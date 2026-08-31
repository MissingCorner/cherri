import Foundation

/// Common surface for a speech-to-speech translation session, so the pipeline
/// can drive OpenAI and Gemini interchangeably. Output audio is always PCM16
/// mono 24 kHz; input audio is PCM16 mono at `inputSampleRate`.
protocol TranslationSession: AnyObject {
    var onAudio: ((Data) -> Void)? { get set }
    var onTranscript: ((String, _ isFinal: Bool) -> Void)? { get set }
    var onStatus: ((String) -> Void)? { get set }
    var onError: ((String) -> Void)? { get set }
    /// false when the connection drops (reconnecting), true when restored.
    var onConnectionChanged: ((Bool) -> Void)? { get set }
    var inputSampleRate: Double { get }
    func connect()
    func close()
    func sendAudio(_ pcm16: Data)
}

/// One WebSocket session against Google's Gemini Live API using the dedicated
/// `gemini-3.5-live-translate-preview` model: continuous speech-to-speech
/// translation, auto-detected source language (70+), target set by BCP-47
/// code. Like OpenAI's translate model it takes no prompts — it is
/// interpretation-only by design.
///
/// Audio in: PCM16 mono 16 kHz. Audio out: PCM16 mono 24 kHz + transcripts.
final class GeminiLiveSession: NSObject, TranslationSession, URLSessionWebSocketDelegate {

    struct Config {
        var apiKey: String
        var model: String = "gemini-3.5-live-translate-preview"
        /// BCP-47 target language code (e.g. "vi", "en").
        var targetLanguageCode: String
        var label: String
        /// Request output transcription (billed as an extra feature) only
        /// when the app actually shows captions.
        var captionsEnabled: Bool = false
    }

    private let config: Config
    private var urlSession: URLSession?
    private var task: URLSessionWebSocketTask?
    private let sendQueue = DispatchQueue(label: "miagent.gemini.send")
    private var isClosed = false
    /// True once the server acknowledged our setup message.
    private var isReady = false
    private var reconnectAttempts = 0
    private var reconnectScheduled = false
    /// Converts model audio to the pipeline's 24 kHz contract when Gemini
    /// declares a different rate in inlineData.mimeType.
    private var outputResampler: StreamResampler?
    private var outputResamplerRate: Double = 0
    private var loggedUnknownShapes: Set<String> = []

    var onAudio: ((Data) -> Void)?
    var onTranscript: ((String, _ isFinal: Bool) -> Void)?
    var onStatus: ((String) -> Void)?
    var onError: ((String) -> Void)?
    var onConnectionChanged: ((Bool) -> Void)?

    var inputSampleRate: Double { 16000 }

    // Speech backlog while disconnected — flushed on reconnect so the
    // interpreter catches up instead of losing what was said.
    private let backlogLock = NSLock()
    private var backlog = Data()
    private static let backlogCap = 16000 * 2 * 30  // 30 s PCM16 @ 16 kHz

    private func bufferBacklog(_ pcm16: Data) {
        guard !isClosed, !pcm16.isEmpty else { return }
        backlogLock.lock()
        backlog.append(pcm16)
        if backlog.count > Self.backlogCap {
            backlog.removeFirst(backlog.count - Self.backlogCap)
        }
        backlogLock.unlock()
    }

    private func flushBacklog() {
        backlogLock.lock()
        let pending = backlog
        backlog = Data()
        backlogLock.unlock()
        guard !pending.isEmpty else { return }
        onStatus?("[\(config.label)] catching up \(pending.count / (16000 * 2)) s of buffered audio")
        let chunkSize = 16000 * 2
        var offset = 0
        while offset < pending.count {
            let end = min(offset + chunkSize, pending.count)
            sendAudioMessage(pending.subdata(in: offset..<end))
            offset = end
        }
    }

    init(config: Config) {
        self.config = config
        super.init()
    }

    // MARK: Connection

