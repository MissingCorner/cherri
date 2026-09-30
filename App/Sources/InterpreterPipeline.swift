import CoreAudio
import Foundation

struct Caption: Identifiable, Equatable {
    enum Speaker { case them, you }
    let id = UUID()
    let speaker: Speaker
    var text: String
    var isFinal: Bool
}

/// Wires the whole audio graph together:
///
/// Inbound (what you hear + captions):
///   Zoom speaker -> [Interpreter Line Output] -> capture -> Realtime API A
///   original audio ---------------------------------------> real speakers (ducked)
///   translated audio (API A) ------------------------------> real speakers (overdub)
///
/// Outbound (what the meeting hears):
///   real mic -> capture -> Realtime API B -> [Interpreter Line Input] -> Zoom mic
final class InterpreterPipeline {

    enum Provider: String {
        case openAI = "openai"
        case gemini = "gemini"
    }

    struct Config {
        var provider: Provider = .openAI
        var apiKey: String
        /// Language the meeting hears (outbound translation target), e.g. "en".
        var meetingLanguageCode: String
        var meetingLanguageName: String
        /// Your language (captions + overdub target), e.g. "vi".
        var userLanguageCode: String
        var userLanguageName: String
        /// Meeting context (topic, names, glossary). Only used when
        /// `useContextEngine` is on.
        var meetingContext: String = ""
        /// When true, use the promptable general realtime model with the
        /// strict interpreter prompt + context instead of gpt-realtime-translate.
        var useContextEngine: Bool = false
        /// Model id for the active engine.
        var model: String = "gpt-realtime-translate"
        /// Interpreter prompt template for the contextual engine
        /// ({TARGET_LANGUAGE} placeholder).
        var interpreterPrompt: String = RealtimeSession.defaultPromptTemplate
        /// Output voice for the contextual engine.
        var voice: String = "marin"
        /// Contextual engine: voice-brief the interpreter and wait for its
        /// confirmation before feeding live audio.
        var spokenHandshake: Bool = true
        var micDeviceID: AudioDeviceID
        var outputDeviceID: AudioDeviceID
        /// Linear gain applied to original meeting audio while translation plays.
        var duckGain: Float = 0.15
        /// Conference mode: the meeting hears the real voice continuously,
        /// dimmed to `duckGain` while the translated dub speaks over it.
        /// When false, the meeting hears only the dub.
        var voicePassthrough: Bool = true
        /// Show live captions (on Gemini this also requests the billed
        /// output-transcription feature; off saves money).
        var captionsEnabled: Bool = false
        /// Voice-activated streaming: only send audio to the (billed) API
        /// while speech is detected. Pre-roll keeps word onsets intact.
        var voiceGateEnabled: Bool = true
        /// Mixer: level of the ORIGINAL meeting voices kept under the
        /// translation you hear (0 = translation only).
        var meetingOriginalGain: Float = 0.15
        /// Mixer: level of your ORIGINAL voice kept under the outbound dub
        /// in conference mode (0 = dub only).
        var myVoiceOriginalGain: Float = 0.15
        /// Live conversation mode: mic + speaker only, no meeting app and no
        /// virtual devices. The mic feeds BOTH translation directions and
        /// both translated voices play on the speaker.
        var liveMode: Bool = false
        /// Translate meeting audio for me. Off: I hear the original untouched
        /// and nothing streams inbound (no cost).
        var translateMeeting: Bool = true
        /// Translate my voice for the meeting. Off: the meeting hears my real
        /// voice only and nothing streams outbound.
        var translateMine: Bool = true
        /// Call Insight: run dedicated cheap transcription sessions so
        /// insights work even with no direction translating.
        var insightTranscription: Bool = false
        /// OpenAI key for the transcription sessions (may differ from
        /// `apiKey` when Gemini is the translation provider).
        var openAIKey: String = ""
    }

