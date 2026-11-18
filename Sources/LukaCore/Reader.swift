import Foundation

/// The names the reader goes by, to notice when a meeting turns to them.
public enum ReaderNames {
    /// Names typed as a list: commas (either width), slashes or 、 separate them.
    public static func parse(_ raw: String) -> [String] {
        raw.split(whereSeparator: { ",，/、;；".contains($0) })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// Whether `text` mentions one of `names`: as a whole word for Latin names, anywhere for others.
    public static func mentions(_ text: String, names: [String]) -> Bool {
        names.contains { name in
            if name.unicodeScalars.allSatisfy({ $0.isASCII }) {
                let pattern = "\\b" + NSRegularExpression.escapedPattern(for: name) + "\\b"
                return text.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
            }
            return text.contains(name)
        }
    }

    /// A line for the prompts, so the model can tell the reader apart in the notes and the answers.
    public static func promptLine(_ names: [String]) -> String {
        guard !names.isEmpty else { return "" }
        let list = names.map { "\"\($0)\"" }.joined(separator: " or ")
        return "The reader is called \(list). When someone addresses them by name, the question is for the reader. In notes, write the reader's own tasks as [Action → me]."
    }
}

/// What a meeting has asked of the reader, for the strip at the top of the notes.
public struct ForMeItem: Equatable, Sendable, Identifiable {
    public enum Kind: Sendable { case mention, action }
    public let kind: Kind
    public let text: String
    /// The line it was said in, for a mention.
    public let lineID: Int?
    public var id: String { "\(kind)-\(lineID ?? 0)-\(text)" }
}

extension Transcript {
    /// The latest lines from others that mention the reader by name, and the reader's own tasks
    /// in the notes. Found locally; nothing is sent to the model for it.
    public func forMe(names: [String], limit: Int = 3) -> [ForMeItem] {
        var items: [ForMeItem] = []
        if !names.isEmpty {
            let said = lines.filter { Channel($0.speaker) != .me && ReaderNames.mentions($0.original, names: names) }
            items += said.suffix(limit).map {
                ForMeItem(kind: .mention, text: $0.original.trimmingCharacters(in: .whitespaces), lineID: $0.id)
            }
        }
        if let notes = summary?.text {
            let mine = notes.split(separator: "\n").map(String.init).filter {
                $0.range(of: "[Action → me]", options: .caseInsensitive) != nil
                    || $0.range(of: "[Action -> me]", options: .caseInsensitive) != nil
            }
            items += mine.suffix(limit).map { line in
                var text = line.trimmingCharacters(in: .whitespaces)
                for marker in ["- ", "* ", "• "] where text.hasPrefix(marker) { text = String(text.dropFirst(marker.count)) }
                for tag in ["[Action → me]", "[Action -> me]"] {
                    text = text.replacingOccurrences(of: tag, with: "", options: .caseInsensitive)
                }
                return ForMeItem(kind: .action, text: text.trimmingCharacters(in: .whitespaces), lineID: nil)
            }
        }
        return items
    }
}

/// "Catch me up": what was just said, in a few bullets, on request.
public enum CatchUpPrompt {
    public static func system(language: OutputLanguage, extra: String = "") -> String {
        var prompt = """
        The reader stepped away from a live conversation for a moment and wants to catch up. From the recent transcript, reply with:
        Line 1: "Now: " and the topic being discussed right now, at most 8 words.
        Then at most 3 "- " bullets, each at most 14 words: what was said or decided, and anything asked of the reader, first if there is.
        \(language.summaryRule) No headings, no preamble. The transcript comes from speech recognition and may contain errors; read through them.
        """
        let extra = extra.trimmingCharacters(in: .whitespacesAndNewlines)
        if !extra.isEmpty { prompt += "\n\nAbout this conversation, from the reader:\n\(extra)" }
        return prompt
    }

    public static func user(conversation: String) -> String {
        "The recent conversation:\n<conversation>\n\(conversation)\n</conversation>"
    }
}
