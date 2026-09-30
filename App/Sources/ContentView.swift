import SwiftUI

struct ContentView: View {
    @EnvironmentObject var state: AppState
    @AppStorage("showSettings") private var showSettings = true
    @AppStorage("selectedTab") private var selectedTab = "live"
    @State private var showSetupGuide = false

    var body: some View {
        HStack(spacing: 0) {
            mainStage
            if showSettings {
                SettingsSidebar()
                    .frame(width: 330)
                    .transition(.move(edge: .trailing))
            }
        }
        .animation(.spring(duration: 0.35), value: showSettings)
        .background(Color(nsColor: .windowBackgroundColor))
        .frame(minWidth: 640, minHeight: 560)
        .sheet(isPresented: $showSetupGuide) {
            SetupGuideSheet()
        }
    }

    // MARK: Main stage

    private var mainStage: some View {
        ZStack(alignment: .top) {
            VStack(spacing: 0) {
                topBar
                if selectedTab == "insight" {
                    CallInsightView(store: state.insightStore)
                } else {
                    Spacer(minLength: 0)
                    centerSection
                    Spacer(minLength: 0)
                    if state.captionsEnabled {
                        CaptionsStrip(store: state.captionStore)
                            .frame(height: 235)
                    }
                }
            }
            if let error = state.lastError {
                ErrorToast(error: error) { state.lastError = nil }
                    .padding(.top, 44)
                    .padding(.horizontal, 24)
                    .transition(.move(edge: .top).combined(with: .opacity))
            } else if let notice = state.notice {
                NoticeToast(text: notice) { state.notice = nil }
                    .padding(.top, 44)
                    .padding(.horizontal, 24)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Extend up into the (hidden) title-bar strip so the logo row sits
        // on the same line as the traffic lights.
        .ignoresSafeArea(.container, edges: .top)
    }

    private var topBar: some View {
        HStack(spacing: 10) {
            Spacer()
                .frame(width: 56) // traffic lights
            CherriLogo()
            Spacer()
            Picker("", selection: $selectedTab) {
                Text("Live").tag("live")
                Text("Call Insight").tag("insight")
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 220)
            Spacer()
            Button {
                showSetupGuide = true
            } label: {
                Image(systemName: "questionmark")
                    .font(.system(size: 15, weight: .semibold))
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.glass)
            .help("How to set up meeting audio")
            Button {
                showSettings.toggle()
            } label: {
                Image(systemName: "sidebar.right")
                    .font(.system(size: 15, weight: .semibold))
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.glass)
            .keyboardShortcut("0", modifiers: [.command])
            .help("Toggle settings (⌘0)")
        }
        .padding(.horizontal, 14)
        .padding(.top, 4)
    }

    // MARK: Center — orb, visualizer, controls

    private var centerSection: some View {
        VStack(spacing: 22) {
            HStack(spacing: 8) {
                languageSelector(
                    title: state.liveMode ? "Their Language" : "Meeting Language",
                    selection: $state.meetingLanguageCode,
                    edge: .trailing)
                OrbLive(
                    levels: state.levels,
                    isRunning: state.isRunning,
                    isStarting: state.isStarting,
                    micMuted: state.micMuted,
                    inboundPaused: !state.translateMeeting
                ) {
                    state.toggle()
                }
                languageSelector(
                    title: "My Language",
                    selection: $state.userLanguageCode,
                    edge: .leading)
            }

            VStack(spacing: 6) {
                Text(statusTitle)
                    .font(.system(.title3, design: .rounded).weight(.medium))
                    .contentTransition(.opacity)
                Text(statusSubtitle)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 12) {
                Button {
                    state.translateMeeting.toggle()
                } label: {
                    Label("\(state.liveMode ? "Them" : "Meeting") → \(AppState.languageName(for: state.userLanguageCode))",
                          systemImage: state.translateMeeting ? "checkmark.circle.fill" : "circle")
                }
                .buttonStyle(.glass)
                .tint(state.translateMeeting ? .blue : nil)
                .keyboardShortcut("p", modifiers: [.command])
                .help("Translate the \(state.liveMode ? "other side" : "meeting") for you (⌘P). Off: you hear the original only, nothing streams inbound.")

                Button {
                    state.translateMine.toggle()
                } label: {
                    Label("Me → \(AppState.languageName(for: state.meetingLanguageCode))",
                          systemImage: state.translateMine ? "checkmark.circle.fill" : "circle")
                }
                .buttonStyle(.glass)
                .tint(state.translateMine ? .green : nil)
                .keyboardShortcut("t", modifiers: [.command])
                .help(state.liveMode
                      ? "Master translation switch in Live mode (⌘T). Off: nothing is translated — the shared mic can't tell speakers apart."
                      : "Translate your voice for them (⌘T). Off: they hear only your real voice, nothing streams outbound.")

                if state.isRunning {
                    Button {
                        state.micMuted.toggle()
                    } label: {
                        Label(state.micMuted ? "Unmute" : "Mute",
                              systemImage: state.micMuted ? "mic.slash.fill" : "mic.fill")
                    }
                    .buttonStyle(.glass)
                    .tint(state.micMuted ? .red : nil)
                    .keyboardShortcut("m", modifiers: [.command])
                    .help("Mute your mic entirely (⌘M)")
                }
            }

            if !state.isRunning && !state.driverInstalled && !state.liveMode {
                Label("Audio driver not installed — run `make install-driver`", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            if state.noMeetingAudio {
                HStack(spacing: 8) {
                    Image(systemName: "speaker.slash.fill")
                        .foregroundStyle(.orange)
                    Text("No meeting audio detected")
                        .foregroundStyle(.secondary)
                    Button("Set up meeting audio…") { showSetupGuide = true }
                        .buttonStyle(.link)
                }
                .font(.callout)
                .transition(.opacity)
            }
        }
        .padding(.horizontal, 24)
        .animation(.easeInOut(duration: 0.25), value: state.noMeetingAudio)
    }

    /// Titled language dropdown beside the pulse: light face, opens the
    /// full language menu on click. Locked while interpreting.
    private func languageSelector(title: String, selection: Binding<String>, edge: Alignment) -> some View {
        VStack(alignment: edge == .trailing ? .trailing : .leading, spacing: 5) {
            Text(title)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.tertiary)
                .textCase(.uppercase)
            Menu {
                Picker("", selection: selection) {
                    ForEach(AppState.languages) { Text($0.name).tag($0.code) }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            } label: {
                HStack(spacing: 5) {
                    Text(AppState.languageName(for: selection.wrappedValue))
                        .font(.system(.title2, design: .rounded).weight(.light))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                    Image(systemName: "chevron.down")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
            }
            .menuIndicator(.hidden)
            .buttonStyle(.plain)
            .fixedSize()
            .disabled(state.isRunning || state.isStarting)
            .opacity(state.isRunning || state.isStarting ? 0.6 : 1)
        }
        .frame(maxWidth: .infinity, alignment: edge)
    }

    private var statusTitle: String {
        if state.isStarting { return "Starting…" }
        if state.isRunning { return "Interpreting" }
        return "Ready"
    }

    private var statusSubtitle: String {
        let engine = state.provider == "gemini" ? "Gemini Live Translate" : state.effectiveModel
        if state.isRunning || state.isStarting {
            return state.liveMode ? "\(engine) · live conversation" : engine
        }
        return state.liveMode ? "Live conversation — mic & speaker only" : "Live meeting interpreter"
    }
}

// MARK: - Orb + visualizer

/// Thin wrapper observing the high-frequency level store, so level ticks
/// re-render only the orb — not the whole window.
private struct OrbLive: View {
    @ObservedObject var levels: LevelStore
    let isRunning: Bool
    let isStarting: Bool
    let micMuted: Bool
    let inboundPaused: Bool
    let action: () -> Void

    private func normalized(_ db: Float) -> Double {
        Double(min(max((db + 55) / 45, 0), 1))
    }

    var body: some View {
        Orb(
            isRunning: isRunning,
            isStarting: isStarting,
            micLevel: normalized(levels.micDb),
            meetingLevel: normalized(levels.meetingDb),
            micActive: levels.micStreaming && !micMuted,
            meetingActive: levels.meetingStreaming && !inboundPaused,
            action: action)
    }
}

/// The heart of the app: a large circular start/stop control surrounded by
/// pulse rings and, while running, a radial audio visualizer — left arc
/// reacts to the meeting, right arc to your mic.
private struct Orb: View {
    let isRunning: Bool
    let isStarting: Bool
    let micLevel: Double
    let meetingLevel: Double
    let micActive: Bool
    let meetingActive: Bool
    let action: () -> Void

    // Temporal smoothing lives in a reference type so the Canvas can update
    // it without touching SwiftUI state during rendering.
    private final class Smoother {
        var mic: Double = 0
        var meeting: Double = 0
        var lastTime: Double = 0
        func step(mic target1: Double, meeting target2: Double, time: Double) {
            let dt = min(max(time - lastTime, 0), 0.1)
            lastTime = time
            let up = 1 - exp(-dt / 0.045)   // fast attack
            let down = 1 - exp(-dt / 0.28)  // slow release
            mic += (target1 - mic) * (target1 > mic ? up : down)
            meeting += (target2 - meeting) * (target2 > meeting ? up : down)
        }
    }
    @State private var smoother = Smoother()

    private let size: CGFloat = 320
    private let orbRadius: CGFloat = 74

    var body: some View {
        TimelineView(.animation(minimumInterval: isRunning ? 1.0 / 30.0 : 1.0 / 10.0)) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            ZStack {
                pulseRings(t)
                if isRunning {
                    visualizerBars(t)
                }
                orbButton(t)
            }
            .frame(width: size, height: size)
        }
    }

    // Expanding, fading circles emanating from the center.
    @ViewBuilder
    private func pulseRings(_ t: Double) -> some View {
        let activity = isRunning ? 0.35 + 0.65 * max(smoother.mic, smoother.meeting) : 0.35
        let period = isRunning ? 2.4 : 4.0
        ForEach(0..<3, id: \.self) { i in
            let progress = ((t / period) + Double(i) / 3).truncatingRemainder(dividingBy: 1)
            Circle()
                .stroke(ringColor.opacity((1 - progress) * 0.28 * activity), lineWidth: 1.5)
                .frame(width: orbRadius * 2 + CGFloat(progress) * (size - orbRadius * 2),
                       height: orbRadius * 2 + CGFloat(progress) * (size - orbRadius * 2))
        }
    }

    private var ringColor: Color { isRunning ? .accentColor : .secondary }

    // Radial bars around the orb: left half = meeting (blue), right = mic (green).
    private func visualizerBars(_ t: Double) -> some View {
        Canvas { context, canvasSize in
            smoother.step(mic: micActive ? micLevel : 0,
                          meeting: meetingActive ? meetingLevel : 0,
                          time: t)
            let center = CGPoint(x: canvasSize.width / 2, y: canvasSize.height / 2)
            let barCount = 72
            let inner = orbRadius + 14
            let maxLength: CGFloat = 44

            for i in 0..<barCount {
                let angle = (Double(i) / Double(barCount)) * 2 * .pi - .pi / 2
                let isRightSide = cos(angle) >= 0
                let level = isRightSide ? smoother.mic : smoother.meeting
                // Per-bar pseudo-random motion so a flat level still shimmers.
                let seed = Double(i) * 12.9898
                let wobble = 0.4 + 0.6 * abs(sin(t * (1.6 + seed.truncatingRemainder(dividingBy: 1.7)) + seed))
                let length = 3 + CGFloat(level * wobble) * maxLength

                let direction = CGPoint(x: cos(angle), y: sin(angle))
                let from = CGPoint(x: center.x + direction.x * inner,
                                   y: center.y + direction.y * inner)
                let to = CGPoint(x: center.x + direction.x * (inner + length),
                                 y: center.y + direction.y * (inner + length))

                var path = Path()
                path.move(to: from)
                path.addLine(to: to)

                let color: Color = isRightSide ? .green : .blue
                let alive = isRightSide ? micActive : meetingActive
                context.stroke(path,
                               with: .color(color.opacity(alive ? 0.35 + 0.65 * level : 0.15)),
                               style: StrokeStyle(lineWidth: 3, lineCap: .round))
            }
        }
        .frame(width: size, height: size)
    }

    private func orbButton(_ t: Double) -> some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .fill(
                        LinearGradient(
                            colors: isRunning
                                ? [Color.red.opacity(0.85), Color.red]
                                : [Color.accentColor.opacity(0.85), Color.accentColor],
                            startPoint: .topLeading, endPoint: .bottomTrailing)
                    )
                Circle()
                    .strokeBorder(.white.opacity(0.25), lineWidth: 1)
                if isStarting {
                    ProgressView()
                        .controlSize(.large)
                        .tint(.white)
                } else {
                    Image(systemName: isRunning ? "stop.fill" : "play.fill")
                        .font(.system(size: 42, weight: .bold))
                        .foregroundStyle(.white)
                        .offset(x: isRunning ? 0 : 3)
                }
            }
            .frame(width: orbRadius * 2, height: orbRadius * 2)
            .shadow(color: (isRunning ? Color.red : Color.accentColor).opacity(0.45),
                    radius: 24, y: 6)
            .scaleEffect(isRunning ? 1.0 : 1.0 + 0.015 * sin(t * 2))
        }
        .buttonStyle(.plain)
        .disabled(isStarting)
        .keyboardShortcut(.return, modifiers: [.command])
        .help(isRunning ? "Stop interpreting (⌘↩)" : "Start interpreting (⌘↩)")
    }
}

// MARK: - Captions strip

private struct CaptionsStrip: View {
    @EnvironmentObject var state: AppState
    @ObservedObject var store: CaptionStore