    var onCaption: ((String, Bool, Caption.Speaker) -> Void)?
    /// Throttled (~10 Hz) level/streaming telemetry for the UI:
    /// (micDb, micStreaming, meetingDb, meetingStreaming).
    var onLevels: ((Float, Bool, Float, Bool) -> Void)?
    var onStatus: ((String) -> Void)?
    /// User-actionable failures (bad API key, connection given up).
    var onError: ((String) -> Void)?
    /// Transient connection state: a message while reconnecting, nil when
    /// everything is connected again.
    var onNotice: ((String?) -> Void)?
    private var inboundDown = false
    private var outboundDown = false

    private func updateConnectionNotice() {
        if inboundDown || outboundDown {
            onNotice?("Connection dropped — reconnecting… speech is buffered and will catch up.")
        } else {
            onNotice?(nil)
        }
    }

    private var config: Config?
    private var sessionInbound: TranslationSession?
    private var sessionOutbound: TranslationSession?
    // Insight transcription (original language, independent of translation).
    private var sttMeeting: TranscriptionSession?
    private var sttMic: TranscriptionSession?
    private var sttMeetingTo24k: StreamResampler?
    private var sttMicTo24k: StreamResampler?
    /// Finished original-language utterances from the insight transcription.
    var onSTTTranscript: ((String, Caption.Speaker) -> Void)?

    private var meetingCapture: CaptureUnit?   // from virtual Line Out
    private var micCapture: AudioCapturing?    // from real mic (AEC when possible)
    private var speakerPlayback: PlaybackUnit? // to real output
    private var virtualMicPlayback: PlaybackUnit? // to virtual Line In

    // Rings all hold mono float at the *destination* device rate.
    private let originalRing = FloatRingBuffer(capacity: 48000 * 10)
    private let translatedRing = FloatRingBuffer(capacity: 48000 * 60)
    private let outboundRing = FloatRingBuffer(capacity: 48000 * 60)
    private let micPassthroughRing = FloatRingBuffer(capacity: 48000 * 10)

    // Resamplers (created at start once device rates are known).
    private var meetingToAPI: StreamResampler?
    private var meetingToSpeaker: StreamResampler?
    private var api24kToSpeaker: StreamResampler?
    private var api24kToSpeakerB: StreamResampler?
    private var micToAPI: StreamResampler?
    private var api24kToVirtualMic: StreamResampler?
    private var micToVirtualMic: StreamResampler?

    private let apiSendQueue = DispatchQueue(label: "miagent.pipeline.apisend")

    // Ducking state (audio-thread only, one set per render callback).
    private var duckCurrentGain: Float = 1.0
    private var duckHoldSamples: Int = 0
    private var speakerRate: Double = 48000
    private var outDuckCurrentGain: Float = 1.0
    private var outDuckHoldSamples: Int = 0
    private var virtualMicRate: Double = 48000

    // Scratch buffers for the render callbacks.
    private var scratchOriginal = [Float](repeating: 0, count: 8192)
    private var scratchTranslated = [Float](repeating: 0, count: 8192)
    private var scratchMicPass = [Float](repeating: 0, count: 8192)
    private var scratchOutbound = [Float](repeating: 0, count: 8192)

    private(set) var isRunning = false

    // Live mute flags, set from the UI while running. Word-sized reads on the
    // audio threads; no lock needed.
    private var micMuted = false
    private var inboundPaused = false

    // Live mixer levels (duck targets while a dub is playing).
    private var meetingOriginalGain: Float = 0.15
    private var myVoiceOriginalGain: Float = 0.15

    /// Live mixer: original-voice level under each dub (0–1).
    func setMixLevels(meetingOriginal: Float, myVoiceOriginal: Float) {
        meetingOriginalGain = max(0, min(1, meetingOriginal))
        myVoiceOriginalGain = max(0, min(1, myVoiceOriginal))
    }

    // MARK: Voice test — record 10 s of the outbound mix, play it back.

    private var testState = 0            // 0 idle, 1 recording, 2 playing
    private var testBuffer: [Float] = []
    private var testCapacity = 0
    private var testPlayRemaining = Int.max
    private let testRing = FloatRingBuffer(capacity: 48000 * 12)
    private var scratchTest = [Float](repeating: 0, count: 8192)
    /// Phases: "recording", "playing", "done". May fire on audio threads.
    var onTestPhase: ((String) -> Void)?

