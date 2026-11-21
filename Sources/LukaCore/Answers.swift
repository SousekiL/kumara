import Foundation

/// A question heard in the conversation, with a short answer and hints from the language model.
public struct QuestionAnswer: Codable, Sendable, Equatable, Identifiable {
    /// The line the question was asked in.
    public var id: Int
    public var question: String
    /// Markdown: a short answer, then optional "- " hint bullets.
    public var answer: String
    /// Whether the answer rests on the user's own knowledge base rather than the model's knowledge.
    public var fromKnowledge: Bool
    public var createdAt: Date
    /// In interviews, the kind of question: technical, case, behavioral, experience, motivation or reverse.
    public var kind: String?
    /// For a polish: whether my answer covered the question ("complete" or "partial").
    public var status: String?
    /// For a polish: the story, project or number my answer relied on.
    public var used: String?
    /// For a polish: the smoother version, kept for the review afterwards.
    public var better: String?
    /// For a question the reader typed: what the answer rests on ("transcript", "knowledge" or "model").
    public var source: String?
    /// The question restated so it stands on its own, with the premise it refers to ("when you and a
    /// colleague disagreed on the design, how did you handle it?" rather than "how did you handle it?").
    public var restated: String?
    /// For a polish: my language slips, each "what I said → what to say".
    public var words: [String]?

    public init(id: Int, question: String, answer: String, fromKnowledge: Bool, createdAt: Date, kind: String? = nil,
                status: String? = nil, used: String? = nil, better: String? = nil, source: String? = nil,
                restated: String? = nil, words: [String]? = nil) {
        self.id = id
        self.question = question
        self.answer = answer
        self.fromKnowledge = fromKnowledge
        self.createdAt = createdAt
        self.kind = kind
        self.status = status
        self.used = used
        self.better = better
        self.source = source
        self.restated = restated
        self.words = words
    }

    /// The question as shown: restated when the model gave one, otherwise its last sentence.
    public var shownQuestion: String {
        restated ?? Questions.lastSentence(question) ?? question
    }
}

/// The user's standing knowledge: imported documents and their own notes, cut into chunks.
/// Answers draw on the chunks that match a question; with nothing matching, the model answers on its own.
public struct KnowledgeBase: Sendable {
    public struct Chunk: Sendable, Equatable {
        public let source: String
        public let text: String
        let terms: Set<String>
    }

    public private(set) var chunks: [Chunk] = []
    public var totalCharacters: Int { chunks.reduce(0) { $0 + $1.text.count } }
    public var isEmpty: Bool { chunks.isEmpty }
    /// Whether `excerpts` hands over all of it, so the text is the same for every question.
    public func fitsWhole(limit: Int = 12_000) -> Bool { !isEmpty && totalCharacters <= limit }

    public init(documents: [(name: String, text: String)] = [], chunkSize: Int = 900) {
        for document in documents {
            var current = ""
            func flush() {
                let text = current.trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty { chunks.append(Chunk(source: document.name, text: text, terms: Self.terms(text))) }
                current = ""
            }
            for paragraph in document.text.split(whereSeparator: \.isNewline) {
                var piece = Substring(paragraph.trimmingCharacters(in: .whitespaces))
                // A paragraph longer than a chunk is cut; anything else stays whole.
                while piece.count > chunkSize {
                    flush()
                    current = String(piece.prefix(chunkSize))
                    flush()
                    piece = piece.dropFirst(chunkSize)
                }
                if current.count + piece.count + 1 > chunkSize { flush() }
                current += (current.isEmpty ? "" : "\n") + piece
            }
            flush()
        }
    }

    /// The text to hand the model for `query`: everything when it fits in `limit` characters,
    /// otherwise the best-matching chunks in their original order. Empty when nothing matches.
    public func excerpts(for query: String, limit: Int = 12_000) -> String {
        guard !chunks.isEmpty else { return "" }
        var picked: [Int]
        if totalCharacters <= limit {
            picked = Array(chunks.indices)
        } else {
            let wanted = Self.terms(query)
            guard !wanted.isEmpty else { return "" }
            // A term found in few chunks says more than one found everywhere.
            var frequency: [String: Int] = [:]
            for chunk in chunks { for term in wanted where chunk.terms.contains(term) { frequency[term, default: 0] += 1 } }
            let scored = chunks.indices.map { i -> (Int, Double) in
                (i, wanted.reduce(0.0) { $0 + (chunks[i].terms.contains($1) ? 1.0 / (1.0 + log(Double(frequency[$1] ?? 1))) : 0) })
            }.filter { $0.1 > 0 }.sorted { $0.1 > $1.1 }
            picked = []
            var used = 0
            for (i, _) in scored {
                if used + chunks[i].text.count > limit { continue }
                picked.append(i)
                used += chunks[i].text.count
            }
            picked.sort()
        }
        var out = ""
        var source: String?
        for i in picked {
            if chunks[i].source != source {
                source = chunks[i].source
                out += (out.isEmpty ? "" : "\n\n") + "[\(chunks[i].source)]"
            }
            out += "\n" + chunks[i].text
        }
        return out
    }

