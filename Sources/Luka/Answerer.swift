import AppKit
import LukaCore
import PDFKit

/// Answers questions heard in the conversation, with the assistant's model, drawing first
/// on the user's knowledge base: files and folders read where they are on disk, plus their own notes.
@MainActor
@Observable
final class Answerer {
    struct Source: Identifiable, Equatable {
        let path: String
        var files = 0
        var characters = 0
        var missing = false
        var isFolder = false
        var id: String { path }
        var name: String { URL(fileURLWithPath: path).lastPathComponent }
    }

    /// A reply still coming in, shown as it is written.
    struct Live: Equatable {
        /// The session it belongs to.
        let session: UUID
        /// The line the question was asked in.
        let id: Int
        let question: String
        let polish: Bool
        /// A question the reader typed.
        var asked = false
        /// What can be shown so far; nil until the model is past its header lines.
        var text: String?
        var fromKnowledge = false
        var kind: String?
        var source: String?
        /// The question restated to stand on its own, once the model has written it.
        var restated: String?
    }

    private let defaults = UserDefaults.standard
    let service: AssistantService

    var enabled: Bool {
        didSet {
            defaults.set(enabled, forKey: "answers.enabled")
            // Start from now: questions asked before it was turned on stay unanswered.
            sessionID = nil
            if !enabled { stop() }
            if enabled { reload() }
            onEnabledChange()
        }
    }
    @ObservationIgnored var onEnabledChange: () -> Void = {}
    /// The job being interviewed for, which tells Interview mode what counts as a technical question.
    var role: String { didSet { defaults.set(role, forKey: "answers.role") } }
    /// In Interview mode with Me / Them: a smoother version of each of my answers, and quick fixes.
    var polishes: Bool { didSet { defaults.set(polishes, forKey: "answers.polish") } }
    static let rolePresets = ["Data Scientist", "Data Analyst", "Actuarial Analyst", "AI Product Manager"]
    /// The user's own notes, part of the knowledge base.
    var notes: String {
        didSet {
            defaults.set(notes, forKey: "answers.notes")
            reload(after: .seconds(1.5))
        }
    }
    /// Whether the side panel shows answers rather than the summary.
    var panelShowsAnswers: Bool { didSet { defaults.set(panelShowsAnswers, forKey: "answers.panelShown") } }

    private(set) var sources: [Source]
    private(set) var loading = false
    private(set) var knowledgeCharacters = 0
    private(set) var working = false
    private(set) var lastError: String?
    /// The answer or polish being written right now.
    private(set) var live: Live?
    /// The answer to a question the reader typed, being written; separate, so neither waits for the other.
    private(set) var asking: Live?
    @ObservationIgnored private var askTask: Task<Void, Never>?

    /// Called when an answer starts to show, and again when it is filed.
    @ObservationIgnored var onAnswer: () -> Void = {}
    @ObservationIgnored private var knowledge = KnowledgeBase()
    @ObservationIgnored private var handled: Set<Int> = []
    @ObservationIgnored private var sessionID: UUID?
    @ObservationIgnored private var reloadTask: Task<Void, Never>?
    /// The reply being written, so a new session or turning answers off can stop it.
    @ObservationIgnored private var writing: (id: UUID, task: Task<Void, Never>)?

    init(service: AssistantService) {
        self.service = service
        let d = UserDefaults.standard
        enabled = d.bool(forKey: "answers.enabled")
        role = d.string(forKey: "answers.role") ?? "Data Scientist"
        polishes = d.object(forKey: "answers.polish") as? Bool ?? true
        notes = d.string(forKey: "answers.notes") ?? ""
        panelShowsAnswers = d.bool(forKey: "answers.panelShown")
        sources = (d.stringArray(forKey: "answers.sources") ?? []).map { Source(path: $0) }
        if enabled { reload() }
    }

    // MARK: Knowledge base

