import Foundation

/// What the reader told the assistant about one session, in their own words: who is there, what it is
/// about, what they want from the notes. Kept with the session and sent with every request about it.
public enum SessionBackground {
    /// Characters sent along, at most; when there is more, the newest part is kept.
    public static let limit = 6_000
    /// The same for the running notes, which are updated several times a minute.
    public static let notesLimit = 1_500

    /// Whether anything was written.
    public static func isWritten(_ background: String) -> Bool {
        !background.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// `background` with `entry` added on a line of its own. Unchanged when the entry is blank.
    public static func adding(_ entry: String, to background: String) -> String {
        let entry = entry.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !entry.isEmpty else { return background }
        let current = background.trimmingCharacters(in: .whitespacesAndNewlines)
        return current.isEmpty ? entry : current + "\n" + entry
    }

    /// What the prompts add: the reader's standing context, then what they said about this session.
    public static func extra(standing: String, background: String, limit: Int = limit) -> String {
        let standing = standing.trimmingCharacters(in: .whitespacesAndNewlines)
        var background = background.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !background.isEmpty else { return standing }
        if background.count > limit {
            // Cut at a line when one starts soon, so no entry is sent in half; a long paragraph is cut where it falls.
            let tail = background.suffix(limit)
            if let cut = tail.prefix(limit / 4).firstIndex(where: \.isNewline) {
                background = String(tail[tail.index(after: cut)...])
            } else {
                background = String(tail)
            }
        }
        let block = "About this conversation, written by the reader. Take it as fact, and where it asks for something, do it:\n<background>\n\(background)\n</background>"
        return standing.isEmpty ? block : standing + "\n\n" + block
    }
}

/// A file the reader attached to one session: their script, an agenda, the paper being discussed.
/// Its text is read once and kept with the session, so it is still there if the file moves.
public struct SessionDocument: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    public var name: String
    public var text: String

    public init(id: UUID = UUID(), name: String, text: String) {
        self.id = id
        self.name = name
        self.text = text
    }
}

public enum SessionDocuments {
    /// Characters kept per session, across its documents: they are saved with it.
    public static let limit = 300_000
    /// Characters sent whole with each answer; past this, only the parts that match the question.
    public static let wholeLimit = 24_000

    /// `documents` with one more, its text cut to what still fits; a file of the same name is replaced.
    /// Nil when there is no text to keep or no room left.
    public static func adding(name: String, text: String, to documents: [SessionDocument]) -> [SessionDocument]? {
        var out = documents.filter { $0.name != name }
        let room = limit - out.reduce(0) { $0 + $1.text.count }
        let text = String(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(max(0, room)))
        guard !text.isEmpty else { return nil }
        out.append(SessionDocument(name: name, text: text))
        return out
    }

    public static func base(_ documents: [SessionDocument]) -> KnowledgeBase {
        KnowledgeBase(documents: documents.map { ($0.name, $0.text) })
    }
}