    var body: some View {
        VStack(spacing: 0) {
            Divider()
            if state.liveMode {
                // One room, one interpreter: a single chronological feed.
                LiveCaptionFeed(
                    myLanguage: AppState.languageName(for: state.userLanguageCode),
                    theirLanguage: AppState.languageName(for: state.meetingLanguageCode),
                    captions: store.captions)
            } else {
                HStack(spacing: 0) {
                    CaptionFeed(
                        title: "Them → \(AppState.languageName(for: state.userLanguageCode))",
                        accent: .blue,
                        captions: store.captions.filter { $0.speaker == .them })
                    Divider()
                    CaptionFeed(
                        title: "You → \(AppState.languageName(for: state.meetingLanguageCode))",
                        accent: .green,
                        captions: store.captions.filter { $0.speaker == .you })
                }
            }
        }
        .background(Color(nsColor: .windowBackgroundColor).opacity(0.6))
    }
}

/// Live mode: every translated utterance in one stream, a colored dot marking
/// the direction (blue = into my language, green = into theirs).
private struct LiveCaptionFeed: View {
    let myLanguage: String
    let theirLanguage: String
    let captions: [Caption]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Text("Interpreter")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                Spacer()
                HStack(spacing: 4) {
                    Circle().fill(Color.blue).frame(width: 6, height: 6)
                    Text("→ \(myLanguage)")
                    Circle().fill(Color.green).frame(width: 6, height: 6)
                        .padding(.leading, 6)
                    Text("→ \(theirLanguage)")
                }
                .font(.caption2)
                .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        ForEach(captions) { caption in
                            HStack(alignment: .firstTextBaseline, spacing: 10) {
                                Circle()
                                    .fill(caption.speaker == .them ? Color.blue : Color.green)
                                    .frame(width: 7, height: 7)
                                Text(caption.text)
                                    .font(.system(.title3, design: .rounded))
                                    .lineSpacing(3)
                                    .opacity(caption.isFinal ? 1.0 : 0.65)
                                    .contentTransition(.opacity)
                                    .animation(.easeOut(duration: 0.25), value: caption.text)
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .id(caption.id)
                            .transition(.opacity.combined(with: .move(edge: .bottom)))
                        }
                    }
                    .animation(.easeOut(duration: 0.3), value: captions.count)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 12)
                }
                .onChange(of: captions.last?.text) { _, _ in
                    if let last = captions.last {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity)
    }
}