    func pickSources() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.message = tr("Choose files or folders for the knowledge base. Folders are read as they are, including later changes.")
        NSApp.activate()
        guard panel.runModal() == .OK else { return }
        for url in panel.urls where !sources.contains(where: { $0.path == url.path }) {
            sources.append(Source(path: url.path))
        }
        saveSources()
        reload()
    }

    func remove(_ source: Source) {
        sources.removeAll { $0.path == source.path }
        saveSources()
        reload()
    }

    private func saveSources() {
        defaults.set(sources.map(\.path), forKey: "answers.sources")
    }

    /// Reads the files again, off the main thread. Folders are never copied, so this picks up edits.
    func reload(after delay: Duration = .zero) {
        reloadTask?.cancel()
        let paths = sources.map(\.path)
        let notes = notes
        loading = true
        reloadTask = Task {
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            let loaded = await Task.detached(priority: .utility) { KnowledgeLoader.load(paths: paths, notes: notes) }.value
            guard !Task.isCancelled else { return }
            knowledge = loaded.base
            knowledgeCharacters = loaded.base.totalCharacters
            for i in sources.indices {
                guard let stat = loaded.stats[sources[i].path] else { continue }
                sources[i].files = stat.files
                sources[i].characters = stat.characters
                sources[i].missing = stat.missing
                sources[i].isFolder = stat.isFolder
            }
            loading = false
        }
    }

    // MARK: Answering

    /// Called every second while listening: answers the newest question that just finished.
    func tick(_ t: Transcript, mode: AssistantMode, language: OutputLanguage, channelsOnly: Bool, name: (SpeakerID) -> String) {
        guard enabled, service.isConfigured else { return }
        if sessionID != t.id {
            // A reply for the session before has no place in this one.
            stop()
            sessionID = t.id
            handled = Set(t.lines.map(\.id))
        }
        guard !working else { return }
        guard let waiting = t.waitingQuestion(handled: handled, channelsOnly: channelsOnly, eagerness: mode.eagerness) else {
            // Questions come first; with none waiting, look at the answer I just gave.
            if polishes, mode == .interview, channelsOnly { polish(t, language: language) }
            return
        }
        handled.formUnion(waiting.all)
        let line = waiting.line
        let conversation = t.summaryText(after: nil, closedOnly: false, limit: 1_500, name: name).text
        let previous = t.answers.suffix(3).map(\.shownQuestion)
        let user = AnswerPrompt.user(question: line.original, asker: line.speaker.map(name) ?? "someone",
                                     conversation: conversation, knowledge: knowledge.excerpts(for: line.original),
                                     previous: previous)
        guard let request = service.request(system: AnswerPrompt.system(language: language, mode: mode, role: role, extra: service.context),
                                            user: user, maxTokens: 4_000, stream: true) else { return }
        write(request, into: t, live: Live(session: t.id, id: line.id, question: line.original, polish: false))
    }

    /// A smoother way to say the answer I just finished, and quick fixes. Interview mode with Me / Them only.
    private func polish(_ t: Transcript, language: OutputLanguage) {
        guard let answer = t.finishedAnswer(handled: handled), let id = answer.ids.last else { return }
        handled.formUnion(answer.ids)
        let user = PolishPrompt.user(question: answer.question, answer: answer.text,
                                     knowledge: knowledge.excerpts(for: (answer.question ?? "") + " " + answer.text, limit: 6_000))
        guard let request = service.request(system: PolishPrompt.system(language: language, role: role, extra: service.context),
                                            user: user, maxTokens: 3_000, stream: true) else { return }
        write(request, into: t, live: Live(session: t.id, id: id, question: answer.text, polish: true))
    }

    /// Streams the reply into `live` as it is written, then files it with the session's answers.
    private func write(_ request: URLRequest, into t: Transcript, live start: Live) {
        working = true
        live = start
        let id = UUID()
        let task = Task {
            defer {
                // Only if this is still the current reply: one that was stopped has been cleared already.
                if writing?.id == id {
                    writing = nil
                    working = false
                    live = nil
                }
            }
            do {
                let reply = try await service.stream(request) { [weak self] text in
                    guard let self, self.live?.id == start.id else { return }
                    let first = self.live?.text == nil
                    defer { if first, self.live?.text != nil { self.onAnswer() } }
                    if start.polish {
                        self.live?.text = PolishPrompt.partial(text)
                    } else if let shown = AnswerPrompt.partial(text) {
                        self.live?.text = shown.text
                        self.live?.fromKnowledge = shown.fromKnowledge
                        self.live?.kind = shown.kind
                        self.live?.restated = shown.question
                    } else if let restated = AnswerPrompt.parse(text + "\nx")?.question {
                        // The restated question arrives before the answer: show it in the pin at once.
                        self.live?.restated = restated
                    }
                }
                guard !Task.isCancelled else { return }
                lastError = nil
                let item: QuestionAnswer
                if start.polish {
                    // Kept even with nothing to fix: whether the answer was complete feeds the question tracker.
                    guard let feedback = PolishPrompt.parse(reply) else { return }
                    item = QuestionAnswer(id: start.id, question: start.question, answer: feedback.fix ?? "",
                                          fromKnowledge: false, createdAt: .now, kind: "polish",
                                          status: feedback.status, used: feedback.used, better: feedback.better)
                } else {
                    guard let answer = AnswerPrompt.parse(reply) else { return }
                    item = QuestionAnswer(id: start.id, question: start.question, answer: answer.text,
                                          fromKnowledge: answer.fromKnowledge, createdAt: .now, kind: answer.kind,
                                          restated: answer.question)
                }
                t.answers.append(item)
                onAnswer()
            } catch SummaryEndpoint.ResponseError.empty {
                // An empty reply is the model having nothing to add, not a failure.
                lastError = nil
            } catch let error where Task.isCancelled || error is CancellationError || (error as? URLError)?.code == .cancelled {
                // Stopped on purpose.
            } catch {
                lastError = error.localizedDescription
                AudioLog.write("\(start.polish ? "polish" : "answer") failed: \(error.localizedDescription)")
            }
        }
        writing = (id, task)
    }

    // MARK: Questions the reader asks

    /// Answers a question the reader typed about this session, whether or not answers are on, in any mode.
    func ask(_ question: String, in t: Transcript, mode: AssistantMode, language: OutputLanguage, name: (SpeakerID) -> String) {
        let question = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty, service.isAskConfigured else { return }
        askTask?.cancel()
        // Its own id space, below any line's, so it never collides with an answer to a heard question.
        let id = -Int((Date.now.timeIntervalSince1970 * 1000).truncatingRemainder(dividingBy: 1_000_000_000_000))
        let conversation = t.summaryText(after: nil, closedOnly: false, limit: 12_000, name: name).text
        let previous = t.answers.filter { $0.kind == "asked" }.suffix(3).map { (question: $0.question, answer: $0.answer) }
        let user = AskPrompt.user(question: question, conversation: conversation, notes: t.summary?.text,
                                  knowledge: knowledge.excerpts(for: question), previous: previous)
        let system = AskPrompt.system(language: language, mode: mode, role: role, extra: service.context)
        let order = service.askThinkingOrder
        guard service.askRequest(system: system, user: user, thinking: order[0]) != nil else { return }
        let endpoint = service.askEndpoint
        let start = Live(session: t.id, id: id, question: question, polish: false, asked: true)
        asking = start
        panelShowsAnswers = true
        askTask = Task {
            defer { if asking?.id == id { asking = nil } }
            do {
                // Models accept different thinking settings; step down to the next style when one is rejected.
                var reply = ""
                for (i, thinking) in order.enumerated() {
                    guard let request = service.askRequest(system: system, user: user, thinking: thinking) else { return }
                    do {
                        reply = try await service.stream(request, via: endpoint) { [weak self] text in
                            guard let self, self.asking?.id == id, let shown = AskPrompt.partial(text) else { return }
                            self.asking?.text = shown.text
                            self.asking?.source = shown.source
                        }
                        service.noteAccepted(thinking)
                        break
                    } catch let error where i < order.count - 1 && !Task.isCancelled
                        && SummaryEndpoint.rejectsThinking(error.localizedDescription) {
                        AudioLog.write("ask: thinking style rejected, trying the next: \(error.localizedDescription)")
                    }
                }
                guard !Task.isCancelled, let answer = AskPrompt.parse(reply) else { return }
                t.answers.append(QuestionAnswer(id: id, question: question, answer: answer.text,
                                                fromKnowledge: answer.source == "knowledge", createdAt: .now,
                                                kind: "asked", source: answer.source))
                lastError = nil
            } catch let error where Task.isCancelled || error is CancellationError || (error as? URLError)?.code == .cancelled {
                // Replaced by a newer question.
            } catch {
                lastError = error.localizedDescription
                AudioLog.write("ask failed: \(error.localizedDescription)")
            }
        }
    }

    /// Stops the reply being written, if any; nothing from it is kept.
    func stop() {
        guard let writing else { return }
        writing.task.cancel()
        self.writing = nil
        working = false
        live = nil
    }
}

