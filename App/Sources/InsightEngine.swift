import AppKit
import Foundation
import PDFKit
import Vision

/// Call Insight state observed by the insight view only.
@MainActor
final class InsightStore: ObservableObject {
    struct Card: Identifiable {
        let id = UUID()
        let date: Date
        let lines: [String]
    }

    struct Doc: Identifiable {
        let id = UUID()
        let name: String
        let text: String
        /// Compact memory brief distilled by the mini model on attach; the
        /// insight prompt uses this instead of raw (truncated) text.
        var digest: String?
        var isMemorizing = false
    }

    struct TranscriptLine: Identifiable {
        let id = UUID()
        let date: Date
        let speaker: Caption.Speaker
        let text: String
    }

    @Published var cards: [Card] = []
    @Published var status = ""
    @Published var docs: [Doc] = []
    /// Raw transcribed utterances, newest last — visible proof of hearing.
    @Published var transcript: [TranscriptLine] = []
    /// Continuously maintained summary of the whole conversation so far.
    @Published var summary = ""
}

/// Feeds the live transcript to a chat model in cost-controlled chunks and
/// returns short bullet insights (topics to raise, suggested answers).
///
/// Cost design, two tiers: every chunk (≤1 per 20 s, ≥120 new chars) a MINI
/// router model answers YES/NO — "does the user need help right now?" — for
/// a handful of tokens. Only on YES is the smart model engaged with the full
/// documents+context prompt (kept byte-stable for OpenAI prompt caching) to
/// write the bullets. Silence and small talk never touch the big model.
final class InsightEngine: @unchecked Sendable {

    var apiKey = ""
    /// Tier 1: cheap watcher — decides if this moment needs help at all.
    var routerModel = "gpt-5-mini"
    /// Tier 2: engaged only when the router says YES — writes the bullets.
    var smartModel = "gpt-5"
    var userLanguageName = "English"

    var onInsight: (([String]) -> Void)?
    var onStatus: ((String) -> Void)?
    /// Updated running summary of the conversation (mini model, continuous).
    var onSummary: ((String) -> Void)?

    private let queue = DispatchQueue(label: "cherri.insight")
    private var timer: Timer?
    private var systemPrompt = ""
    private var pending = ""        // new speech since the last request
    private var recent = ""         // rolling conversation window
    private var lastSent = Date.distantPast
    private var inFlight = false
    private var running = false
    private var totalIngestedChars = 0
    private var sentFirstCard = false
    // Running conversation summary: folded forward by the mini model so long
    // meetings keep context beyond the short rolling window.
    private var conversationSummary = ""
    private var summaryPending = ""
    private var summaryInFlight = false

    private static let minInterval: TimeInterval = 20
    private static let minNewChars = 120
    private static let recentWindowChars = 2500

    // MARK: Lifecycle