    static let stopwords: Set<String> = [
        "the", "and", "for", "are", "was", "were", "you", "your", "with", "that", "this", "have", "has", "what", "why",
        "how", "when", "where", "which", "who", "can", "could", "would", "will", "should", "does", "did", "about",
        "from", "they", "their", "there", "been", "tell", "more", "some", "any", "into", "than", "then", "them",
    ]

    /// Words of three letters or more, and pairs of neighbouring Chinese, Japanese or Korean characters.
    static func terms(_ text: String) -> Set<String> {
        var terms = Set<String>()
        var word = ""
        var previousCJK: Character?
        func endWord() {
            if word.count >= 3, !stopwords.contains(word) { terms.insert(word) }
            word = ""
        }
        for ch in text.lowercased() {
            let cjk = ch.unicodeScalars.first.map { (0x3040...0x30FF).contains($0.value) || (0x4E00...0x9FFF).contains($0.value) || (0xAC00...0xD7AF).contains($0.value) } ?? false
            if cjk {
                endWord()
                if let p = previousCJK { terms.insert(String([p, ch])) }
                previousCJK = ch
            } else {
                previousCJK = nil
                if ch.isLetter || ch.isNumber { word.append(ch) } else { endWord() }
            }
        }
        endWord()
        return terms
    }
}

public enum AnswerPrompt {
    public static func system(language: String, mode: AssistantMode = .meeting, role: String = "", extra: String = "") -> String {
        system(language: OutputLanguage(language), mode: mode, role: role, extra: extra)
    }

    public static func system(language: OutputLanguage, mode: AssistantMode = .meeting, role: String = "", extra: String = "",
                              lessons: [String] = []) -> String {
        let body: String
        if mode == .interview {
            body = interviewBody(language)
        } else if let spoken = language.spoken {
            // Guide: the reader's own language points to what matters; the spoken language gives words to borrow.
            body = """
            After the header lines, exactly this and nothing more:
            Line 1: what to say, in at most 15 words of \(language.explain) (about 25 characters in Chinese). The gist, not a sentence to read out.
            Then 2 or 3 "- " bullets, each a few words of \(language.explain) naming one point, a colon, and a short phrase in \(spoken) to borrow, in quotes, at most 12 words. Example: - 先给结论："The short answer is that it depends on the baseline."
            No full answer paragraph. Technical terms stay in \(spoken).
            """
        } else {
            body = """
            After the header lines: the answer in 1 or 2 short sentences, direct and easy to say aloud. Then at most 3 "- " bullets of hints, each under 12 words: a key fact, number, term or example worth mentioning. Leave the bullets out when the answer needs none.
            Write in \(language.explain).
            """
        }
        var prompt = """
        You assist someone taking part in a live conversation (a meeting, an interview, a lecture or a call). A question was just asked. They will glance at your reply for a few seconds while the conversation goes on, so give only what helps them answer, and keep it short.

        Format
        Line 1 is exactly "SOURCE: knowledge" or "SOURCE: model" (see Sources).
        Next (after the TYPE line, when there is one), a line "QUESTION: " followed by the question restated so it makes sense on its own, without the conversation: what is being asked, with the situation, premise or topic it refers to filled in from the conversation. Not "How did you handle it?" but "When you and a colleague disagreed on the design, how did you handle it?". At most 30 words of \(language.explain) (about 45 characters in Chinese).
        \(body)
        No headings, no preamble, and don't repeat the question after the QUESTION line.
        Reply with the final answer only. Never show your reasoning, second thoughts or corrections: decide first, then write once.

        Sources
        - When the reader's knowledge base is provided and covers the question, answer from it and keep its facts, names and numbers exactly. Where it differs from what you know, the knowledge base wins. Start with "SOURCE: knowledge".
        - When it doesn't cover the question, or none is provided, answer from your own knowledge and start with "SOURCE: model".
        - Never invent facts about the reader: their experience, opinions, projects or numbers. For a personal question the knowledge base doesn't cover, give the points to cover, in order, instead.

        When not to answer
        Reply with exactly SKIP when the text isn't a question that needs an answer: a greeting, small talk, a logistics check ("can you hear me?"), a rhetorical question, or a question the speaker goes on to answer.

        The transcript comes from speech recognition and may contain errors; read through them.
        """
        let guidance = mode.answerGuidance(role: role)
        if !guidance.isEmpty { prompt += "\n\n" + guidance + "\nWhatever the type, keep to the format and length above: the reader has seconds." }
        if !lessons.isEmpty {
            prompt += "\n\nLessons from the reader's earlier sessions (keep the format above):\n" + lessons.map { "- " + $0 }.joined(separator: "\n")
        }
        let extra = extra.trimmingCharacters(in: .whitespacesAndNewlines)
        if !extra.isEmpty {
            prompt += "\n\nThe reader's own instructions, which override the above where they conflict:\n\(extra)"
        }
        return prompt
    }