    func startVoiceTest() {
        guard isRunning, testState == 0 else { return }
        testCapacity = Int(virtualMicRate * 10)
        testBuffer.removeAll(keepingCapacity: true)
        testBuffer.reserveCapacity(testCapacity + 4096)
        testPlayRemaining = Int.max
        testRing.reset()
        testState = 1
        onTestPhase?("recording")
    }

    /// Called from the virtual-mic render thread with the final outbound mix.
    private func captureVoiceTest(_ samples: UnsafeMutablePointer<Float>, count: Int) {
        guard testState == 1 else { return }
        let take = min(testCapacity - testBuffer.count, count)
        if take > 0 {
            testBuffer.append(contentsOf: UnsafeBufferPointer(start: samples, count: take))
        }
        guard testBuffer.count >= testCapacity else { return }
        testState = 2
        let recorded = testBuffer
        let sourceRate = virtualMicRate
        apiSendQueue.async { [weak self] in
            guard let self else { return }
            let resampler = StreamResampler(sourceRate: sourceRate, targetRate: self.speakerRate)
            let atSpeakerRate = resampler.process(recorded)
            self.testRing.write(atSpeakerRate)
            self.testPlayRemaining = atSpeakerRate.count
            self.onTestPhase?("playing")
        }
    }

    /// Called from the speaker render thread to overlay the test playback.
    private func mixInVoiceTest(_ out: UnsafeMutablePointer<Float>, count n: Int) {
        guard testState == 2, testPlayRemaining != Int.max else { return }
        let toMix = min(n, scratchTest.count)
        scratchTest.withUnsafeMutableBufferPointer { buf in
            testRing.read(into: buf.baseAddress!, count: toMix)
            for i in 0..<toMix { out[i] += buf.baseAddress![i] }
        }
        testPlayRemaining -= toMix
        if testPlayRemaining <= 0 {
            testState = 0
            testPlayRemaining = Int.max
            onTestPhase?("done")
        }
    }

    // Voice gates + level telemetry (audio threads write, UI reads via onLevels).
    private var micGate: VoiceGate?
    private var meetingGate: VoiceGate?
    private var lastLevelEmit: CFAbsoluteTime = 0

    /// Runs the chunk through the gate (or just the meter when gating is
    /// off) and returns what should be streamed, nil when gated shut.
    private func gatedChunk(_ gate: VoiceGate?, _ samples: UnsafePointer<Float>, _ count: Int) -> [Float]? {
        guard let gate else { return [Float](UnsafeBufferPointer(start: samples, count: count)) }
        if config?.voiceGateEnabled == true {
            return gate.process(samples, count: count)
        }
        gate.measure(samples, count: count)
        return [Float](UnsafeBufferPointer(start: samples, count: count))
    }

    private func emitLevels() {
        let now = CFAbsoluteTimeGetCurrent()
        guard now - lastLevelEmit >= 0.1 else { return }
        lastLevelEmit = now
        let gateOn = config?.voiceGateEnabled == true
        let micStreaming = !micMuted && (!gateOn || micGate?.isOpen == true)
        if config?.liveMode == true {
            // No meeting side: the left arc pulses while the interpreter speaks.
            let translating = translatedRing.availableToRead > 0 || outboundRing.availableToRead > 0
            onLevels?(micGate?.levelDb ?? -80, micStreaming,
                      translating ? -15 : -80, translating)
            return
        }
        let meetingStreaming = !inboundPaused && (!gateOn || meetingGate?.isOpen == true)
        onLevels?(micGate?.levelDb ?? -80, micStreaming,
                  meetingGate?.levelDb ?? -80, meetingStreaming)
    }

    /// Stops streaming the mic to the API and cuts the voice passthrough.
    func setMicMuted(_ muted: Bool) {
        micMuted = muted
        onStatus?(muted ? "Mic muted — outbound streaming stopped" : "Mic live")
    }

    /// Stops streaming meeting audio to the API; the original still plays
    /// through to the speakers at full volume.
    func setInboundPaused(_ paused: Bool) {
        inboundPaused = paused
        onStatus?(paused ? "Meeting translation off — original audio passes through" : "Meeting translation on")
    }

