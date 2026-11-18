import Foundation

/// Feedback on the reader's own answers in an interview: a smoother way to say what they just said,
/// and a few quick fixes. Needs Me / Them, so "my" words are known for certain.
public enum PolishPrompt {
    public static func system(language: OutputLanguage, role: String, extra: String = "") -> String {
        let job = role.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "a job" : "a \(role) position"
        // Notes are explanations, so they follow the explanation language; spoken wording stays as spoken.
        let notes = language.explain
        var prompt = """
        You coach a candidate during a live job interview for \(job). The candidate ("Me") just finished answering. The transcript comes from speech recognition, so expect broken sentences, restarts, filler and misheard words; read through them to what the candidate meant.

        Reply in this format:
        Line 1: a smoother version of what the candidate just said, 1 to 4 sentences, in the same language the candidate spoke, in the first person, ready to say. Keep their meaning, their facts and their level of detail. Don't add facts, numbers or claims they didn't make, except a number or result from the knowledge base, which you may add only if it is clearly the one they were reaching for.
        Then at most 3 "- " bullets, only for what really matters, most useful first:
        - a clear grammar or word-choice error, as "wrong → right" (no punctuation or style nitpicks)
        - an unnatural or non-native phrasing, with the natural way to say it
        - the answer didn't address the question: one sentence they can add right now to get back to it
        - the point got lost: the one-line takeaway they can close with
        - a result or number from the knowledge base that would strengthen the answer
        - heavy filler or hedging ("um", "like", "kind of", "I think maybe"): name it briefly
        Write the bullets' explanations in \(notes); anything to say aloud stays in the language the candidate spoke.

        Reply with exactly SKIP when the answer was already clear and correct, or was too short to matter (a yes, a thanks, a one-word reply). No preamble, no headings, no praise.
        """
        let extra = extra.trimmingCharacters(in: .whitespacesAndNewlines)
        if !extra.isEmpty { prompt += "\n\nThe reader's own instructions, which override the above where they conflict:\n\(extra)" }
        return prompt
    }

    public static func user(question: String?, answer: String, knowledge: String) -> String {
        var out = ""
        if !knowledge.isEmpty { out += "The candidate's knowledge base (excerpts):\n<knowledge>\n\(knowledge)\n</knowledge>\n\n" }
        if let question, !question.isEmpty { out += "The interviewer asked:\n<question>\n\(question)\n</question>\n\n" }
        out += "The candidate's answer, as transcribed:\n<answer>\n\(answer)\n</answer>"
        return out
    }

    /// The feedback, or nil when the model skipped.
    public static func parse(_ reply: String) -> String? {
        let text = SummaryPrompt.clean(reply)
        let bare = text.trimmingCharacters(in: CharacterSet(charactersIn: " .。\n")).uppercased()
        return bare.isEmpty || bare == "SKIP" ? nil : text
    }
}

extension Transcript {
    /// The reader's latest answer once they've finished it: the run of Me lines since Them last spoke,
    /// when Them has spoken again or nothing has come in for `pause` seconds. Nil for a short reply,
    /// a run with a line already handled, or one still being spoken.
    public func finishedAnswer(handled: Set<Int>, now: Date = .now, pause: TimeInterval = 5, minWeight: Int = 80)
        -> (ids: [Int], text: String, question: String?)?
    {
        let recent = Array(lines.suffix(40))
        // The last run of Me lines, and whether Them spoke after it.
        guard let lastMe = recent.lastIndex(where: { Channel($0.speaker) == .me }) else { return nil }
        var start = lastMe
        while start > 0, Channel(recent[start - 1].speaker) == .me { start -= 1 }
        let run = recent[start...lastMe]
        guard !run.contains(where: { handled.contains($0.id) || $0.isOpen }) else { return nil }
        let themAfter = recent[(lastMe + 1)...].contains { Channel($0.speaker) == .them }
        let quiet = lastMe == recent.count - 1 && provisional == nil && now.timeIntervalSince(updatedAt) >= pause
        guard themAfter || quiet else { return nil }
        let text = run.map { $0.original.trimmingCharacters(in: .whitespaces) }.joined(separator: " ")
        guard SummaryPrompt.weight(text) >= minWeight else { return nil }
        let question = recent[..<start].last { Channel($0.speaker) == .them }?.original
        return (run.map(\.id), text, question)
    }
}