    func connect() {
        isClosed = false
        isReady = false
        pendingAudio = Data()
        task?.cancel(with: .normalClosure, reason: nil)
        urlSession?.invalidateAndCancel()

        var components = URLComponents(string: "wss://generativelanguage.googleapis.com/ws/google.ai.generativelanguage.v1beta.GenerativeService.BidiGenerateContent")!
        components.queryItems = [URLQueryItem(name: "key", value: config.apiKey)]
        guard let url = components.url else { return }

        var request = URLRequest(url: url)
        request.timeoutInterval = 15

        let session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
        urlSession = session
        let task = session.webSocketTask(with: request)
        self.task = task
        task.resume()
        receiveLoop()
        onStatus?("[\(config.label)] connecting to Gemini…")
    }

    func close() {
        isClosed = true
        isReady = false
        backlogLock.lock()
        backlog = Data()
        backlogLock.unlock()
        task?.cancel(with: .normalClosure, reason: nil)
        task = nil
        urlSession?.invalidateAndCancel()
        urlSession = nil
    }

    // MARK: Failure handling / reconnect

    private func isAuthFailure(_ message: String) -> Bool {
        let lowered = message.lowercased()
        return lowered.contains("api key") || lowered.contains("api_key")
            || lowered.contains("permission") || lowered.contains("unauthenticated")
            || lowered.contains("401") || lowered.contains("403")
    }