/// Reads knowledge-base files. Runs off the main thread.
enum KnowledgeLoader {
    struct Stat: Sendable {
        var files = 0
        var characters = 0
        var missing = false
        var isFolder = false
    }

    struct Loaded: Sendable {
        var base: KnowledgeBase
        var stats: [String: Stat]
    }

    static let plain: Set<String> = ["md", "markdown", "txt", "text", "csv", "json", "yaml", "yml", "org", "tex"]
    static let rich: Set<String> = ["docx", "doc", "rtf", "odt"]
    /// Enough for a large notes vault; past this the rest is left out.
    static let maxCharacters = 8_000_000

    static func load(paths: [String], notes: String) -> Loaded {
        var documents: [(name: String, text: String)] = []
        var stats: [String: Stat] = [:]
        var total = 0
        let fm = FileManager.default
        let trimmed = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { documents.append(("My notes", trimmed)) }

        for path in paths {
            var stat = Stat()
            var isDirectory: ObjCBool = false
            guard fm.fileExists(atPath: path, isDirectory: &isDirectory) else {
                stat.missing = true
                stats[path] = stat
                continue
            }
            stat.isFolder = isDirectory.boolValue
            let root = URL(fileURLWithPath: path)
            var files: [URL] = []
            if isDirectory.boolValue {
                // Hidden folders (.git, .obsidian) and packages are skipped.
                let walker = fm.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey],
                                           options: [.skipsHiddenFiles, .skipsPackageDescendants])
                while let url = walker?.nextObject() as? URL {
                    if supported(url) { files.append(url) }
                }
                files.sort { $0.path < $1.path }
            } else {
                files = [root]
            }
            for url in files {
                guard total < maxCharacters, let text = read(url), !text.isEmpty else { continue }
                // Inside a folder, the name keeps the path below it, so the model can tell notes apart.
                var name = url.lastPathComponent
                if isDirectory.boolValue, url.path.hasPrefix(root.path + "/") {
                    name = root.lastPathComponent + "/" + String(url.path.dropFirst(root.path.count + 1))
                }
                documents.append((name, text))
                stat.files += 1
                stat.characters += text.count
                total += text.count
            }
            stats[path] = stat
        }
        return Loaded(base: KnowledgeBase(documents: documents), stats: stats)
    }

    static func supported(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        return plain.contains(ext) || rich.contains(ext) || ext == "pdf"
    }

    static func read(_ url: URL) -> String? {
        let ext = url.pathExtension.lowercased()
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        if ext == "pdf" {
            guard size < 50_000_000 else { return nil }
            return PDFDocument(url: url)?.string
        }
        guard size < 5_000_000 else { return nil }
        if rich.contains(ext) {
            return (try? NSAttributedString(url: url, options: [:], documentAttributes: nil))?.string
        }
        return try? String(contentsOf: url, encoding: .utf8)
    }
}
