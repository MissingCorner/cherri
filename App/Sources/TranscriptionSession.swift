import Foundation

/// Transcription-only OpenAI Realtime session (`intent=transcription`):
/// cheap streaming speech-to-text used by Call Insight, so insights work even
/// when nothing is being translated (e.g. an all-English meeting).
///
/// Audio in: PCM16 mono 24 kHz. Out: finished utterances in the original
/// language.
final class TranscriptionSession: NSObject, URLSessionWebSocketDelegate {

    private let apiKey: String
    private let label: String
    private var urlSession: URLSession?
    private var task: URLSessionWebSocketTask?
    private let sendQueue = DispatchQueue(label: "cherri.stt.send")
    private var isClosed = false
    private var isOpen = false
    private var reconnectAttempts = 0
    private var reconnectScheduled = false

    var onUtterance: ((String) -> Void)?
    var onStatus: ((String) -> Void)?

    init(apiKey: String, label: String) {
        self.apiKey = apiKey
        self.label = label
        super.init()
    }

    func connect() {
        isClosed = false
        isOpen = false
        task?.cancel(with: .normalClosure, reason: nil)
        urlSession?.invalidateAndCancel()

        var request = URLRequest(url: URL(string: "wss://api.openai.com/v1/realtime?intent=transcription")!)
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 15

        let session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
        urlSession = session
        let task = session.webSocketTask(with: request)
        self.task = task
        task.resume()
        receiveLoop()
    }

    func close() {
        isClosed = true
        isOpen = false
        task?.cancel(with: .normalClosure, reason: nil)
        task = nil
        urlSession?.invalidateAndCancel()
        urlSession = nil
    }

    /// PCM16 mono 24 kHz. Dropped while the socket is down (the insight
    /// engine works on conversation flow; gaps are tolerable).
    func sendAudio(_ pcm16: Data) {
        guard !pcm16.isEmpty, isOpen else { return }
        let message: [String: Any] = [
            "type": "input_audio_buffer.append",
            "audio": pcm16.base64EncodedString(),
        ]
        sendJSON(message)
    }

    // MARK: Connection lifecycle

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask,
                    didOpenWithProtocol protocol: String?) {
        isOpen = true
        reconnectAttempts = 0
        // Per current docs: model "gpt-transcribe" (post-commit, language
        // detection) with server VAD committing each utterance.
        let sessionConfig: [String: Any] = [
            "type": "transcription",
            "audio": [
                "input": [
                    "format": ["type": "audio/pcm", "rate": 24000],
                    "turn_detection": [
                        "type": "server_vad",
                        "silence_duration_ms": 400,
                    ],
                    "transcription": ["model": "gpt-transcribe"],
                ],
            ],
        ]
        sendJSON(["type": "session.update", "session": sessionConfig])
        onStatus?("[\(label)] transcription connected")
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask,
                    didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        let reasonText = reason.flatMap { String(data: $0, encoding: .utf8) } ?? ""
        handleFailure("closed (code \(closeCode.rawValue)) \(reasonText)")
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard !isClosed else { return }
        handleFailure(error.map { "transport error: \($0.localizedDescription)" } ?? "connection ended")
    }

    private func handleFailure(_ message: String) {
        guard !isClosed else { return }
        isOpen = false
        let lowered = message.lowercased()
        if lowered.contains("bearer") || lowered.contains("api key") || lowered.contains("401") {
            isClosed = true
            onStatus?("[\(label)] transcription auth failed — check the OpenAI key")
            return
        }
        guard !reconnectScheduled else { return }
        reconnectScheduled = true
        reconnectAttempts += 1
        let delay = min(Double(1 << min(reconnectAttempts, 4)), 15.0)
        onStatus?("[\(label)] \(message) — reconnecting in \(Int(delay))s")
        DispatchQueue.global().asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, !self.isClosed else { return }
            self.reconnectScheduled = false
            self.connect()
        }
    }

    // MARK: Receive

    private func sendJSON(_ object: [String: Any]) {
        guard let task, !isClosed else { return }
        guard let data = try? JSONSerialization.data(withJSONObject: object),
              let text = String(data: data, encoding: .utf8) else { return }
        sendQueue.async {
            task.send(.string(text)) { _ in }
        }
    }

    private func receiveLoop() {
        task?.receive { [weak self] result in
            guard let self, !self.isClosed else { return }
            switch result {
            case .failure(let error):
                self.handleFailure("receive error: \(error.localizedDescription)")
            case .success(let message):
                switch message {
                case .string(let text):
                    self.handleEvent(text)
                case .data(let data):
                    if let text = String(data: data, encoding: .utf8) {
                        self.handleEvent(text)
                    }
                @unknown default:
                    break
                }
                self.receiveLoop()
            }
        }
    }

    private var loggedEventTypes: Set<String> = []

    private func handleEvent(_ text: String) {
        guard let data = text.data(using: .utf8),
              let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = event["type"] as? String else { return }

        // Finished utterances only — clean sentences for the insight engine.
        if type.hasSuffix("input_audio_transcription.completed")
            || type.hasSuffix("input_audio_transcription.done") {
            if let transcript = event["transcript"] as? String,
               !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                onUtterance?(transcript)
            }
            return
        }
        switch type {
        case "session.created":
            break
        case "session.updated", "transcription_session.updated":
            onStatus?("[\(label)] transcription session ready")
        case "error":
            if let err = event["error"] as? [String: Any],
               let message = err["message"] as? String {
                let lowered = message.lowercased()
                if lowered.contains("bearer") || lowered.contains("api key") {
                    isClosed = true
                }
                onStatus?("[\(label)] transcription error: \(message)")
            }
        default:
            // Deltas and speech markers are expected chatter; log anything
            // else once so protocol drift is visible instead of silent.
            if !type.contains(".delta"),
               !type.contains("input_audio_buffer"),
               !loggedEventTypes.contains(type) {
                loggedEventTypes.insert(type)
                onStatus?("[\(label)] unhandled event: \(type)")
            }
        }
    }
}
