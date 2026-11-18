import Foundation

/// Feedback on the reader's own answers in an interview: a smoother way to say what they just said,
/// and a few quick fixes. Needs Me / Them, so "my" words are known for certain.
public enum PolishPrompt {
    public static func system(language: OutputLanguage, role: String, extra: String = "") -> String {
        let job = role.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "a job" : "a \(role) position"
        // Notes are explanations, so they follow the explanation language; spoken wording stays as spoken.
        let notes = language.explain
        var prompt = """
        You coach a candidate during a live job interview for \(job). The candidate ("Me") just finished answering. They will glance at your reply for two seconds between questions, under pressure, so be brief and concrete. The transcript comes from speech recognition: expect broken sentences, restarts, filler and misheard words, and read through them to what the candidate meant.

        Reply in this format:
        Line 1: a smoother version of what the candidate just said: at most 2 short sentences (about 40 words), first person, in the language the candidate spoke, ready to say. Keep their meaning and facts; add nothing they didn't say, except a number from the knowledge base that is clearly the one they were reaching for.
        Then at most 2 "- " bullets, each under 12 words, only if clearly worth it:
        - "wrong → right" for a real grammar or word error, or an unnatural phrase and its natural form
        - "Next time: …" for one habit to fix in later answers (lead with the result, cut filler, answer the question first, add a number)
        - "Add now: …" for one line to say right away when the answer missed the question
        Bullets in \(notes); words to say stay in the language the candidate spoke. No explanations, no praise, no headings.

        Reply with exactly SKIP when the answer was already clear and correct, or was too short to matter (a yes, a thanks, a one-word reply).
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