    private func handleFailure(_ message: String) {
        guard !isClosed else { return }
        isReady = false

        if isAuthFailure(message) {
            isClosed = true
            onError?("[\(config.label)] Gemini authentication failed — check your Gemini API key. \(message)")
            return
        }

        onStatus?("[\(config.label)] \(message)")
        guard !reconnectScheduled else { return }
        if reconnectAttempts == 0 { onConnectionChanged?(false) }
        reconnectScheduled = true
        reconnectAttempts += 1
        let delay = min(Double(1 << min(reconnectAttempts, 4)), 15.0)
        onStatus?("[\(config.label)] reconnecting in \(Int(delay))s (attempt \(reconnectAttempts))…")
        DispatchQueue.global().asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, !self.isClosed else { return }
            self.reconnectScheduled = false
            self.connect()
        }
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask,
                    didOpenWithProtocol protocol: String?) {
        onStatus?("[\(config.label)] connected, configuring…")
        sendSetup()
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask,
                    didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        let reasonText = reason.flatMap { String(data: $0, encoding: .utf8) } ?? ""
        handleFailure("connection closed (code \(closeCode.rawValue)) \(reasonText)")
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard !isClosed else { return }
        var message = error.map { "transport error: \($0.localizedDescription)" } ?? "connection ended"
        if let http = task.response as? HTTPURLResponse {
            message += " (HTTP \(http.statusCode))"
        }
        handleFailure(message)
    }

    private func sendSetup() {
        // NB: the transcription toggle lives at the *setup* level, not inside
        // generationConfig — the server rejects it there (1007).
        var setupBody: [String: Any] = [
            "model": "models/\(config.model)",
            "generationConfig": [
                "responseModalities": ["AUDIO"],
                "translationConfig": [
                    "targetLanguageCode": config.targetLanguageCode,
                    // Stay silent when input is already in the target
                    // language — the original passes through unducked.
                    "echoTargetLanguage": false,
                ],
            ] as [String: Any],
        ]
        if config.captionsEnabled {
            setupBody["outputAudioTranscription"] = [:] as [String: Any]
        }
        sendJSON(["setup": setupBody])
    }

    // MARK: Sending audio

    /// Pending audio batched to ~100 ms messages, per Google's guidance.
    /// Only touched from the pipeline's serial send queue.
    private var pendingAudio = Data()
    private static let batchBytes = 3200 // 100 ms of PCM16 @ 16 kHz

    /// Appends PCM16 mono 16 kHz audio. Buffered while disconnected.
    func sendAudio(_ pcm16: Data) {
        guard !pcm16.isEmpty else { return }
        guard isReady else {
            bufferBacklog(pcm16)
            return
        }
        pendingAudio.append(pcm16)
        guard pendingAudio.count >= Self.batchBytes else { return }
        let chunk = pendingAudio
        pendingAudio = Data()
        sendAudioMessage(chunk)
    }

    private func sendAudioMessage(_ chunk: Data) {
        let message: [String: Any] = [
            "realtimeInput": [
                "audio": [
                    "data": chunk.base64EncodedString(),
                    "mimeType": "audio/pcm;rate=16000",
                ],
            ],
        ]
        sendJSON(message)
    }

    private func sendJSON(_ object: [String: Any]) {
        guard let task, !isClosed else { return }
        guard let data = try? JSONSerialization.data(withJSONObject: object),
              let text = String(data: data, encoding: .utf8) else { return }
        sendQueue.async {
            task.send(.string(text)) { _ in }
        }
    }

    // MARK: Receiving

    private func receiveLoop() {
        task?.receive { [weak self] result in
            guard let self, !self.isClosed else { return }
            switch result {
            case .failure(let error):
                self.handleFailure("receive error: \(error.localizedDescription)")
            case .success(let message):
                switch message {
                case .string(let text):
                    if let data = text.data(using: .utf8) {
                        self.handleMessage(data)
                    }
                case .data(let data):
                    // Gemini frequently sends JSON in binary frames.
                    self.handleMessage(data)
                @unknown default:
                    break
                }
                self.receiveLoop()
            }
        }
    }

    private static func rate(fromMime mime: String) -> Double? {
        guard let range = mime.range(of: "rate=") else { return nil }
        let tail = mime[range.upperBound...].prefix(while: { $0.isNumber })
        return Double(tail)
    }

    /// Delivers PCM16 audio to the pipeline at 24 kHz, resampling if the
    /// server declared another rate.
    private func deliverAudio(_ audio: Data, mime: String) {
        let rate = Self.rate(fromMime: mime) ?? 24000
        guard rate != 24000 else {
            onAudio?(audio)
            return
        }
        if outputResampler == nil || outputResamplerRate != rate {
            outputResampler = StreamResampler(sourceRate: rate, targetRate: 24000)
            outputResamplerRate = rate
        }
        guard let resampler = outputResampler else { return }
        let converted = resampler.process(PCM.pcm16ToFloat(audio))
        onAudio?(PCM.floatToPCM16(converted))
    }

    private func handleMessage(_ data: Data) {
        guard let message = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            let preview = String(data: data.prefix(200), encoding: .utf8) ?? "\(data.count) bytes (non-UTF8)"
            onStatus?("[\(config.label)] unparseable Gemini message: \(preview)")
            return
        }

        if message["setupComplete"] != nil {
            isReady = true
            if reconnectAttempts > 0 { onConnectionChanged?(true) }
            reconnectAttempts = 0
            onStatus?("[\(config.label)] Gemini session ready (→ \(config.targetLanguageCode))")
            flushBacklog()
            return
        }

        if let error = message["error"] as? [String: Any] {
            let text = (error["message"] as? String) ?? "\(error)"
            if isAuthFailure(text) {
                isClosed = true
                onError?("[\(config.label)] Gemini authentication failed — check your Gemini API key. \(text)")
            } else {
                onError?("[\(config.label)] Gemini API error: \(text)")
            }
            return
        }

        if message["goAway"] != nil {
            handleFailure("server requested reconnect (goAway)")
            return
        }

        guard let serverContent = message["serverContent"] as? [String: Any] else {
            // Surface message shapes we don't recognize (once per shape) so
            // protocol drift shows up in the status footer instead of silence.
            let shape = message.keys.sorted().joined(separator: ",")
            if !loggedUnknownShapes.contains(shape) {
                loggedUnknownShapes.insert(shape)
                onStatus?("[\(config.label)] unhandled Gemini message keys: \(shape)")
            }
            return
        }

        if let transcription = serverContent["outputTranscription"] as? [String: Any],
           let text = transcription["text"] as? String, !text.isEmpty {
            onTranscript?(text, false)
        }

        if let modelTurn = serverContent["modelTurn"] as? [String: Any],
           let parts = modelTurn["parts"] as? [[String: Any]] {
            for part in parts {
                if let inline = part["inlineData"] as? [String: Any],
                   let base64 = inline["data"] as? String,
                   let audio = Data(base64Encoded: base64) {
                    deliverAudio(audio, mime: (inline["mimeType"] as? String) ?? "")
                }
            }
        }

        if (serverContent["turnComplete"] as? Bool) == true
            || (serverContent["generationComplete"] as? Bool) == true {
            onTranscript?("", true)
        }
    }
}
