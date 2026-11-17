import Foundation

/// Spots the questions someone asks you, so captions can keep the latest one in view while you answer.
/// Pure text rules, no extra model calls: Soniox punctuates, so a question mark does most of the work,
/// and the openers catch interview prompts that are questions in all but punctuation ("Walk me through…").
public enum Questions {
    static let promptOpeners = [
        "tell me", "walk me through", "talk me through", "take me through", "describe", "explain",
        "give me an example", "give us an example", "share an example", "share a time", "talk about",
        "can you tell", "could you tell", "i'd like to hear", "i would like to hear", "i'd love to hear",
        "what would you", "how would you", "why do you", "why did you", "what made you",
    ]

    static let questionWords: Set<String> = [
        "what", "why", "how", "when", "where", "which", "who", "whom", "whose",
        "do", "does", "did", "are", "is", "was", "were", "can", "could", "would", "will", "should",
        "have", "has", "had", "may", "might",
    ]

    /// Whether a line ends in a question or an interview prompt. Only its last sentence counts:
    /// "Why insurance? Okay, great." has moved on.
    public static func isQuestion(_ text: String) -> Bool {
        guard let sentence = lastSentence(text) else { return false }
        if sentence.hasSuffix("?") || sentence.hasSuffix("？") { return true }
        // Chinese and Japanese questions often end in a particle instead of a mark.
        let bare = sentence.trimmingCharacters(in: CharacterSet(charactersIn: ".。!！ "))
        if let last = bare.last, "吗呢么嗎か".contains(last), bare.count >= 4 { return true }
        let lower = bare.lowercased()
        let words = lower.split(separator: " ")
        guard words.count >= 4 else { return false }
        if promptOpeners.contains(where: { lower.hasPrefix($0) }) { return true }
        // "So, what…" / "And how…": skip one leading filler before the question word.
        let fillers: Set<String> = ["so", "and", "okay", "ok", "well", "now", "great", "alright", "right"]
        let first = words[0].trimmingCharacters(in: .punctuationCharacters)
        let second = words[1].trimmingCharacters(in: .punctuationCharacters)
        if questionWords.contains(first) { return true }
        return fillers.contains(first) && questionWords.contains(second)
    }

    /// The last sentence, with its closing mark.
    static func lastSentence(_ text: String) -> String? {
        var sentences: [String] = []
        var current = ""
        for ch in text {
            current.append(ch)
            if ".?!。？！\n".contains(ch) {
                sentences.append(current)
                current = ""
            }
        }
        sentences.append(current)
        return sentences.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .last { $0.count >= 4 && $0.contains(where: \.isLetter) }
    }
}

extension Transcript {
    /// The latest question asked, for pinning above the captions.
    /// With Me / Them channels it only looks at Them; otherwise at anyone. Questions older than
    /// `maxAge`, or followed by `maxLinesAfter` other lines, are no longer pinned.
    public func pinnedQuestion(channelsOnly: Bool, now: Date = .now, maxAge: TimeInterval = 600, maxLinesAfter: Int = 40) -> Line? {
        for (offset, line) in lines.reversed().enumerated() {
            if offset > maxLinesAfter { return nil }
            if now.timeIntervalSince(line.startedAt) > maxAge { return nil }
            let channel = Channel(line.speaker)
            if channelsOnly && channel != .them { continue }
            if !channelsOnly && channel == .me { continue }
            if Questions.isQuestion(line.original) { return line }
        }
        return nil
    }
}