    // Outbound translation toggle: off = the meeting hears only the real
    // voice (full volume), nothing streams outbound.
    private var outboundEnabled = true

    func setOutboundEnabled(_ enabled: Bool) {
        outboundEnabled = enabled
        onStatus?(enabled ? "My-voice translation on" : "My-voice translation off — real voice only")
    }

    // MARK: Lifecycle

    func start(config: Config) throws {
        stop()
        self.config = config
        meetingOriginalGain = config.meetingOriginalGain
        myVoiceOriginalGain = config.myVoiceOriginalGain

        // Visible devices prove the driver is installed; the hidden tap/feed
        // companions (reachable only by UID translation) are the app's side
        // of each loopback pair. Missing tap/feed with visible devices
        // present means an outdated driver build is installed. Live mode
        // needs none of them.
        var tapID: AudioDeviceID?
        var feedID: AudioDeviceID?
        if !config.liveMode {
            guard AudioDevices.find(uid: VirtualDeviceUID.lineOut) != nil,
                  AudioDevices.find(uid: VirtualDeviceUID.lineIn) != nil else {
                throw PipelineError.driverNotInstalled
            }
            guard let tap = AudioDevices.deviceID(forUID: VirtualDeviceUID.lineOutTap),
                  let feed = AudioDevices.deviceID(forUID: VirtualDeviceUID.lineInFeed) else {
                throw PipelineError.driverOutdated
            }
            tapID = tap
            feedID = feed
        }

        originalRing.reset()
        translatedRing.reset()
        outboundRing.reset()
        micPassthroughRing.reset()
        duckCurrentGain = 1.0
        duckHoldSamples = 0
        outDuckCurrentGain = 1.0
        outDuckHoldSamples = 0

        // --- Spoken briefings (rendered BEFORE anything connects) --------------
        // TTS runs on the main thread; start() must be called off it.
        var inboundBriefing: Data?
        var outboundBriefing: Data?
        if config.provider == .openAI && config.useContextEngine && config.spokenHandshake {
            onStatus?("Rendering spoken briefing…")
            inboundBriefing = SpokenPromptGenerator.generateSync(
                text: RealtimeSession.spokenPromptText(targetLanguage: config.userLanguageName))
            outboundBriefing = SpokenPromptGenerator.generateSync(
                text: RealtimeSession.spokenPromptText(targetLanguage: config.meetingLanguageName))
            if inboundBriefing == nil || outboundBriefing == nil {
                onStatus?("Spoken briefing unavailable — starting without it")
            }
        }

        // --- Translation sessions ----------------------------------------------
        let inbound: TranslationSession
        let outbound: TranslationSession
        switch config.provider {
        case .gemini:
            inbound = GeminiLiveSession(config: .init(
                apiKey: config.apiKey,
                targetLanguageCode: config.userLanguageCode,
                label: "inbound",
                captionsEnabled: config.captionsEnabled))
            outbound = GeminiLiveSession(config: .init(
                apiKey: config.apiKey,
                targetLanguageCode: config.meetingLanguageCode,
                label: "outbound",
                captionsEnabled: config.captionsEnabled))
        case .openAI:
            let engine: RealtimeSession.Engine = config.useContextEngine
                ? .contextual(context: config.meetingContext)
                : .translate
            inbound = RealtimeSession(config: .init(
                apiKey: config.apiKey,
                engine: engine,
                model: config.model,
                targetLanguageCode: config.userLanguageCode,
                targetLanguageName: config.userLanguageName,
                label: "inbound",
                promptTemplate: config.interpreterPrompt,
                voice: config.voice,
                spokenPromptAudio: inboundBriefing))
            outbound = RealtimeSession(config: .init(
                apiKey: config.apiKey,
                engine: engine,
                model: config.model,
                targetLanguageCode: config.meetingLanguageCode,
                targetLanguageName: config.meetingLanguageName,
                label: "outbound",
                promptTemplate: config.interpreterPrompt,
                voice: config.voice,
                spokenPromptAudio: outboundBriefing))
        }
        sessionInbound = inbound
        sessionOutbound = outbound

        inbound.onStatus = { [weak self] in self?.onStatus?($0) }
        outbound.onStatus = { [weak self] in self?.onStatus?($0) }
        inbound.onError = { [weak self] in
            self?.onStatus?($0)
            self?.onError?($0)
        }
        outbound.onError = { [weak self] in
            self?.onStatus?($0)
            self?.onError?($0)
        }
        inboundDown = false
        outboundDown = false
        inbound.onConnectionChanged = { [weak self] up in
            self?.inboundDown = !up
            self?.updateConnectionNotice()
        }
        outbound.onConnectionChanged = { [weak self] up in
            self?.outboundDown = !up
            self?.updateConnectionNotice()
        }

        inbound.onAudio = { [weak self] pcm16 in
            guard let self, let resampler = self.api24kToSpeaker else { return }
            let floats = PCM.pcm16ToFloat(pcm16)
            let atSpeakerRate = resampler.process(floats)
            self.translatedRing.write(atSpeakerRate)
        }
        inbound.onTranscript = { [weak self] delta, isFinal in
            guard let self, self.config?.captionsEnabled == true else { return }
            self.onCaption?(delta, isFinal, .them)
        }

        outbound.onAudio = { [weak self] pcm16 in
            guard let self, let resampler = self.api24kToVirtualMic else { return }
            let floats = PCM.pcm16ToFloat(pcm16)
            let atMicRate = resampler.process(floats)
            self.outboundRing.write(atMicRate)
        }
        outbound.onTranscript = { [weak self] delta, isFinal in
            guard let self, self.config?.captionsEnabled == true else { return }
            self.onCaption?(delta, isFinal, .you)
        }

        inbound.connect()
        outbound.connect()

        // --- Insight transcription (independent of the translate toggles) ------
        if config.insightTranscription {
            if config.openAIKey.isEmpty {
                onStatus?("Insight transcription needs the OpenAI API key")
            } else {
                if !config.liveMode {
                    let stt = TranscriptionSession(apiKey: config.openAIKey, label: "stt-meeting")
                    stt.onUtterance = { [weak self] text in self?.onSTTTranscript?(text, .them) }
                    stt.onStatus = { [weak self] in self?.onStatus?($0) }
                    sttMeeting = stt
                    stt.connect()
                }
                let sttM = TranscriptionSession(apiKey: config.openAIKey, label: "stt-mic")
                sttM.onUtterance = { [weak self] text in self?.onSTTTranscript?(text, .you) }
                sttM.onStatus = { [weak self] in self?.onStatus?($0) }
                sttMic = sttM
                sttM.connect()
            }
        }

        if config.liveMode {
            // --- Live conversation mode: mic + speaker only --------------------
            let speaker = PlaybackUnit(deviceID: config.outputDeviceID)
            speakerPlayback = speaker
            try speaker.start()
            speakerRate = speaker.sampleRate
            speaker.renderMono = { [weak self] out, frames in
                guard let self else {
                    out.update(repeating: 0, count: frames)
                    return
                }
                self.renderLiveMix(out, frames: frames)
            }
            api24kToSpeaker = StreamResampler(sourceRate: 24000, targetRate: speaker.sampleRate)
            api24kToSpeakerB = StreamResampler(sourceRate: 24000, targetRate: speaker.sampleRate)

            // One interpreter line: each direction lands in its own ring and
            // an arbiter plays one at a time (inbound handler already fills
            // translatedRing; outbound goes to outboundRing).
            outbound.onAudio = { [weak self] pcm16 in
                guard let self, let resampler = self.api24kToSpeakerB else { return }
                let floats = PCM.pcm16ToFloat(pcm16)
                self.outboundRing.write(resampler.process(floats))
            }

            let mic = try startMicCapture(config: config)
            micCapture = mic
            micToAPI = StreamResampler(sourceRate: mic.sampleRate, targetRate: outbound.inputSampleRate)
            sttMicTo24k = StreamResampler(sourceRate: mic.sampleRate, targetRate: 24000)
            micGate = VoiceGate(sampleRate: mic.sampleRate)
            meetingGate = nil

            // One mic feeds BOTH directions; each engine stays silent when
            // the speech is already in its target language.
            mic.onAudio = { [weak self] samples, count in
                guard let self, !self.micMuted else { return }
                let gated = self.gatedChunk(self.micGate, samples, count)
                self.emitLevels()
                guard let chunk = gated else { return }
                self.apiSendQueue.async { [weak self] in
                    guard let self, !self.micMuted, let toAPI = self.micToAPI else { return }
                    let pcm = PCM.floatToPCM16(toAPI.process(chunk))
                    // "Me →" is the MASTER translation switch in live mode:
                    // one shared mic can't attribute speakers, so with it off
                    // nothing is translated (otherwise the inbound direction
                    // would translate the user's own speech back at them).
                    // Insight transcription continues regardless.
                    if self.outboundEnabled {
                        if !self.inboundPaused { self.sessionInbound?.sendAudio(pcm) }
                        self.sessionOutbound?.sendAudio(pcm)
                    }
                    if let stt = self.sttMic, let to24k = self.sttMicTo24k {
                        stt.sendAudio(PCM.floatToPCM16(to24k.process(chunk)))
                    }
                }
            }
        } else {
        // --- Speaker playback (original ducked + translated overdub) ----------
        let speaker = PlaybackUnit(deviceID: config.outputDeviceID)
        speakerPlayback = speaker
        try speaker.start()
        speakerRate = speaker.sampleRate

        speaker.renderMono = { [weak self] out, frames in
            guard let self else {
                out.update(repeating: 0, count: frames)
                return
            }
            self.renderSpeakerMix(out, frames: frames)
        }

        // --- Virtual mic playback (translated outbound speech) ----------------
        let virtualMic = PlaybackUnit(deviceID: feedID!)
        virtualMicPlayback = virtualMic
        try virtualMic.start()
        virtualMicRate = virtualMic.sampleRate
        virtualMic.renderMono = { [weak self] out, frames in
            guard let self else {
                out.update(repeating: 0, count: frames)
                return
            }
            self.renderVirtualMicMix(out, frames: frames)
        }

        // --- Meeting capture (from virtual Line Out) ---------------------------
        let meeting = CaptureUnit(deviceID: tapID!)
        meetingCapture = meeting
        try meeting.start()

        meetingToAPI = StreamResampler(sourceRate: meeting.sampleRate, targetRate: inbound.inputSampleRate)
        sttMeetingTo24k = StreamResampler(sourceRate: meeting.sampleRate, targetRate: 24000)
        meetingToSpeaker = StreamResampler(sourceRate: meeting.sampleRate, targetRate: speaker.sampleRate)
        api24kToSpeaker = StreamResampler(sourceRate: 24000, targetRate: speaker.sampleRate)
        api24kToVirtualMic = StreamResampler(sourceRate: 24000, targetRate: virtualMic.sampleRate)

        meeting.onAudio = { [weak self] samples, count in
            guard let self else { return }
            // Pass-through path: must stay on the audio thread and be cheap.
            if let toSpeaker = self.meetingToSpeaker {
                let passthrough = toSpeaker.process(samples, count: count)
                self.originalRing.write(passthrough)
            }
            // API path: gate on detected speech, then send off the audio thread.
            let gated = self.gatedChunk(self.meetingGate, samples, count)
            self.emitLevels()
            guard let chunk = gated else { return }
            self.apiSendQueue.async { [weak self] in
                guard let self else { return }
                if !self.inboundPaused, let toAPI = self.meetingToAPI {
                    self.sessionInbound?.sendAudio(PCM.floatToPCM16(toAPI.process(chunk)))
                }
                if let stt = self.sttMeeting, let to24k = self.sttMeetingTo24k {
                    stt.sendAudio(PCM.floatToPCM16(to24k.process(chunk)))
                }
            }
        }

        // --- Mic capture (from real mic, echo-cancelled when possible) ---------
        let mic = try startMicCapture(config: config)
        micCapture = mic
        micToAPI = StreamResampler(sourceRate: mic.sampleRate, targetRate: outbound.inputSampleRate)
        sttMicTo24k = StreamResampler(sourceRate: mic.sampleRate, targetRate: 24000)
        // Always created: the real voice must reach the meeting whenever
        // outbound translation is off, regardless of the conference-mode
        // setting (which only governs behavior while translating).
        micToVirtualMic = StreamResampler(sourceRate: mic.sampleRate, targetRate: virtualMic.sampleRate)

        micGate = VoiceGate(sampleRate: mic.sampleRate)
        meetingGate = VoiceGate(sampleRate: meeting.sampleRate)

        mic.onAudio = { [weak self] samples, count in
            guard let self, !self.micMuted else { return }
            // Conference mode: real voice straight into the virtual mic mix.
            if let toVirtualMic = self.micToVirtualMic {
                let passthrough = toVirtualMic.process(samples, count: count)
                self.micPassthroughRing.write(passthrough)
            }
            let gated = self.gatedChunk(self.micGate, samples, count)
            self.emitLevels()
            guard let chunk = gated else { return }
            self.apiSendQueue.async { [weak self] in
                guard let self, !self.micMuted, let to24k = self.micToAPI else { return }
                let at24k = to24k.process(chunk)
                self.sessionOutbound?.sendAudio(PCM.floatToPCM16(at24k))
            }
        }

        }

        micMuted = false
        inboundPaused = !config.translateMeeting
        outboundEnabled = config.translateMine
        isRunning = true
        onStatus?("Pipeline running")
    }

