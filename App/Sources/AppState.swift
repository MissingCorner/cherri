import CoreAudio
import Foundation
import SwiftUI
@preconcurrency import UserNotifications

@MainActor
final class AppState: ObservableObject {

    // MARK: Published state

    @Published var devices: [AudioDeviceInfo] = []
    @Published var selectedMicUID: String {
        didSet { UserDefaults.standard.set(selectedMicUID, forKey: "micUID") }
    }
    @Published var selectedOutputUID: String {
        didSet { UserDefaults.standard.set(selectedOutputUID, forKey: "outputUID") }
    }
    @Published var meetingLanguageCode: String {
        didSet { UserDefaults.standard.set(meetingLanguageCode, forKey: "meetingLangCode") }
    }
    @Published var userLanguageCode: String {
        didSet { UserDefaults.standard.set(userLanguageCode, forKey: "userLangCode") }
    }
    @Published var meetingContext: String {
        didSet { UserDefaults.standard.set(meetingContext, forKey: "meetingContext") }
    }
    @Published var useContextEngine: Bool {
        didSet { UserDefaults.standard.set(useContextEngine, forKey: "useContextEngine") }
    }
    @Published var contextModelChoice: String {
        didSet { UserDefaults.standard.set(contextModelChoice, forKey: "contextModelChoice") }
    }
    @Published var customContextModel: String {
        didSet { UserDefaults.standard.set(customContextModel, forKey: "customContextModel") }
    }
    @Published var voicePassthrough: Bool {
        didSet { UserDefaults.standard.set(voicePassthrough, forKey: "voicePassthrough") }
    }
    @Published var interpreterPrompt: String {
        didSet { UserDefaults.standard.set(interpreterPrompt, forKey: "interpreterPrompt") }
    }
    @Published var voice: String {
        didSet { UserDefaults.standard.set(voice, forKey: "voice") }
    }
    @Published var spokenHandshake: Bool {
        didSet { UserDefaults.standard.set(spokenHandshake, forKey: "spokenHandshake") }
    }
    @Published var captionsEnabled: Bool {
        didSet { UserDefaults.standard.set(captionsEnabled, forKey: "captionsEnabled") }
    }
    @Published var voiceGateEnabled: Bool {
        didSet { UserDefaults.standard.set(voiceGateEnabled, forKey: "voiceGateEnabled") }
    }
    @Published var showDebugActivity: Bool {
        didSet { UserDefaults.standard.set(showDebugActivity, forKey: "showDebugActivity") }
    }
    @Published var autoStopEnabled: Bool {
        didSet { UserDefaults.standard.set(autoStopEnabled, forKey: "autoStopEnabled") }
    }
    @Published var liveMode: Bool {
        didSet { UserDefaults.standard.set(liveMode, forKey: "liveMode") }
    }
    @Published var meetingOriginalMix: Double {
        didSet {
            UserDefaults.standard.set(meetingOriginalMix, forKey: "meetingOriginalMix")
            pushMixLevels()
        }
    }
    @Published var myVoiceMix: Double {
        didSet {
            UserDefaults.standard.set(myVoiceMix, forKey: "myVoiceMix")
            pushMixLevels()
        }
    }
    /// nil = idle, "recording" / "playing" while the voice test runs.
    @Published var voiceTestPhase: String?
    /// Non-error notice shown as an orange toast (e.g. idle auto-stop).
    @Published var notice: String?
    // High-frequency streams live in dedicated stores so their updates only
    // re-render the views that draw them (see Stores.swift).
    let levels = LevelStore()
    let captionStore = CaptionStore()
    let insightStore = InsightStore()
    private let insightEngine = InsightEngine()

    @Published var insightEnabled = false {
        didSet {
            UserDefaults.standard.set(insightEnabled, forKey: "insightEnabled")
            if !insightEnabled { insightEngine.stop() }
            else if isRunning { startInsightEngine() }
        }
    }
    @Published var insightContext = "" {
        didSet { UserDefaults.standard.set(insightContext, forKey: "insightContext") }
    }