private struct CaptionFeed: View {
    let title: String
    let accent: Color
    let captions: [Caption]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Circle().fill(accent).frame(width: 6, height: 6)
                Text(title)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        ForEach(captions) { caption in
                            Text(caption.text)
                                .font(.system(.title3, design: .rounded))
                                .lineSpacing(3)
                                .opacity(caption.isFinal ? 1.0 : 0.65)
                                .contentTransition(.opacity)
                                .animation(.easeOut(duration: 0.25), value: caption.text)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .id(caption.id)
                                .transition(.opacity.combined(with: .move(edge: .bottom)))
                        }
                    }
                    .animation(.easeOut(duration: 0.3), value: captions.count)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 12)
                }
                .onChange(of: captions.last?.text) { _, _ in
                    if let last = captions.last {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Error toast

private struct ErrorToast: View {
    let error: String
    let dismiss: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.octagon.fill")
                .foregroundStyle(.red)
            Text(error)
                .font(.caption)
                .textSelection(.enabled)
                .lineLimit(3)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button("Copy") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(error, forType: .string)
            }
            .controlSize(.small)
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
            }
            .controlSize(.small)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .glassEffect(.regular.tint(.red.opacity(0.25)), in: RoundedRectangle(cornerRadius: 14))
        .frame(maxWidth: 560)
    }
}

