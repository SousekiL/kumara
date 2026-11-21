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
