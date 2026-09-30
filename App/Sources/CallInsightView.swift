import SwiftUI
import UniformTypeIdentifiers

/// Call Insight tab: pre-load documents and context, then get short live
/// bullets (topics to raise, suggested answers) while the meeting runs.
struct CallInsightView: View {
    @EnvironmentObject var state: AppState
    @ObservedObject var store: InsightStore
    @State private var showImporter = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            controls
            preparation
            Divider()
            HStack(alignment: .top, spacing: 14) {
                transcriptPanel
                    .frame(width: 250)
                Divider()
                insightFeed
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 8)
        .fileImporter(
            isPresented: $showImporter,
            allowedContentTypes: [.pdf, .image, .plainText]
                + ["pptx", "docx"].compactMap { UTType(filenameExtension: $0) },
            allowsMultipleSelection: true
        ) { result in
            if case .success(let urls) = result {
                for url in urls {
                    state.attachInsightDocument(url: url)
                }
            }
        }
    }

    // MARK: Controls

    private var controls: some View {
        HStack(spacing: 12) {
            Toggle(isOn: $state.insightEnabled) {
                Text("Live insights")
                    .font(.system(.body, design: .rounded).weight(.medium))
            }
            .toggleStyle(.switch)

            Button {
                showImporter = true
            } label: {
                Label("Add files", systemImage: "paperclip")
            }
            .buttonStyle(.glass)

            Spacer()

            InsightAudioActivity(levels: state.levels)

            if !store.status.isEmpty {
                Text(store.status)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .lineLimit(1)
            } else if state.insightEnabled && state.isRunning {
                HStack(spacing: 5) {
                    Circle().fill(Color.purple).frame(width: 7, height: 7)
                    Text("Watching the conversation")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else if state.insightEnabled {
                Text("Waiting for Start — works with or without translation")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: Preparation (docs + context)

    private var preparation: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !store.docs.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(store.docs) { doc in
                            HStack(spacing: 5) {
                                if doc.isMemorizing {
                                    ProgressView()
                                        .controlSize(.mini)
                                } else {
                                    Image(systemName: doc.digest != nil ? "brain.fill" : "doc.text")
                                        .font(.caption)
                                        .foregroundStyle(doc.digest != nil ? Color.purple : Color.secondary)
                                }
                                Text(doc.name)
                                    .font(.caption)
                                    .lineLimit(1)
                                Button {
                                    state.removeInsightDocument(id: doc.id)
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .font(.caption)
                                        .foregroundStyle(.tertiary)
                                }
                                .buttonStyle(.plain)
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .glassEffect(.regular, in: Capsule())
                        }
                    }
                }
            }

            TextEditor(text: $state.insightContext)
                .font(.callout)
                .frame(height: 64)
                .scrollContentBackground(.hidden)
                .padding(8)
                .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 12))
                .overlay(alignment: .topLeading) {
                    if state.insightContext.isEmpty {
                        Text("Pre-context: what this meeting is about, your goals, who's there, what you want out of it…")
                            .font(.callout)
                            .foregroundStyle(.tertiary)
                            .padding(.top, 9)
                            .padding(.leading, 13)
                            .allowsHitTesting(false)
                    }
                }
            Text("Files are read locally (PDF, PowerPoint, Word, image OCR), then memorized by the mini model into a compact brief the moment you add them — the brain icon means ready. A mini model watches the talk (~every 20 s, a few tokens) and engages the smarter model only when something actually needs you — a question, objection, or decision. Changes apply on the next Start.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }

    // MARK: Transcript panel

    private var transcriptPanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Transcript")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
                .padding(.bottom, 6)
            if store.transcript.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "waveform.and.mic")
                        .foregroundStyle(.quaternary)
                    Text(state.isRunning && state.insightEnabled
                         ? "Listening — nothing transcribed yet"
                         : "Transcripts appear here while running")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.top, 40)
                Spacer()
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 7) {
                            ForEach(store.transcript) { line in
                                HStack(alignment: .firstTextBaseline, spacing: 6) {
                                    Circle()
                                        .fill(line.speaker == .them ? Color.blue : Color.green)
                                        .frame(width: 5, height: 5)
                                    Text(line.text)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .textSelection(.enabled)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }
                                .id(line.id)
                            }
                        }
                        .padding(.bottom, 8)
                    }
                    .onChange(of: store.transcript.last?.id) { _, _ in
                        if let last = store.transcript.last {
                            proxy.scrollTo(last.id, anchor: .bottom)
                        }
                    }
                }
            }
        }
    }

    // MARK: Insight feed

    private var insightFeed: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    if !store.summary.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Meeting so far")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.secondary)
                                .textCase(.uppercase)
                            ForEach(Array(store.summary.split(separator: "\n").enumerated()), id: \.offset) { _, line in
                                Text(line.trimmingCharacters(in: CharacterSet(charactersIn: " -•\t")))
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                                    .textSelection(.enabled)
                            }
                        }
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.secondary.opacity(0.07), in: RoundedRectangle(cornerRadius: 12))
                    }
                    if store.cards.isEmpty {
                        VStack(spacing: 10) {
                            Image(systemName: "lightbulb.max")
                                .font(.system(size: 34))
                                .foregroundStyle(.tertiary)
                            Text(state.insightEnabled
                                 ? "Insights appear here as the conversation develops"
                                 : "Turn on Live insights, add your files, then Start the session")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.top, 60)
                    }
                    ForEach(store.cards) { card in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(card.date, style: .time)
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                            ForEach(Array(card.lines.enumerated()), id: \.offset) { _, line in
                                HStack(alignment: .firstTextBaseline, spacing: 10) {
                                    Circle()
                                        .fill(Color.purple.opacity(0.7))
                                        .frame(width: 7, height: 7)
                                        .offset(y: -3)
                                    Text(line)
                                        .font(.system(.title3, design: .rounded))
                                        .lineSpacing(3)
                                        .textSelection(.enabled)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }
                            }
                        }
                        .padding(14)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 16))
                        .id(card.id)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                    }
                }
                .animation(.easeOut(duration: 0.3), value: store.cards.count)
                .padding(.bottom, 16)
            }
        }
    }
}


/// Compact live audio meters for the insight tab: green dot while that
/// source is actually streaming to the APIs, bar shows level.
private struct InsightAudioActivity: View {
    @ObservedObject var levels: LevelStore

    var body: some View {
        HStack(spacing: 14) {
            meter("Mic", db: levels.micDb, active: levels.micStreaming)
            meter("Meeting", db: levels.meetingDb, active: levels.meetingStreaming)
        }
    }

    private func meter(_ label: String, db: Float, active: Bool) -> some View {
        let fraction = CGFloat(min(max((db + 60) / 60, 0), 1))
        return HStack(spacing: 5) {
            Circle()
                .fill(active ? Color.green : Color.secondary.opacity(0.3))
                .frame(width: 6, height: 6)
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
            ZStack(alignment: .leading) {
                Capsule().fill(Color.secondary.opacity(0.2))
                Capsule()
                    .fill(active ? Color.green : Color.secondary.opacity(0.5))
                    .frame(width: max(40 * fraction, 2))
            }
            .frame(width: 40, height: 4)
        }
    }
}