// MARK: - Settings sidebar

private struct SettingsSidebar: View {
    @EnvironmentObject var state: AppState

    private var locked: Bool { state.isRunning || state.isStarting }

    private var voiceTestLabel: String {
        switch state.voiceTestPhase {
        case "recording": return "Recording — speak now…"
        case "playing": return "Playing back…"
        default: return "Test my voice (10 s)"
        }
    }

    /// Explainer line under a settings control.
    private func caption(_ text: String) -> some View {
        Text(text)
            .font(.caption2)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    var body: some View {
        Form {
            Group {
            Section("Mode") {
                Picker("", selection: $state.liveMode) {
                    Text("Meeting").tag(false)
                    Text("Live").tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                caption(state.liveMode
                        ? "Live conversation: in-person two-way interpretation using only your microphone and speaker. No meeting app or virtual devices involved."
                        : "Meeting: sits between your meeting app and your real devices via the Interpreter virtual devices.")
            }
            Section("Languages") {
                Picker("Meeting Language", selection: $state.meetingLanguageCode) {
                    ForEach(AppState.languages) { Text($0.name).tag($0.code) }
                }
                caption("The language the meeting speaks — your voice is translated into this for them.")
                Picker("My Language", selection: $state.userLanguageCode) {
                    ForEach(AppState.languages) { Text($0.name).tag($0.code) }
                }
                caption("Your language — the meeting is translated into this for you. Spoken input is always auto-detected; these set what each side hears.")
                Toggle("Live captions", isOn: $state.captionsEnabled)
                caption("Shows translated text below the stage. Off saves cost — on Gemini, transcription is a billed extra. Takes effect on the next Start.")
            }

            Section("Devices") {
                Picker("Microphone", selection: $state.selectedMicUID) {
                    ForEach(state.realMics) { device in
                        Text(device.name).tag(device.uid)
                    }
                }
                caption("Your real microphone — what you say is captured here, echo-cancelled, then translated.")
                Picker("Speakers", selection: $state.selectedOutputUID) {
                    ForEach(state.realOutputs) { device in
                        Text(device.name).tag(device.uid)
                    }
                }
                caption("Your real speakers or headphones — the meeting plays here with its translation overdubbed on top.")
                Button("Refresh devices") { state.refreshDevices() }
                    .controlSize(.small)
                caption("Re-scan after plugging in or removing audio hardware.")
            }

            Section("My voice") {
                Toggle("Voice-activated streaming", isOn: $state.voiceGateEnabled)
                caption("Streams audio to the API only while speech is detected — silence costs nothing. A short pre-roll keeps word onsets intact.")
                if !state.liveMode {
                    Toggle("Conference mode", isOn: $state.voicePassthrough)
                    caption(state.voicePassthrough
                            ? "While translating: the meeting hears your real voice continuously, dimmed under the interpreter — like a conference feed."
                            : "While translating: the meeting hears only the translated voice. (With translation off, your real voice always passes through.)")
                }
            }

            Section("Translation service") {
                Picker("Provider", selection: $state.provider) {
                    Text("OpenAI").tag("openai")
                    Text("Google Gemini").tag("gemini")
                }
                .pickerStyle(.segmented)
                caption("Which AI service interprets. Each provider needs its own API key; both keys are kept in your login keychain.")
                if state.provider == "gemini" {
                    SecureField("Gemini API key (AIza…)", text: $state.geminiApiKey)
                        .onSubmit { state.saveAPIKey() }
                    caption("From aistudio.google.com. Gemini uses gemini-3.5-live-translate-preview: streaming translation with adaptive voice, but no prompts or meeting context.")
                } else {
                    SecureField("OpenAI API key (sk-…)", text: $state.apiKey)
                        .onSubmit { state.saveAPIKey() }
                    caption("From platform.openai.com, with Realtime API access.")
                }
            }
            }
            .disabled(locked)

            if !state.liveMode {
            Section("Mixer") {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Meeting original voice")
                        Spacer()
                        Text("\(Int(state.meetingOriginalMix * 100))%")
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    Slider(value: $state.meetingOriginalMix, in: 0...1)
                }
                caption("How loud the original meeting voices stay under the translation you hear. 0% = translation only. Adjustable live.")
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("My original voice")
                        Spacer()
                        Text("\(Int(state.myVoiceMix * 100))%")
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    Slider(value: $state.myVoiceMix, in: 0...1)
                        .disabled(!state.voicePassthrough)
                }
                caption(state.voicePassthrough
                        ? "How loud your real voice stays under the dub the meeting hears. 0% = dub only. Adjustable live."
                        : "Enable Conference mode to mix your real voice under the dub.")
                Button(voiceTestLabel) { state.testMyVoice() }
                    .disabled(!state.isRunning || state.voiceTestPhase != nil)
                caption("Records 10 seconds of exactly what the meeting hears from you (dub + your voice at the mixer level), then plays it back on your speakers. Available while interpreting.")
            }
            }

            Section("Advanced") {
                Toggle("Session check-ins & auto-stop", isOn: $state.autoStopEnabled)
                caption("Every 10 minutes a notification confirms Cherri is still interpreting; after 15 minutes with no meeting audio the session stops itself to save cost.")
                Toggle("Show debug activity", isOn: $state.showDebugActivity)
                caption("Reveals the technical activity log at the bottom of this panel — connection status, reconnects, and API errors.")
            }

        }
        .formStyle(.grouped)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if state.showDebugActivity {
                activityFooter
            }
        }
    }

    /// Always interactive, even while interpreting — that's when the log
    /// matters most.
    private var activityFooter: some View {
        VStack(alignment: .leading, spacing: 0) {
            Divider()
            HStack {
                Text("Activity")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                Spacer()
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(state.statusLines.joined(separator: "\n"), forType: .string)
                } label: {
                    Image(systemName: "doc.on.doc")
                }
                .buttonStyle(.borderless)
                .controlSize(.mini)
                .help("Copy the full status log")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            ScrollView {
                VStack(alignment: .leading, spacing: 3) {
                    if state.statusLines.isEmpty {
                        Text("No activity yet.")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.tertiary)
                    }
                    ForEach(Array(state.statusLines.suffix(6).enumerated()), id: \.offset) { _, line in
                        Text(line)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .padding(.bottom, 8)
            }
            .frame(height: 74)
        }
        .background(.bar)
    }
}


