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

    public init(id: Int, question: String, answer: String, fromKnowledge: Bool, createdAt: Date) {
        self.id = id
        self.question = question
        self.answer = answer
        self.fromKnowledge = fromKnowledge
        self.createdAt = createdAt
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
    public static func system(language: String, mode: AssistantMode = .meeting, extra: String = "") -> String {
        var prompt = """
        You assist someone taking part in a live conversation (a meeting, an interview, a lecture or a call). A question was just asked. Give them what they need to answer it well, short enough to read at a glance. Write in \(language).

        Format
        Line 1 is exactly "SOURCE: knowledge" or "SOURCE: model" (see Sources).
        Then the answer in 1 to 3 short sentences: direct, specific, easy to say aloud.
        Then up to 3 "- " bullets of hints: a key fact, number, term or example worth mentioning. Leave the bullets out when the answer needs none.
        No headings, no preamble, and don't repeat the question.

        Sources
        - When the reader's knowledge base is provided and covers the question, answer from it and keep its facts, names and numbers exactly. Where it differs from what you know, the knowledge base wins. Start with "SOURCE: knowledge".
        - When it doesn't cover the question, or none is provided, answer from your own knowledge and start with "SOURCE: model".
        - Never invent facts about the reader: their experience, opinions, projects or numbers. For a personal question the knowledge base doesn't cover, give a short structure for answering instead (what to cover, in what order).
        - When you aren't sure, say what you're unsure of in a few words instead of guessing.

        When not to answer
        Reply with exactly SKIP when the text isn't a question that needs an answer: a greeting, small talk, a logistics check ("can you hear me?"), a rhetorical question, or a question the speaker goes on to answer.

        The transcript comes from speech recognition and may contain errors; read through them.
        """
        if !mode.answerGuidance.isEmpty { prompt += "\n\n" + mode.answerGuidance }
        let extra = extra.trimmingCharacters(in: .whitespacesAndNewlines)
        if !extra.isEmpty {
            prompt += "\n\nThe reader's own instructions, which override the above where they conflict:\n\(extra)"
        }
        return prompt
    }

    public static func user(question: String, asker: String, conversation: String, knowledge: String) -> String {
        var out = ""
        if !knowledge.isEmpty {
            out += "The reader's knowledge base (excerpts):\n<knowledge>\n\(knowledge)\n</knowledge>\n\n"
        }
        if !conversation.isEmpty {
            out += "Recent conversation:\n<conversation>\n\(conversation)\n</conversation>\n\n"
        }
        out += "The question to answer, asked by \(asker):\n<question>\n\(question)\n</question>"
        return out
    }

    /// The answer and where it came from, or nil when the model declined to answer.
    public static func parse(_ reply: String) -> (text: String, fromKnowledge: Bool)? {
        var text = SummaryPrompt.clean(reply)
        var fromKnowledge = false
        if let first = text.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false).first,
           first.uppercased().hasPrefix("SOURCE:") {
            fromKnowledge = first.lowercased().contains("knowledge")
            text = String(text.dropFirst(first.count)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let bare = text.trimmingCharacters(in: CharacterSet(charactersIn: " .。\n")).uppercased()
        if bare.isEmpty || bare == "SKIP" { return nil }
        return (text, fromKnowledge)
    }
}

extension Transcript {
    /// The newest finished question that hasn't been handled, asked within `maxAge`, plus every
    /// other waiting question's line, so older ones aren't answered late. Never the user's own questions.
    public func waitingQuestion(handled: Set<Int>, channelsOnly: Bool, eagerness: AnswerEagerness = .normal,
                                now: Date = .now, maxAge: TimeInterval = 90)
        -> (line: Line, all: [Int])?
    {
        let waiting = lines.suffix(30).filter { line in
            guard !line.isOpen, !handled.contains(line.id), now.timeIntervalSince(line.startedAt) <= maxAge else { return false }
            let channel = Channel(line.speaker)
            if channelsOnly ? channel != .them : channel == .me { return false }
            return eagerness.accepts(line.original, fromThem: channel == .them)
        }
        guard let newest = waiting.last else { return nil }
        return (newest, waiting.map(\.id))
    }
}