    /// `previous` are the questions answered most recently, so a restatement isn't answered twice.
    /// Interview answers are a skeleton to speak from, not a script: the gist, three cues, and one anchor
    /// from the candidate's own material, so they can glance, then say it in their own words.
    static func interviewBody(_ language: OutputLanguage) -> String {
        let spoken = language.spoken ?? language.explain
        return """
        After the header lines, exactly this and nothing more:
        Line 1: the gist, at most 15 words of \(language.explain) (about 25 characters in Chinese): what the answer is or how to approach it. Not a sentence to read out.
        Then 2 or 3 cue lines, starting with ①, ② and ③, each at most 8 words of \(spoken): the skeleton for this type of question (see below). Cues to speak from, not sentences to read out. Technical terms stay in \(spoken).
        Then, when it applies, one anchor line starting with "⚓ ": the candidate's own project, story or number from the knowledge base that fits, with the file it came from in brackets, at most 15 words, e.g. ⚓ [projects.md] Search ranking holdout: +2.1% sessions. Copy names and numbers exactly.
        For behavioral, experience and motivation questions the anchor line is required: when nothing in the knowledge base fits, write exactly "⚓ —". For other types, leave it out unless something clearly fits.
        When the question has several parts, give one cue per part, in order.
        """
    }

    /// The knowledge base as it opens the user message. Sent on its own when it is the whole base,
    /// so the service can cache it from one question to the next.
    public static func knowledgeBlock(_ knowledge: String) -> String {
        knowledge.isEmpty ? "" : "The reader's knowledge base (excerpts):\n<knowledge>\n\(knowledge)\n</knowledge>\n\n"
    }

    public static func user(question: String, asker: String, conversation: String, knowledge: String, previous: [String] = [],
                            force: Bool = false) -> String {
        var out = knowledgeBlock(knowledge)
        if !conversation.isEmpty {
            out += "Recent conversation:\n<conversation>\n\(conversation)\n</conversation>\n\n"
        }
        if !previous.isEmpty {
            out += "Questions already answered (reply SKIP if this only repeats one of them; a follow-up asking for more is new):\n"
            out += previous.map { "- \($0)" }.joined(separator: "\n") + "\n\n"
        }
        out += "The question to answer, asked by \(asker):\n<question>\n\(question)\n</question>"
        if force {
            out += "\n\nThe reader asked for an answer to this one: answer it, never SKIP."
        }
        return out
    }

    static let kinds: Set<String> = ["technical", "case", "behavioral", "experience", "motivation", "reverse", "for-me"]

    /// What can be shown of a reply still coming in: nil while it is only header lines,
    /// or could still turn out to be SKIP.
    public static func partial(_ reply: String) -> (text: String, fromKnowledge: Bool, kind: String?, question: String?)? {
        var lines = reply.split(separator: "\n", omittingEmptySubsequences: false)
        // A header line still being written isn't text to show.
        if !reply.hasSuffix("\n"), let last = lines.last {
            let upper = last.trimmingCharacters(in: .whitespaces).uppercased()
            if upper.isEmpty || ["SOURCE:", "TYPE:", "QUESTION:"].contains(where: { $0.hasPrefix(upper) || upper.hasPrefix($0) }) {
                lines.removeLast()
            }
        }
        guard let parsed = parse(lines.joined(separator: "\n")) else { return nil }
        return Self.maySkip(parsed.text) ? nil : parsed
    }