    func stop() {
        meetingCapture?.stop()
        micCapture?.stop()
        speakerPlayback?.stop()
        virtualMicPlayback?.stop()
        meetingCapture = nil
        micCapture = nil
        speakerPlayback = nil
        virtualMicPlayback = nil

        sessionInbound?.close()
        sessionOutbound?.close()
        sessionInbound = nil
        sessionOutbound = nil
        sttMeeting?.close()
        sttMic?.close()
        sttMeeting = nil
        sttMic = nil
        sttMeetingTo24k = nil
        sttMicTo24k = nil

        meetingToAPI = nil
        meetingToSpeaker = nil
        api24kToSpeaker = nil
        api24kToSpeakerB = nil
        api24kToVirtualMic = nil
        micToVirtualMic = nil
        micGate = nil
        meetingGate = nil
        testState = 0
        testPlayRemaining = Int.max
        testRing.reset()
        inboundDown = false
        outboundDown = false
        liveSource = 0
        onNotice?(nil)

        if isRunning {
            isRunning = false
            onStatus?("Pipeline stopped")
        }
    }

    /// VPIO (echo-cancelled) mic capture with plain-capture fallback.
    private func startMicCapture(config: Config) throws -> AudioCapturing {
        let vpio = VoiceProcessingCaptureUnit(
            micDeviceID: config.micDeviceID,
            referenceOutputDeviceID: config.outputDeviceID)
        do {
            try vpio.start()
            onStatus?("Echo cancellation active (voice processing)")
            return vpio
        } catch {
            vpio.stop()
            onStatus?("Echo cancellation unavailable (\(error.localizedDescription)) — using plain mic capture; use headphones to avoid feedback")
            let plain = CaptureUnit(deviceID: config.micDeviceID)
            try plain.start()
            return plain
        }
    }