    func attachInsightDocument(url: URL) {
        let name = url.lastPathComponent
        insightStore.status = "Reading \(name)…"
        Task.detached(priority: .userInitiated) { [weak self] in
            let text = InsightEngine.extractText(from: url)
            await MainActor.run { [weak self] in
                guard let self else { return }
                guard let text, !text.isEmpty else {
                    self.insightStore.status = "Couldn't read \(name)"
                    return
                }
                let doc = InsightStore.Doc(name: name, text: text, digest: nil, isMemorizing: true)
                self.insightStore.docs.append(doc)
                self.memorizeDocument(id: doc.id)
            }
        }
    }

    /// Distills an attached document into a memory brief (mini model, one
    /// small call) so insights start from understanding, not raw text.
    private func memorizeDocument(id: UUID) {
        guard let index = insightStore.docs.firstIndex(where: { $0.id == id }) else { return }
        let doc = insightStore.docs[index]
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else {
            insightStore.docs[index].isMemorizing = false
            insightStore.status = "Add the OpenAI key to memorize files (raw text will be used)"
            return
        }
        insightEngine.apiKey = key
        insightEngine.userLanguageName = Self.languageName(for: userLanguageCode)
        insightStore.status = "Memorizing \(doc.name)…"
        insightEngine.memorize(name: doc.name, text: doc.text) { [weak self] digest in
            Task { @MainActor in
                guard let self,
                      let index = self.insightStore.docs.firstIndex(where: { $0.id == id }) else { return }
                self.insightStore.docs[index].isMemorizing = false
                if let digest, !digest.isEmpty {
                    self.insightStore.docs[index].digest = digest
                    self.insightStore.status = ""
                } else {
                    self.insightStore.status = "Couldn't memorize \(self.insightStore.docs[index].name) — raw text will be used"
                }
            }
        }
    }

    func removeInsightDocument(id: UUID) {
        insightStore.docs.removeAll { $0.id == id }
    }

    private func startInsightEngine() {
        insightEngine.apiKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        insightEngine.userLanguageName = Self.languageName(for: userLanguageCode)
        insightEngine.onInsight = { [weak self] lines in
            Task { @MainActor in
                guard let self else { return }
                self.insightStore.cards.insert(.init(date: Date(), lines: lines), at: 0)
                if self.insightStore.cards.count > 12 {
                    self.insightStore.cards.removeLast(self.insightStore.cards.count - 12)
                }
            }
        }
        insightEngine.onSummary = { [weak self] summary in
            Task { @MainActor in self?.insightStore.summary = summary }
        }
        insightEngine.onStatus = { [weak self] message in
            Task { @MainActor in
                guard let self else { return }
                self.insightStore.status = message
                if !message.isEmpty {
                    self.appendStatus("[insight] \(message)")
                }
            }
        }
        insightEngine.start(
            context: insightContext,
            docs: insightStore.docs.map { ($0.name, $0.text, $0.digest) })
    }
    /// True when the session has been running a while but the meeting side
    /// is dead silent — almost always the meeting app's speaker not routed
    /// to "Interpreter Line Output".
    @Published var noMeetingAudio = false
    private var runningSince: Date?
    private var meetingAudioSeen = false
    private var lastMeetingAudioAt: Date?
    private var sessionTimer: Timer?
    private var lastCheckInMinute = 0
    private var connectionNoticeActive = false

    /// Voices available on the general realtime models (contextual engine).
    static let voices = [
        "marin", "cedar", "alloy", "ash", "ballad",
        "coral", "echo", "sage", "shimmer", "verse",
    ]

    var isDefaultPrompt: Bool {
        interpreterPrompt == RealtimeSession.defaultPromptTemplate
    }

    func resetInterpreterPrompt() {
        interpreterPrompt = RealtimeSession.defaultPromptTemplate
    }

    static let translateModel = "gpt-realtime-translate"
    static let contextualModels = [
        "gpt-realtime-2.1",
        "gpt-realtime-2.1-mini",
        "gpt-realtime-2",
        "gpt-realtime",
    ]
    static let customModelTag = "custom"

