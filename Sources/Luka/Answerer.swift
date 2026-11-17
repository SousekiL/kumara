import AppKit
import LukaCore
import PDFKit

/// Answers questions heard in the conversation, with the summary's model and key, drawing first
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

    private let defaults = UserDefaults.standard

    var enabled: Bool {
        didSet {
            defaults.set(enabled, forKey: "answers.enabled")
            // Start from now: questions asked before it was turned on stay unanswered.
            sessionID = nil
            if enabled { reload() }
        }
    }
    var instructions: String { didSet { defaults.set(instructions, forKey: "answers.instructions") } }
    /// The job being interviewed for, which tells Interview mode what counts as a technical question.
    var role: String { didSet { defaults.set(role, forKey: "answers.role") } }
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

    /// Called when an answer has been added.
    @ObservationIgnored var onAnswer: () -> Void = {}
    @ObservationIgnored private var knowledge = KnowledgeBase()
    @ObservationIgnored private var handled: Set<Int> = []
    @ObservationIgnored private var sessionID: UUID?
    @ObservationIgnored private var reloadTask: Task<Void, Never>?

    init() {
        let d = UserDefaults.standard
        enabled = d.bool(forKey: "answers.enabled")
        instructions = d.string(forKey: "answers.instructions") ?? ""
        role = d.string(forKey: "answers.role") ?? "Data Scientist"
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
    func tick(_ t: Transcript, summarizer: Summarizer, languageName: String, channelsOnly: Bool, name: (SpeakerID) -> String) {
        guard enabled, summarizer.isConfigured else { return }
        if sessionID != t.id {
            sessionID = t.id
            handled = Set(t.lines.map(\.id))
        }
        let mode = summarizer.mode
        guard !working, let waiting = t.waitingQuestion(handled: handled, channelsOnly: channelsOnly, eagerness: mode.eagerness) else { return }
        handled.formUnion(waiting.all)
        let line = waiting.line
        let conversation = t.summaryText(after: nil, closedOnly: false, limit: 1_500, name: name).text
        let previous = t.answers.suffix(3).map { Questions.lastSentence($0.question) ?? $0.question }
        let user = AnswerPrompt.user(question: line.original, asker: line.speaker.map(name) ?? "someone",
                                     conversation: conversation, knowledge: knowledge.excerpts(for: line.original),
                                     previous: previous)
        let endpoint = summarizer.endpoint
        guard let request = endpoint.request(apiKey: summarizer.apiKey,
                                             system: AnswerPrompt.system(language: languageName, mode: mode, role: role, extra: instructions),
                                             user: user, maxTokens: 500) else { return }
        working = true
        Task {
            defer { working = false }
            do {
                let reply = try await Summarizer.send(request, endpoint: endpoint)
                lastError = nil
                guard let answer = AnswerPrompt.parse(reply) else { return }
                t.answers.append(QuestionAnswer(id: line.id, question: line.original, answer: answer.text,
                                                fromKnowledge: answer.fromKnowledge, createdAt: .now, kind: answer.kind))
                onAnswer()
            } catch {
                lastError = error.localizedDescription
                AudioLog.write("answer failed: \(error.localizedDescription)")
            }
        }
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