    // MARK: Live mode — single interpreter line

    /// 0 = idle, 1 = their speech → my language, 2 = my speech → theirs.
    private var liveSource = 0

    /// One voice at a time: the direction currently speaking holds the line
    /// until its ring drains, then the other direction takes over.
    private func renderLiveMix(_ out: UnsafeMutablePointer<Float>, frames: Int) {
        let n = min(frames, scratchTranslated.count)
        let aAvailable = translatedRing.availableToRead
        let bAvailable = outboundRing.availableToRead

        if liveSource == 1 && aAvailable == 0 && bAvailable > 0 {
            liveSource = 2
        } else if liveSource == 2 && bAvailable == 0 && aAvailable > 0 {
            liveSource = 1
        } else if liveSource == 0 {
            liveSource = aAvailable > 0 ? 1 : (bAvailable > 0 ? 2 : 0)
        }

        switch liveSource {
        case 1: translatedRing.read(into: out, count: n)
        case 2: outboundRing.read(into: out, count: n)
        default: out.update(repeating: 0, count: n)
        }
        if frames > n {
            (out + n).update(repeating: 0, count: frames - n)
        }
    }

    // MARK: Speaker mix with ducking

    private func renderSpeakerMix(_ out: UnsafeMutablePointer<Float>, frames: Int) {
        let n = min(frames, scratchOriginal.count)
        scratchOriginal.withUnsafeMutableBufferPointer { orig in
            scratchTranslated.withUnsafeMutableBufferPointer { trans in
                originalRing.read(into: orig.baseAddress!, count: n)
                let translatedAvailable = translatedRing.availableToRead
                translatedRing.read(into: trans.baseAddress!, count: n)

                // Hold the duck for ~400 ms after translated audio stops so the
                // gain doesn't pump between sentences.
                if translatedAvailable > 0 {
                    duckHoldSamples = Int(speakerRate * 0.4)
                } else {
                    duckHoldSamples = max(0, duckHoldSamples - n)
                }
                let targetGain: Float = duckHoldSamples > 0 ? meetingOriginalGain : 1.0

                // ~30 ms smoothing to avoid clicks.
                let alpha = Float(1.0 - exp(-1.0 / (0.03 * speakerRate)))
                for i in 0..<n {
                    duckCurrentGain += (targetGain - duckCurrentGain) * alpha
                    out[i] = orig.baseAddress![i] * duckCurrentGain + trans.baseAddress![i]
                }
            }
        }
        mixInVoiceTest(out, count: n)
        if frames > n {
            (out + n).update(repeating: 0, count: frames - n)
        }
    }