// MARK: - Notice toast

private struct NoticeToast: View {
    let text: String
    let dismiss: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "moon.zzz.fill")
                .foregroundStyle(.orange)
            Text(text)
                .font(.caption)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
            }
            .controlSize(.small)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .glassEffect(.regular.tint(.orange.opacity(0.25)), in: RoundedRectangle(cornerRadius: 14))
        .frame(maxWidth: 560)
    }
}

// MARK: - Setup guide

private struct SetupGuideSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Route your meeting audio through Cherri")
                .font(.system(.title2, design: .rounded).weight(.semibold))
            Text("In your meeting app (Zoom, Teams, Meet, …) open the audio / sound device settings and pick Cherri's virtual devices:")
                .foregroundStyle(.secondary)

            guideRow(icon: "speaker.wave.2.fill", accent: .blue,
                     title: "Speaker → “Interpreter Line Output”",
                     detail: "The meeting's voices flow into Cherri, get translated, and play on your real speakers with the original dimmed underneath.")
            guideRow(icon: "mic.fill", accent: .green,
                     title: "Microphone → “Interpreter Line Input”",
                     detail: "The meeting hears your translated voice (plus your real voice dimmed, in conference mode).")
            guideRow(icon: "gearshape.fill", accent: .secondary,
                     title: "Where each app hides it",
                     detail: "Zoom: Settings → Audio. Teams: Settings → Devices. Meet/browser calls: the gear inside the call, or the browser's site audio settings.")
            guideRow(icon: "macwindow", accent: .secondary,
                     title: "Leave the Mac itself alone",
                     detail: "Keep System Settings → Sound on your real speakers and mic — only the meeting app should use the Interpreter devices. Your real devices are chosen inside Cherri.")

            HStack {
                Text("The “No meeting audio” warning clears by itself once sound arrives from the meeting app.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                Spacer()
                Button("Done") { dismiss() }
                    .buttonStyle(.glassProminent)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.top, 4)
        }
        .padding(24)
        .frame(width: 500)
    }

    private func guideRow(icon: String, accent: Color, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(accent)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.callout.weight(.medium))
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}