    /// The model id the pipeline will actually use.
    var effectiveModel: String {
        guard useContextEngine else { return Self.translateModel }
        if contextModelChoice == Self.customModelTag {
            let trimmed = customContextModel.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? Self.contextualModels[0] : trimmed
        }
        return contextModelChoice
    }
    @Published var apiKey: String = ""
    @Published var geminiApiKey: String = ""
    @Published var provider: String {
        didSet { UserDefaults.standard.set(provider, forKey: "provider") }
    }
    @Published var isRunning = false
    @Published var isStarting = false
    @Published var micMuted = false {
        didSet { pipeline.setMicMuted(micMuted) }
    }
    @Published var translateMeeting: Bool {
        didSet {
            UserDefaults.standard.set(translateMeeting, forKey: "translateMeeting")
            pipeline.setInboundPaused(!translateMeeting)
        }
    }
    @Published var translateMine: Bool {
        didSet {
            UserDefaults.standard.set(translateMine, forKey: "translateMine")
            pipeline.setOutboundEnabled(translateMine)
        }
    }
    @Published var statusLines: [String] = []
    @Published var driverInstalled = false
    @Published var lastError: String?

    struct Language: Identifiable, Hashable {
        let code: String
        let name: String
        var id: String { code }
    }

    /// The 13 output languages supported by gpt-realtime-translate.
    /// (Input language is auto-detected from 70+ languages.)
    static let languages = [
        Language(code: "en", name: "English"),
        Language(code: "vi", name: "Vietnamese"),
        Language(code: "ja", name: "Japanese"),
        Language(code: "ko", name: "Korean"),
        Language(code: "zh", name: "Chinese"),
        Language(code: "fr", name: "French"),
        Language(code: "de", name: "German"),
        Language(code: "es", name: "Spanish"),
        Language(code: "pt", name: "Portuguese"),
        Language(code: "it", name: "Italian"),
        Language(code: "id", name: "Indonesian"),
        Language(code: "hi", name: "Hindi"),
        Language(code: "ru", name: "Russian"),
    ]

    static func languageName(for code: String) -> String {
        languages.first { $0.code == code }?.name ?? code
    }

    private let pipeline = InterpreterPipeline()

    // Caption accumulation: the current in-flight utterance per speaker.
    private var liveCaptionIndex: [Caption.Speaker: Int] = [:]