    // MARK: Virtual mic mix (conference mode)

    /// What the meeting hears: the translated dub, with the real voice
    /// underneath, dimmed while the dub speaks (mirror of the speaker mix).
    private func renderVirtualMicMix(_ out: UnsafeMutablePointer<Float>, frames: Int) {
        let n = min(frames, scratchMicPass.count)
        scratchMicPass.withUnsafeMutableBufferPointer { voice in
            scratchOutbound.withUnsafeMutableBufferPointer { dub in
                micPassthroughRing.read(into: voice.baseAddress!, count: n)
                let dubAvailable = outboundEnabled ? outboundRing.availableToRead : 0
                outboundRing.read(into: dub.baseAddress!, count: n)
                if !outboundEnabled {
                    dub.baseAddress!.update(repeating: 0, count: n)
                }

                // Real voice passes through when conference mode is on OR when
                // outbound translation is off (silence to the meeting would
                // be a bug, not a setting).
                let passthroughActive = (config?.voicePassthrough == true) || !outboundEnabled
                guard passthroughActive else {
                    out.update(from: dub.baseAddress!, count: n)
                    return
                }

                if dubAvailable > 0 {
                    outDuckHoldSamples = Int(virtualMicRate * 0.4)
                } else {
                    outDuckHoldSamples = max(0, outDuckHoldSamples - n)
                }
                let targetGain: Float = outDuckHoldSamples > 0 ? myVoiceOriginalGain : 1.0

                let alpha = Float(1.0 - exp(-1.0 / (0.03 * virtualMicRate)))
                for i in 0..<n {
                    outDuckCurrentGain += (targetGain - outDuckCurrentGain) * alpha
                    out[i] = voice.baseAddress![i] * outDuckCurrentGain + dub.baseAddress![i]
                }
            }
        }
        captureVoiceTest(out, count: n)
        if frames > n {
            (out + n).update(repeating: 0, count: frames - n)
        }
    }
}

enum PipelineError: Error, LocalizedError {
    case driverNotInstalled
    case driverOutdated

    var errorDescription: String? {
        switch self {
        case .driverNotInstalled:
            return "Cherri virtual audio devices not found. Install the driver first (make install-driver), then restart Core Audio."
        case .driverOutdated:
            return "An older Cherri audio driver is installed. Reinstall it (make install-driver) to get the updated devices, then press Start again."
        }
    }
}