// MARK: - Logo

/// Text-type wordmark with a small cherry mark: two stems, leaf, one cherry
/// per language side is overkill — one cherry, lowercase rounded wordmark.
private struct CherriLogo: View {
    var body: some View {
        HStack(spacing: 6) {
            CherryMark()
                .frame(width: 18, height: 18)
            Text("cherri")
                .font(.system(size: 17, weight: .semibold, design: .rounded))
                .kerning(0.3)
                .foregroundStyle(.primary)
        }
        .accessibilityLabel("Cherri")
    }
}

private struct CherryMark: View {
    var body: some View {
        Canvas { ctx, size in
            let w = size.width, h = size.height
            let green = Color(red: 0.38, green: 0.66, blue: 0.38)

            var stem = Path()
            stem.move(to: CGPoint(x: 0.46 * w, y: 0.52 * h))
            stem.addQuadCurve(to: CGPoint(x: 0.72 * w, y: 0.08 * h),
                              control: CGPoint(x: 0.42 * w, y: 0.16 * h))
            ctx.stroke(stem, with: .color(green),
                       style: StrokeStyle(lineWidth: 1.8, lineCap: .round))

            var leaf = Path()
            let tip = CGPoint(x: 0.72 * w, y: 0.08 * h)
            leaf.move(to: tip)
            leaf.addQuadCurve(to: CGPoint(x: 0.98 * w, y: 0.22 * h),
                              control: CGPoint(x: 0.92 * w, y: 0.02 * h))
            leaf.addQuadCurve(to: tip,
                              control: CGPoint(x: 0.76 * w, y: 0.26 * h))
            ctx.fill(leaf, with: .color(green))

            let cherry = CGRect(x: 0.16 * w, y: 0.42 * h, width: 0.58 * w, height: 0.58 * h)
            ctx.fill(Path(ellipseIn: cherry),
                     with: .linearGradient(
                        Gradient(colors: [Color(red: 0.95, green: 0.30, blue: 0.38),
                                          Color(red: 0.72, green: 0.10, blue: 0.20)]),
                        startPoint: CGPoint(x: 0.3 * w, y: 0.42 * h),
                        endPoint: CGPoint(x: 0.6 * w, y: h)))
            let highlight = CGRect(x: 0.26 * w, y: 0.52 * h, width: 0.16 * w, height: 0.12 * h)
            ctx.fill(Path(ellipseIn: highlight), with: .color(.white.opacity(0.35)))
        }
    }
}