    init() {
        let defaults = UserDefaults.standard
        selectedMicUID = defaults.string(forKey: "micUID") ?? ""
        selectedOutputUID = defaults.string(forKey: "outputUID") ?? ""
        meetingLanguageCode = defaults.string(forKey: "meetingLangCode") ?? "en"
        userLanguageCode = defaults.string(forKey: "userLangCode") ?? "vi"
        meetingContext = defaults.string(forKey: "meetingContext") ?? ""
        useContextEngine = defaults.bool(forKey: "useContextEngine")
        contextModelChoice = defaults.string(forKey: "contextModelChoice") ?? AppState.contextualModels[0]
        customContextModel = defaults.string(forKey: "customContextModel") ?? ""
        // Defaults to true (conference mode) on first launch.
        voicePassthrough = defaults.object(forKey: "voicePassthrough") == nil
            ? true : defaults.bool(forKey: "voicePassthrough")
        let storedPrompt = defaults.string(forKey: "interpreterPrompt") ?? ""
        interpreterPrompt = storedPrompt.isEmpty ? RealtimeSession.defaultPromptTemplate : storedPrompt
        voice = defaults.string(forKey: "voice") ?? "marin"
        // Defaults to true on first launch.
        spokenHandshake = defaults.object(forKey: "spokenHandshake") == nil
            ? true : defaults.bool(forKey: "spokenHandshake")
        captionsEnabled = defaults.bool(forKey: "captionsEnabled")
        // Defaults to true on first launch.
        voiceGateEnabled = defaults.object(forKey: "voiceGateEnabled") == nil
            ? true : defaults.bool(forKey: "voiceGateEnabled")
        showDebugActivity = defaults.bool(forKey: "showDebugActivity")
        // Defaults to true on first launch.
        autoStopEnabled = defaults.object(forKey: "autoStopEnabled") == nil
            ? true : defaults.bool(forKey: "autoStopEnabled")
        liveMode = defaults.bool(forKey: "liveMode")
        // Meeting translation defaults ON; translating your own voice is
        // opt-in.
        translateMeeting = defaults.object(forKey: "translateMeeting") == nil
            ? true : defaults.bool(forKey: "translateMeeting")
        translateMine = defaults.bool(forKey: "translateMine")
        insightEnabled = defaults.bool(forKey: "insightEnabled")
        insightContext = defaults.string(forKey: "insightContext") ?? ""
        meetingOriginalMix = defaults.object(forKey: "meetingOriginalMix") == nil
            ? 0.15 : defaults.double(forKey: "meetingOriginalMix")
        myVoiceMix = defaults.object(forKey: "myVoiceMix") == nil
            ? 0.15 : defaults.double(forKey: "myVoiceMix")
        provider = defaults.string(forKey: "provider") ?? "openai"
        apiKey = KeychainStore.load(account: KeychainStore.openAIAccount) ?? ""
        // Context-aware engine is shelved for now — force off so the model,
        // status line, and pipeline all stay on the fast translate engine.
        useContextEngine = false
        geminiApiKey = KeychainStore.load(account: KeychainStore.geminiAccount) ?? ""

        pipeline.onStatus = { [weak self] line in
            Task { @MainActor in
                guard let self else { return }
                self.appendStatus(line)
                if line.contains("transcription") {
                    self.insightStore.status = line
                }
            }
        }
        pipeline.onCaption = { [weak self] delta, isFinal, speaker in
            Task { @MainActor in self?.appendCaption(delta: delta, isFinal: isFinal, speaker: speaker) }
        }
        pipeline.onError = { [weak self] message in
            Task { @MainActor in self?.lastError = message }
        }
        pipeline.onSTTTranscript = { [weak self] text, speaker in
            Task { @MainActor in
                guard let self else { return }
                self.insightStore.transcript.append(.init(date: Date(), speaker: speaker, text: text))
                if self.insightStore.transcript.count > 80 {
                    self.insightStore.transcript.removeFirst(self.insightStore.transcript.count - 80)
                }
                self.feedInsight(speaker: speaker, text: text)
            }
        }
        pipeline.onNotice = { [weak self] message in
            Task { @MainActor in
                guard let self else { return }
                if let message {
                    self.notice = message
                    self.connectionNoticeActive = true
                } else if self.connectionNoticeActive {
                    self.notice = nil
                    self.connectionNoticeActive = false
                }
            }
        }
        pipeline.onTestPhase = { [weak self] phase in
            Task { @MainActor in
                self?.voiceTestPhase = phase == "done" ? nil : phase
            }
        }
        pipeline.onLevels = { [weak self] micDb, micOn, meetingDb, meetingOn in
            Task { @MainActor in
                guard let self else { return }
                self.levels.micDb = micDb
                self.levels.micStreaming = micOn
                self.levels.meetingDb = meetingDb
                self.levels.meetingStreaming = meetingOn
                self.evaluateMeetingAudio(meetingDb: self.liveMode ? micDb : meetingDb)
            }
        }

        refreshDevices()
    }

    // MARK: Devices

    var realMics: [AudioDeviceInfo] {
        devices.filter { $0.hasInput && !$0.isVirtualInterpreter }
    }

    var realOutputs: [AudioDeviceInfo] {
        devices.filter { $0.hasOutput && !$0.isVirtualInterpreter }
    }

    func refreshDevices() {
        devices = AudioDevices.all()
        driverInstalled = devices.contains { $0.uid == VirtualDeviceUID.lineOut }
            && devices.contains { $0.uid == VirtualDeviceUID.lineIn }

        // Sensible defaults on first launch.
        if selectedMicUID.isEmpty || !devices.contains(where: { $0.uid == selectedMicUID }) {
            if let defaultID = AudioDevices.defaultDevice(input: true),
               let info = devices.first(where: { $0.id == defaultID && !$0.isVirtualInterpreter }) {
                selectedMicUID = info.uid
            } else {
                selectedMicUID = realMics.first?.uid ?? ""
            }
        }
        if selectedOutputUID.isEmpty || !devices.contains(where: { $0.uid == selectedOutputUID }) {
            if let defaultID = AudioDevices.defaultDevice(input: false),
               let info = devices.first(where: { $0.id == defaultID && !$0.isVirtualInterpreter }) {
                selectedOutputUID = info.uid
            } else {
                selectedOutputUID = realOutputs.first?.uid ?? ""
            }
        }
    }