    /// Whether the model has committed to answering: its reply has begun with a header line,
    /// which a skip never has. Until then the question may still turn out to need no answer.
    public static func committed(_ reply: String) -> Bool {
        let head = SummaryPrompt.clean(reply).trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        return ["SOURCE:", "TYPE:", "QUESTION:"].contains { head.hasPrefix($0) }
    }

    /// Whether text so far could still be the start of SKIP.
    static func maySkip(_ text: String) -> Bool {
        let bare = text.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        return bare.count < 4 && "SKIP".hasPrefix(bare)
    }

    /// The answer, where it came from and its kind, or nil when the model declined to answer.
    public static func parse(_ reply: String) -> (text: String, fromKnowledge: Bool, kind: String?, question: String?)? {
        var fromKnowledge = false
        var kind: String?
        var question: String?
        var body: [Substring] = []
        var lines = SummaryPrompt.clean(reply).split(separator: "\n", omittingEmptySubsequences: false)
        // A model that changed its mind halfway starts over with a new SOURCE line: keep only the last attempt.
        if let last = Self.lastHeader(lines.map(String.init)) {
            var start = last
            if start > 0, lines[start - 1].trimmingCharacters(in: .whitespaces).uppercased().hasPrefix("TYPE:") { start -= 1 }
            lines = Array(lines[start...])
        }
        // SOURCE and TYPE lead the reply, in either order.
        var leading = true
        var sawHeader = false
        for line in lines {
            if leading {
                let u = line.trimmingCharacters(in: .whitespaces).uppercased()
                if u.hasPrefix("SOURCE:") || u.hasPrefix("TYPE:") || u.hasPrefix("QUESTION:") { sawHeader = true }
            }
            let upper = line.trimmingCharacters(in: .whitespaces).uppercased()
            if leading, upper.hasPrefix("SOURCE:") {
                fromKnowledge = upper.contains("KNOWLEDGE")
            } else if leading, upper.hasPrefix("TYPE:") {
                let value = upper.dropFirst(5).trimmingCharacters(in: .whitespaces).lowercased()
                kind = kinds.contains(value) ? value : nil
            } else if leading, upper.hasPrefix("QUESTION:") {
                let value = line.trimmingCharacters(in: .whitespaces).dropFirst(9).trimmingCharacters(in: .whitespaces)
                question = value.isEmpty ? nil : value
            } else {
                leading = false
                body.append(line)
            }
        }
        let text = body.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        let bare = text.trimmingCharacters(in: CharacterSet(charactersIn: " .。\n")).uppercased()
        // "SKIP - small talk" is still a skip; after real headers, only a bare SKIP is.
        if bare.isEmpty || bare == "SKIP" || (!sawHeader && bare.hasPrefix("SKIP")) { return nil }
        return (text, fromKnowledge, kind, question)
    }

    /// The last real SOURCE header: "SOURCE:" followed by one of the words the format allows.
    /// A body line that merely begins "Source: the meeting" doesn't count.
    static func lastHeader(_ lines: [String]) -> Int? {
        lines.indices.last { i in
            let upper = lines[i].trimmingCharacters(in: .whitespaces).uppercased()
            guard upper.hasPrefix("SOURCE:") else { return false }
            let value = upper.dropFirst(7).trimmingCharacters(in: CharacterSet(charactersIn: " .\"'"))
            return ["KNOWLEDGE", "MODEL", "TRANSCRIPT", "CONVERSATION", "KNOWLEDGE BASE"].contains(value)
        }
    }
}

extension Transcript {
    /// The newest finished question that hasn't been handled, asked within `maxAge`, plus every
    /// other waiting question's line, so older ones aren't answered late. Never the user's own questions.
    public func waitingQuestion(handled: Set<Int>, channelsOnly: Bool, eagerness: AnswerEagerness = .normal,
                                tuning: AnswerTuning? = nil, now: Date = .now, maxAge: TimeInterval = 90)
        -> (line: Line, all: [Int])?
    {
        let waiting = lines.suffix(30).filter { line in
            guard !line.isOpen, !handled.contains(line.id), now.timeIntervalSince(line.startedAt) <= maxAge else { return false }
            let channel = Channel(line.speaker)
            if channelsOnly ? channel != .them : channel == .me { return false }
            return tuning?.accepts(line.original, fromThem: channel == .them, eagerness: eagerness)
                ?? eagerness.accepts(line.original, fromThem: channel == .them)
        }
        guard let newest = waiting.last else { return nil }
        return (newest, waiting.map(\.id))
    }
}


