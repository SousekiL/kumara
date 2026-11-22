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

        Reply with exactly these six lines, nothing else:
        STATUS: complete, when the answer covered what was asked, or partial, when it missed part of it.
        USED: the story, project or number the candidate relied on, at most 6 words, or - for none.
        FIX: the single most useful fix for the candidate's next turn, at most 12 words, or - when nothing is worth fixing. One of: "Add now: …" a line to say right away when the answer missed the question; "Next: …" one habit for later answers (lead with the result, cut filler, add a number). The fix in \(notes); words to say stay in the language the candidate spoke.
        DETAIL: one detail the candidate left out that matters: something an interviewer for this role expects to hear and won't ask for, so leaving it out reads as not knowing it. At most 16 words, or - for none. Prefer a concrete fact from the knowledge base about the same project or story (the scale, the method and why it was chosen, their own part, how the result was measured, the number), copied exactly; say what to add in \(notes), with the words to say in the language the candidate spoke. When the knowledge base has nothing on it, name the kind of detail that was missing ("how the lift was measured") and never make up a fact. Only now and then: - when the answer already had the substance, when it wasn't about a project or experience, or when the detail is minor.
        WORDS: the candidate's language slips, at most 2, most useful first, separated by " | ", or - for none. Each is "what they said → what to say", both sides in the language the candidate spoke, at most 10 words: a wrong word, a wrong form or tense, an unnatural phrase, or a word they clearly couldn't find and talked around ("the thing when one class is much bigger → class imbalance"). Only slips the candidate would want to hear about: nothing for filler, restarts or style, and nothing that looks like the recognizer mishearing a correct word.
        BETTER: a smoother version of what the candidate said, for reviewing after the interview: at most 2 short sentences (about 40 words), first person, in the language the candidate spoke. Keep their meaning and facts; add nothing they didn't say, except a number from the knowledge base that is clearly the one they were reaching for.
        No explanations, no praise.

        Reply with exactly SKIP only when it wasn't really an answer: too short to matter (a yes, a thanks, a one-word reply) or small talk.
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

    /// The feedback on one answer.
    public struct Feedback: Equatable, Sendable {
        /// "complete" or "partial", when the model said.
        public var status: String?
        /// The story, project or number the answer relied on.
        public var used: String?
        /// The one fix to show during the interview, under the question; nil when nothing is worth fixing.
        public var fix: String?
        /// A smoother version, kept for the review afterwards.
        public var better: String?
        /// Language slips, each "what I said → what to say".
        public var words: [String] = []
        /// A detail that mattered and was left out, to add while the question is still open.
        public var detail: String?
    }

    /// The fix as far as it has come in; nil until there is one to show.
    public static func partial(_ reply: String) -> String? {
        guard let fix = fields(SummaryPrompt.clean(reply))["FIX"], !fix.isEmpty, fix != "-", !AnswerPrompt.maySkip(fix) else { return nil }
        return fix
    }

    /// The slips on a WORDS line: separated by "|", none for "-".
    static func words(_ value: String?) -> [String] {
        (value ?? "").split(separator: "|").map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && $0 != "-" && $0 != "—" }
    }

    /// The feedback, or nil when the model skipped. A reply in no known format counts as a fix, as before.
    public static func parse(_ reply: String) -> Feedback? {
        let text = SummaryPrompt.clean(reply)
        let bare = text.trimmingCharacters(in: CharacterSet(charactersIn: " .。\n")).uppercased()
        guard !bare.isEmpty, bare != "SKIP" else { return nil }
        let f = fields(text)
        guard !f.isEmpty else { return Feedback(fix: text) }
        func value(_ key: String) -> String? {
            guard let v = f[key]?.trimmingCharacters(in: .whitespaces), !v.isEmpty, v != "-", v != "—" else { return nil }
            return v
        }
        let status = value("STATUS")?.lowercased()
        return Feedback(status: status.map { $0.hasPrefix("partial") ? "partial" : "complete" },
                        used: value("USED"), fix: value("FIX"), better: value("BETTER"), words: words(f["WORDS"]),
                        detail: value("DETAIL"))
    }

    /// "KEY: value" lines; a value can run on to the following lines until the next key.
    static func fields(_ text: String) -> [String: String] {
        let keys = ["STATUS", "USED", "FIX", "DETAIL", "WORDS", "BETTER"]
        var out: [String: String] = [:]
        var current: String?
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if let key = keys.first(where: { trimmed.uppercased().hasPrefix($0 + ":") }) {
                current = key
                out[key] = String(trimmed.dropFirst(key.count + 1)).trimmingCharacters(in: .whitespaces)
            } else if let current, !trimmed.isEmpty {
                out[current, default: ""] += (out[current, default: ""].isEmpty ? "" : " ") + trimmed
            }
        }
        return out
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

/// What a question's card shows about my own answers to it.
public struct Coaching: Equatable, Sendable {
    /// The fix from my latest answer to it: an earlier one has been said or passed by.
    public var fix: String?
    /// A detail my latest answer to it left out and that matters.
    public var detail: String?
    /// Language slips, each "what I said → what to say", newest last.
    public var slips: [String] = []
    public var isEmpty: Bool { fix == nil && detail == nil && slips.isEmpty }

    public init(fix: String? = nil, detail: String? = nil, slips: [String] = []) {
        self.fix = fix
        self.detail = detail
        self.slips = slips
    }
}

/// One interview question and how it went, for the question tracker.
public struct QuestionLogEntry: Equatable, Sendable, Identifiable {
    public let question: QuestionAnswer
    /// "complete" or "partial" once my answer has been reviewed; nil before.
    public var status: String?
    /// The stories or numbers my answers to it relied on.
    public var used: [String] = []
    public var id: Int { question.id }
}

extension Transcript {
    /// The interviewer's questions in order, each with how my answer went: a polish belongs to the
    /// question answered last before it. Built from the answers already made, with no extra request.
    /// The feedback on my answers to each heard question, by the question's line. It sits under the
    /// question's card, never in one of its own. An answer I gave to a question that got no card
    /// (one judged to need no answer) has no card to sit under, so its feedback isn't shown.
    public var coaching: [Int: Coaching] {
        let cards = answers.filter { $0.kind != "polish" && $0.kind != "asked" }.map(\.id).sorted()
        var out: [Int: Coaching] = [:]
        for item in answers where item.kind == "polish" {
            // A polish carries the line my answer ended on: the card is the last question before it.
            guard let card = cards.last(where: { $0 < item.id }) else { continue }
            let between = lines.filter { $0.id > card && $0.id < item.id && Channel($0.speaker) == .them }
            if between.contains(where: { AnswerEagerness.eager.accepts($0.original, fromThem: true) }) { continue }
            if !item.answer.isEmpty { out[card, default: Coaching()].fix = item.answer }
            if let detail = item.detail { out[card, default: Coaching()].detail = detail }
            out[card, default: Coaching()].slips += item.words ?? []
        }
        return out.filter { !$0.value.isEmpty }
    }

    public var questionLog: [QuestionLogEntry] {
        var log: [QuestionLogEntry] = []
        for item in answers {
            if item.kind == "polish" {
                guard !log.isEmpty else { continue }
                if let status = item.status { log[log.count - 1].status = status }
                if let used = item.used, !log[log.count - 1].used.contains(used) { log[log.count - 1].used.append(used) }
            } else if item.kind != "reverse", item.kind != "asked" {
                log.append(QuestionLogEntry(question: item))
            }
        }
        return log
    }
}
