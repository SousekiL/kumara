import Foundation

/// A name for a finished session, written by the model from what was said in it.
public enum TitlePrompt {
    /// Below this much speech a session is a test or a false start: it keeps its time as its name.
    public static let minWeight = 400

    public static let system = """
    You name a recorded conversation for a list of sessions, so its owner can find it again at a glance.

    Rules
    - When it is a recurring or named meeting (a weekly meeting, a stand-up, a sync, a 1:1, a review, an interview with a company, a class or talk with a title), use that name as the people in it would say it: "TCP Weekly Meeting", "Appier Interview", "Design Review". When the earlier session names listed below include this same meeting, use the same name.
    - Otherwise name its main topic in a few words: specific enough to tell it from other sessions, not a sentence.
    - At most 6 words, or 14 characters in Chinese, Japanese or Korean. No date, no time, no quotes, no full stop.
    - Write it in the language the conversation was mostly held in; keep a meeting's or company's own name as it was said.
    - The transcript comes from speech recognition and may contain errors; read through them.

    Reply with the name alone on one line. Reply with exactly SKIP when there is too little to name: a microphone test, a few stray words.
    """

    /// `opening` and `ending` are how the session began and how it ended; a long one is not sent whole.
    public static func user(opening: String, ending: String, notes: String?, background: String, tags: [String], earlier: [String]) -> String {
        var parts: [String] = []
        let background = background.trimmingCharacters(in: .whitespacesAndNewlines)
        if !background.isEmpty { parts.append("What its owner wrote about it:\n<background>\n\(background.prefix(600))\n</background>") }
        if !tags.isEmpty { parts.append("Its tags: " + tags.joined(separator: ", ")) }
        if !earlier.isEmpty { parts.append("Earlier session names, for recurring meetings:\n" + earlier.map { "- " + $0 }.joined(separator: "\n")) }
        if let notes, !notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { parts.append("Notes taken during it:\n<notes>\n\(notes.prefix(2_000))\n</notes>") }
        parts.append("How it began:\n<opening>\n\(opening)\n</opening>")
        if !ending.isEmpty { parts.append("How it ended:\n<ending>\n\(ending)\n</ending>") }
        return parts.joined(separator: "\n\n")
    }

    /// The name in a reply, or nil when the model declined or wrote something that isn't one.
    public static func parse(_ reply: String) -> String? {
        guard let line = SummaryPrompt.clean(reply).split(whereSeparator: \.isNewline).map({ $0.trimmingCharacters(in: .whitespaces) }).first(where: { !$0.isEmpty })
        else { return nil }
        var name = line
        for prefix in ["Title:", "Name:", "标题：", "名称："] where name.hasPrefix(prefix) { name = String(name.dropFirst(prefix.count)) }
        name = name.trimmingCharacters(in: CharacterSet(charactersIn: " \"'“”‘’「」《》*#.。"))
        guard !name.isEmpty, name.uppercased() != "SKIP", SummaryPrompt.weight(name) <= 80 else { return nil }
        return name
    }

    /// `name`, told apart from sessions already called that: a recurring meeting gets its date,
    /// and its time too when there were two that day.
    public static func unique(_ name: String, among existing: [String], date: Date, calendar: Calendar = .current) -> String {
        let taken = Set(existing.map { $0.lowercased() })
        guard taken.contains(name.lowercased()) else { return name }
        let c = calendar.dateComponents([.month, .day, .hour, .minute], from: date)
        let dated = name + String(format: " %02d-%02d", c.month ?? 0, c.day ?? 0)
        guard taken.contains(dated.lowercased()) else { return dated }
        return dated + String(format: " %02d:%02d", c.hour ?? 0, c.minute ?? 0)
    }
}

extension Transcript {
    /// How the session began and ended, for naming it: a meeting usually says what it is at the start.
    public func titleInput(name: (SpeakerID) -> String, opening: Int = 1_500, ending: Int = 1_500) -> (opening: String, ending: String, weight: Int) {
        func text(_ line: Line) -> String { (line.speaker.map(name).map { $0 + ": " } ?? "") + line.original.trimmingCharacters(in: .whitespaces) }
        let weight = lines.reduce(0) { $0 + SummaryPrompt.weight($1.original) }
        var head: [String] = [], used = 0, next = 0
        while next < lines.count, used < opening {
            let line = text(lines[next])
            head.append(String(line.prefix(opening - used)))
            used += line.count
            next += 1
        }
        var tail: [String] = []
        used = 0
        var last = lines.count - 1
        while last >= next, used < ending {
            let line = text(lines[last])
            tail.insert(String(line.suffix(ending - used)), at: 0)
            used += line.count
            last -= 1
        }
        return (head.joined(separator: "\n"), tail.joined(separator: "\n"), weight)
    }
}