    // MARK: API key

    func saveAPIKey() {
        apiKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        geminiApiKey = geminiApiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if apiKey.isEmpty {
            KeychainStore.delete(account: KeychainStore.openAIAccount)
        } else {
            KeychainStore.save(apiKey, account: KeychainStore.openAIAccount)
        }
        if geminiApiKey.isEmpty {
            KeychainStore.delete(account: KeychainStore.geminiAccount)
        } else {
            KeychainStore.save(geminiApiKey, account: KeychainStore.geminiAccount)
        }
    }

    var activeProvider: InterpreterPipeline.Provider {
        provider == "gemini" ? .gemini : .openAI
    }

    // MARK: Start / stop

    func toggle() {
        if isRunning {
            stop()
        } else {
            start()
        }
    }

    func start() {
        guard !isStarting, !isRunning else { return }
        lastError = nil
        refreshDevices()

        guard liveMode || driverInstalled else {
            lastError = "Virtual audio driver not installed. Run `make install-driver` in the project folder, then click Refresh."
            return
        }
        let key = (activeProvider == .gemini ? geminiApiKey : apiKey)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else {
            lastError = activeProvider == .gemini
                ? "Enter your Gemini API key first."
                : "Enter your OpenAI API key first."
            return
        }
        guard let mic = devices.first(where: { $0.uid == selectedMicUID }),
              let output = devices.first(where: { $0.uid == selectedOutputUID }) else {
            lastError = "Select a microphone and an output device."
            return
        }

        saveAPIKey()
        micMuted = false
        captionStore.captions.removeAll()
        insightStore.transcript.removeAll()
        insightStore.summary = ""
        liveCaptionIndex.removeAll()

        let config = InterpreterPipeline.Config(
            provider: activeProvider,
            apiKey: key,
            meetingLanguageCode: meetingLanguageCode,
            meetingLanguageName: Self.languageName(for: meetingLanguageCode),
            userLanguageCode: userLanguageCode,
            userLanguageName: Self.languageName(for: userLanguageCode),
            meetingContext: meetingContext,
            useContextEngine: useContextEngine,
            model: effectiveModel,
            interpreterPrompt: interpreterPrompt,
            voice: voice,
            spokenHandshake: spokenHandshake,
            micDeviceID: mic.id,
            outputDeviceID: output.id,
            voicePassthrough: voicePassthrough,
            captionsEnabled: captionsEnabled,
            voiceGateEnabled: voiceGateEnabled,
            meetingOriginalGain: Float(meetingOriginalMix),
            myVoiceOriginalGain: Float(myVoiceMix),
            liveMode: liveMode,
            translateMeeting: translateMeeting,
            translateMine: translateMine,
            insightTranscription: insightEnabled,
            openAIKey: apiKey.trimmingCharacters(in: .whitespacesAndNewlines))

        // Pipeline startup does audio-unit setup and (optionally) waits for
        // TTS rendering — it must never run on the main thread or the UI
        // freezes. TTS itself renders on the main run loop, which stays free.
        isStarting = true
        let pipeline = self.pipeline
        Task.detached(priority: .userInitiated) {
            do {
                try pipeline.start(config: config)
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    self.isStarting = false
                    self.isRunning = true
                    self.runningSince = Date()
                    self.meetingAudioSeen = false
                    self.noMeetingAudio = false
                    self.lastMeetingAudioAt = Date()
                    self.lastCheckInMinute = 0
                    self.startSessionTimer()
                    if self.insightEnabled { self.startInsightEngine() }
                }
            } catch {
                pipeline.stop()
                await MainActor.run { [weak self] in
                    self?.isStarting = false
                    self?.isRunning = false
                    self?.lastError = error.localizedDescription
                }
            }
        }
    }

    func stop() {
        pipeline.stop()
        isRunning = false
        noMeetingAudio = false
        runningSince = nil
        meetingAudioSeen = false
        sessionTimer?.invalidate()
        sessionTimer = nil
        voiceTestPhase = nil
        insightEngine.stop()
    }

    // MARK: Session watchdog — 10-min check-ins, 15-min idle auto-stop

    private func startSessionTimer() {
        sessionTimer?.invalidate()
        sessionTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.sessionTick() }
        }
    }

    private func sessionTick() {
        guard isRunning, autoStopEnabled else { return }

        if let last = lastMeetingAudioAt, Date().timeIntervalSince(last) > 15 * 60 {
            stop()
            notice = "Auto-stopped: no meeting audio for 15 minutes."
            postNotification(
                title: "Cherri stopped itself",
                body: "No meeting audio for 15 minutes — interpretation was stopped to save cost.")
            return
        }

        if let since = runningSince {
            let minutes = Int(Date().timeIntervalSince(since) / 60)
            if minutes > 0, minutes % 10 == 0, minutes != lastCheckInMinute {
                lastCheckInMinute = minutes
                postNotification(
                    title: "Cherri is still interpreting",
                    body: "\(minutes) minutes in. Stop from the menu bar if the meeting is over.")
                appendStatus("Check-in: interpreting for \(minutes) min")
            }
        }
    }

    private func postNotification(title: String, body: String) {
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
        }
    }

    private func pushMixLevels() {
        pipeline.setMixLevels(
            meetingOriginal: Float(meetingOriginalMix),
            myVoiceOriginal: Float(myVoiceMix))
    }

    func testMyVoice() {
        pipeline.startVoiceTest()
    }

    /// Flags a session that has been running for a while without ever
    /// hearing meeting audio; clears the moment audio shows up.
    private func evaluateMeetingAudio(meetingDb: Float) {
        guard isRunning else { return }
        if meetingDb > -55 {
            meetingAudioSeen = true
            lastMeetingAudioAt = Date()
            if noMeetingAudio { noMeetingAudio = false }
            return
        }
        guard !meetingAudioSeen, translateMeeting, !liveMode,
              let since = runningSince,
              Date().timeIntervalSince(since) > 8 else { return }
        if !noMeetingAudio { noMeetingAudio = true }
    }

    // MARK: Captions / status

    private func appendStatus(_ line: String) {
        statusLines.append(line)
        if statusLines.count > 200 {
            statusLines.removeFirst(statusLines.count - 200)
        }
    }

    private func feedInsight(speaker: Caption.Speaker, text: String) {
        guard insightEnabled else { return }
        insightEngine.ingest(speaker: speaker == .you ? "You" : "Them", line: text)
    }

    private static func endsSentence(_ text: String) -> Bool {
        guard let last = text.trimmingCharacters(in: .whitespaces).last else { return false }
        return ".!?…。！？".contains(last)
    }

    private func appendCaption(delta: String, isFinal: Bool, speaker: Caption.Speaker) {
        if isFinal {
            if let index = liveCaptionIndex[speaker], captionStore.captions.indices.contains(index) {
                captionStore.captions[index].isFinal = true
            }
            liveCaptionIndex[speaker] = nil
            return
        }
        guard !delta.isEmpty else { return }
        if let index = liveCaptionIndex[speaker], captionStore.captions.indices.contains(index) {
            captionStore.captions[index].text += delta
            // One sentence per line: close the row at sentence boundaries so
            // the next delta starts fresh.
            if Self.endsSentence(captionStore.captions[index].text) {
                captionStore.captions[index].isFinal = true
                liveCaptionIndex[speaker] = nil
            }
        } else {
            let trimmed = delta.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { return }
            captionStore.captions.append(Caption(speaker: speaker, text: trimmed, isFinal: false))
            if Self.endsSentence(trimmed) {
                captionStore.captions[captionStore.captions.count - 1].isFinal = true
            } else {
                liveCaptionIndex[speaker] = captionStore.captions.count - 1
            }
        }
        if captionStore.captions.count > 100 {
            let removeCount = captionStore.captions.count - 100
            captionStore.captions.removeFirst(removeCount)
            liveCaptionIndex = liveCaptionIndex.mapValues { $0 - removeCount }
        }
    }
}