    /// Builds the stable system prompt (kept identical across requests for
    /// prompt caching) and starts the tick timer. Docs with a digest use it
    /// (full coverage, compact); undigested docs fall back to raw prefix.
    func start(context: String, docs: [(name: String, text: String, digest: String?)]) {
        var docsBlock = ""
        for doc in docs {
            let content = doc.digest ?? String(doc.text.prefix(3000))
            docsBlock += "\n--- Document memory: \(doc.name) ---\n\(content)\n"
        }
        let contextBlock = String(context.prefix(1500))

        systemPrompt = """
        You are Call Insight, a silent copilot for the user (the transcript \
        speaker labeled "You") during a live meeting. You never speak in the \
        meeting; you write short cues that help the user continue their \
        current conversation.

        Respond with 3 to 6 bullets, each on its own line starting with \
        "- ", each at most 12 words, written in \(userLanguageName). \
        Prioritize in this order:
        1. Suggested answers or replies to the question/topic on the table.
        2. Sharp follow-up questions or next topics worth raising.
        3. Facts from the documents/context relevant RIGHT NOW.
        No headers, no preamble, no repetition of earlier bullets, nothing \
        generic. If nothing useful can be said, reply with exactly: -

        MEETING CONTEXT (from the user):
        \(contextBlock.isEmpty ? "(none)" : contextBlock)

        DOCUMENTS:
        \(docsBlock.isEmpty ? "(none)" : docsBlock)
        """

        queue.sync {
            pending = ""
            recent = ""
            lastSent = .distantPast
            inFlight = false
            totalIngestedChars = 0
            sentFirstCard = false
            conversationSummary = ""
            summaryPending = ""
            summaryInFlight = false
        }
        running = true
        DispatchQueue.main.async { [weak self] in
            guard let self, self.running else { return }
            self.timer?.invalidate()
            self.timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
                self?.tick()
            }
        }
        onStatus?("Live insights on — updates every ~20 s while people talk")
    }

    func stop() {
        running = false
        DispatchQueue.main.async { [weak self] in
            self?.timer?.invalidate()
            self?.timer = nil
        }
    }

    /// One-time distillation of an attached document into a memory brief,
    /// done by the mini model the moment the file is added.
    func memorize(name: String, text: String, completion: @escaping (String?) -> Void) {
        guard !apiKey.isEmpty else {
            completion(nil)
            return
        }
        let system = """
        Distill this document into a compact memory brief for supporting the \
        user in a live meeting. Output at most 20 lines, each starting with \
        "- ", each at most 15 words, in \(userLanguageName). Cover: key \
        facts and claims; numbers, prices, dates; names and roles; \
        commitments or asks; risks or weak points; and 3 likely questions \
        with their answers (as "Q → A" lines). No preamble, no headers.
        """
        chat(model: routerModel,
             system: system,
             user: "Document \"\(name)\":\n\(String(text.prefix(24000)))",
             maxTokens: 1500,
             reasoningEffort: "low") { result in
            switch result {
            case .success(let content):
                completion(content.trimmingCharacters(in: .whitespacesAndNewlines))
            case .failure:
                completion(nil)
            }
        }
    }

    /// Feed one finalized transcript sentence.
    func ingest(speaker: String, line: String) {
        guard running else { return }
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        queue.async { [weak self] in
            self?.pending += "\n\(speaker): \(trimmed)"
            self?.summaryPending += "\n\(speaker): \(trimmed)"
            self?.totalIngestedChars += trimmed.count
        }
    }

    // MARK: Chunked requests

    private func tick() {
        queue.async { [weak self] in
            guard let self, self.running else { return }
            self.foldSummaryIfNeeded()
            guard !self.inFlight else { return }
            guard Date().timeIntervalSince(self.lastSent) >= Self.minInterval else { return }
            let newText = self.pending.trimmingCharacters(in: .whitespacesAndNewlines)
            guard newText.count >= Self.minNewChars else {
                if self.totalIngestedChars == 0 {
                    self.onStatus?("Listening — no speech transcribed yet (check the mic isn't muted and people are talking)")
                }
                return
            }

            self.recent += self.pending
            if self.recent.count > Self.recentWindowChars {
                self.recent = String(self.recent.suffix(Self.recentWindowChars))
            }
            self.pending = ""
            self.lastSent = Date()
            self.inFlight = true
            self.request(recent: self.recent, latest: newText)
        }
    }

    /// Folds accumulated speech into the running summary (mini model) once
    /// enough has piled up. Keeps decisions, numbers, names, open questions.
    private func foldSummaryIfNeeded() {
        guard !summaryInFlight, summaryPending.count > 900, !apiKey.isEmpty else { return }
        let excerpt = summaryPending
        summaryPending = ""
        summaryInFlight = true
        let system = """
        You maintain the running summary of a live meeting. Merge the \
        existing summary with the new excerpt into ONE updated summary: at \
        most 10 lines, each starting with "- ", each at most 14 words, in \
        \(userLanguageName). Keep decisions, commitments, numbers, names, \
        open questions, and the current topic. Drop small talk. No preamble.
        """
        let user = """
        Existing summary:
        \(conversationSummary.isEmpty ? "(none)" : conversationSummary)

        New excerpt:
        \(excerpt)
        """
        chat(model: routerModel, system: system, user: user,
             maxTokens: 900, reasoningEffort: "minimal") { [weak self] result in
            guard let self else { return }
            self.queue.async {
                self.summaryInFlight = false
                if case .success(let content) = result {
                    let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty {
                        self.conversationSummary = trimmed
                        self.onSummary?(trimmed)
                    }
                }
            }
        }
    }

    private func request(recent: String, latest: String) {
        guard !apiKey.isEmpty else {
            inFlight = false
            onStatus?("Insights need the OpenAI API key")
            return
        }

        // The very first chunk always produces a card so the feed shows life;
        // from then on the router gates the smart model.
        if !sentFirstCard {
            sentFirstCard = true
            generate(recent: recent, latest: latest)
            return
        }

        // Tier 1: the mini router decides whether to engage the smart model.
        let routerSystem = """
        You watch a live meeting transcript to decide if the user (the \
        speaker labeled "You") needs help RIGHT NOW. Reply with exactly one \
        word: YES or NO.
        YES only when: a question or request is directed at the user; an \
        objection or pushback needs answering; a decision, price, or \
        commitment is on the table; a factual claim should be checked; or \
        the user seems stuck for an answer.
        Also YES if the user just spoke and could use follow-up points, or \
        if you are uncertain.
        NO only for clear greetings, small talk, or logistics.
        """
        chat(model: routerModel,
             system: routerSystem,
             user: "Newest exchange:\n\(latest)",
             maxTokens: 256,
             reasoningEffort: "minimal") { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure(let message):
                self.queue.async { self.inFlight = false }
                self.onStatus?("Insight router failed: \(message)")
            case .success(let content):
                if content.uppercased().contains("YES") {
                    self.generate(recent: recent, latest: latest)
                } else {
                    self.queue.async { self.inFlight = false }
                    self.onStatus?("Watching — nothing needs you right now")
                }
            }
        }
    }

    /// Tier 2: the smart model writes the actual bullets.
    private func generate(recent: String, latest: String) {
        let summaryBlock = conversationSummary.isEmpty
            ? "" : "Running summary of the meeting so far:\n\(conversationSummary)\n\n"
        let userPrompt = """
        \(summaryBlock)Recent conversation (oldest first):
        \(recent)

        Newest exchange (react to this):
        \(latest)
        """
        onStatus?("Thinking…")
        chat(model: smartModel,
             system: systemPrompt,
             user: userPrompt,
             maxTokens: 2000,
             reasoningEffort: "low") { [weak self] result in
            guard let self else { return }
            self.queue.async { self.inFlight = false }
            switch result {
            case .failure(let message):
                self.onStatus?("Insight failed: \(message)")
            case .success(let content):
                let bullets = content
                    .split(separator: "\n")
                    .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: " -•*\t")) }
                    .filter { !$0.isEmpty && $0 != "-" }
                guard !bullets.isEmpty else {
                    self.onStatus?("")
                    return
                }
                self.onInsight?(bullets)
                self.onStatus?("")
            }
        }
    }

    private enum ChatResult {
        case success(String)
        case failure(String)
    }

    private func chat(model: String, system: String, user: String,
                      maxTokens: Int, reasoningEffort: String,
                      completion: @escaping (ChatResult) -> Void) {
        var request = URLRequest(url: URL(string: "https://api.openai.com/v1/chat/completions")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 25
        let body: [String: Any] = [
            "model": model,
            "messages": [
                ["role": "system", "content": system],
                ["role": "user", "content": user],
            ],
            "max_completion_tokens": maxTokens,
            "reasoning_effort": reasoningEffort,
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        URLSession.shared.dataTask(with: request) { data, _, error in
            if let error {
                completion(.failure(error.localizedDescription))
                return
            }
            guard let data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                completion(.failure("unreadable response"))
                return
            }
            if let apiError = json["error"] as? [String: Any],
               let message = apiError["message"] as? String {
                completion(.failure(message))
                return
            }
            guard let choices = json["choices"] as? [[String: Any]],
                  let message = choices.first?["message"] as? [String: Any],
                  let content = message["content"] as? String,
                  !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                let finish = (json["choices"] as? [[String: Any]])?.first?["finish_reason"] as? String ?? "?"
                completion(.failure("empty content (finish_reason: \(finish))"))
                return
            }
            completion(.success(content))
        }.resume()
    }

    // MARK: Document text extraction (all local, free)

    static func extractText(from url: URL) -> String? {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }

        switch url.pathExtension.lowercased() {
        case "pdf":
            return PDFDocument(url: url)?.string
        case "png", "jpg", "jpeg", "heic", "tiff", "gif", "webp":
            return ocr(url: url)
        case "pptx":
            return officeXMLText(url: url, entryPattern: "ppt/slides/slide*.xml",
                                 textRegex: "<a:t>(.*?)</a:t>")
        case "docx":
            return officeXMLText(url: url, entryPattern: "word/document.xml",
                                 textRegex: "<w:t[^>]*>(.*?)</w:t>")
        default:
            return try? String(contentsOf: url, encoding: .utf8)
        }
    }

    /// PPTX/DOCX are zip archives of XML; stream the relevant entries
    /// through the system unzip and pull the text runs out.
    private static func officeXMLText(url: URL, entryPattern: String, textRegex: String) -> String? {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        task.arguments = ["-p", url.path, entryPattern]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = Pipe()
        do {
            try task.run()
        } catch {
            return nil
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        guard let xml = String(data: data, encoding: .utf8), !xml.isEmpty,
              let regex = try? NSRegularExpression(pattern: textRegex,
                                                   options: [.dotMatchesLineSeparators]) else {
            return nil
        }
        let ns = xml as NSString
        var parts: [String] = []
        regex.enumerateMatches(in: xml, range: NSRange(location: 0, length: ns.length)) { match, _, _ in
            if let match, match.numberOfRanges > 1 {
                parts.append(ns.substring(with: match.range(at: 1)))
            }
        }
        guard !parts.isEmpty else { return nil }
        return parts.joined(separator: " ")
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&apos;", with: "'")
            .replacingOccurrences(of: "&#10;", with: "\n")
    }

    private static func ocr(url: URL) -> String? {
        guard let image = NSImage(contentsOf: url),
              let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return nil
        }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        let handler = VNImageRequestHandler(cgImage: cgImage)
        try? handler.perform([request])
        let lines = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }
}