/// A question the reader types about the conversation, answered on request.
public enum AskPrompt {
    public static func system(language: OutputLanguage, mode: AssistantMode = .meeting, role: String = "", extra: String = "") -> String {
        let format: String
        if let spoken = language.spoken {
            format = """
            After the SOURCE line: first a direct answer in at most 25 words of \(language.explain); then, only if it helps, up to 4 "- " bullets, each at most 18 words. Technical terms, quotes from the conversation and anything the reader might say stay in \(spoken), in quotes.
            """
        } else {
            format = """
            After the SOURCE line: first a direct answer in at most 25 words of \(language.explain); then, only if it helps, up to 4 "- " bullets, each at most 18 words. Quote the conversation's own words when they settle it.
            """
        }
        var prompt = """
        The reader is in a live \(mode == .interview ? "interview" : mode == .lecture ? "talk or lecture" : mode == .meeting ? "meeting or call" : "conversation") and is asking you a question directly. Answer it.
        Use, in this order: what was said in the conversation, the reader's knowledge base, then your own knowledge.
        Start with one line "SOURCE: transcript" when the answer comes from the conversation, "SOURCE: knowledge" when it rests on the knowledge base, or "SOURCE: model" when it is your own knowledge.
        \(format)
        When the question is about the conversation and the transcript doesn't settle it, say so plainly instead of guessing. The transcript comes from speech recognition and may contain errors; read through them. Never invent the reader's facts or numbers. No headings, no preamble, never show your reasoning.
        """
        if mode == .interview, !role.isEmpty { prompt += "\nThe reader is a candidate interviewing for \(role)." }
        let extra = extra.trimmingCharacters(in: .whitespacesAndNewlines)
        if !extra.isEmpty { prompt += "\n\nAbout the reader and this conversation:\n\(extra)" }
        return prompt
    }

    public static func user(question: String, conversation: String, notes: String?, knowledge: String,
                            previous: [(question: String, answer: String)] = []) -> String {
        var parts: [String] = []
        if let notes, !notes.isEmpty { parts.append("Notes taken so far:\n<notes>\n\(notes)\n</notes>") }
        parts.append("The conversation (most recent part):\n<conversation>\n\(conversation)\n</conversation>")
        if !knowledge.isEmpty { parts.append("From the reader's knowledge base:\n<knowledge>\n\(knowledge)\n</knowledge>") }
        if !previous.isEmpty {
            parts.append("The reader's earlier questions, for follow-ups:\n" + previous.map { "Q: \($0.question)\nA: \($0.answer)" }.joined(separator: "\n\n"))
        }
        parts.append("The reader's question:\n\(question)")
        return parts.joined(separator: "\n\n")
    }

    /// The answer and what it rests on.
    public static func parse(_ reply: String) -> (text: String, source: String)? {
        var lines = SummaryPrompt.clean(reply).split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var source = "model"
        // Keep only the last SOURCE block, should the model have started over.
        if let last = AnswerPrompt.lastHeader(lines) {
            let value = lines[last].split(separator: ":", maxSplits: 1).last.map { $0.trimmingCharacters(in: .whitespaces).lowercased() } ?? ""
            if value.hasPrefix("transcript") || value.hasPrefix("conversation") { source = "transcript" }
            else if value.hasPrefix("knowledge") { source = "knowledge" }
            lines = Array(lines[(last + 1)...])
        }
        let text = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : (text, source)
    }

    /// What can be shown of a reply still coming in: nil while it is only the SOURCE line.
    public static func partial(_ reply: String) -> (text: String, source: String)? {
        var text = reply
        if !text.hasSuffix("\n"), let lastLine = text.split(separator: "\n", omittingEmptySubsequences: false).last,
           "SOURCE:".hasPrefix(lastLine.trimmingCharacters(in: .whitespaces).uppercased())
            || lastLine.trimmingCharacters(in: .whitespaces).uppercased().hasPrefix("SOURCE:") {
            text = String(text.dropLast(lastLine.count))
        }
        return parse(text)
    }
}
