import Foundation

/// What kind of conversation the assistant is following. It decides how the summary is kept
/// and how readily questions get answered.
public enum AssistantMode: String, Codable, CaseIterable, Sendable {
    /// A talk, lecture, podcast or video: one speaker, one line of argument.
    case lecture
    /// A working meeting or call.
    case meeting
    /// An interview in which the reader is the one being interviewed.
    case interview

    /// What choosing a mode turns on and off. Each stays a separate switch afterwards.
    public struct Scene: Equatable, Sendable {
        public var summary: Bool
        public var answers: Bool
        /// Me / Them: the microphone is the reader, Mac audio everyone else, numbered.
        public var separatesSpeakers: Bool
        public var pinsQuestions: Bool
        /// Polish my answers; nil leaves it as it is.
        public var polishes: Bool?
    }

    public var scene: Scene {
        switch self {
        case .lecture: Scene(summary: false, answers: false, separatesSpeakers: false, pinsQuestions: false, polishes: nil)
        case .meeting: Scene(summary: true, answers: false, separatesSpeakers: true, pinsQuestions: false, polishes: nil)
        case .interview: Scene(summary: false, answers: true, separatesSpeakers: true, pinsQuestions: true, polishes: true)
        }
    }

    /// Whether the summary is one overview rewritten whole. No mode does any more: a lecture's notes grow
    /// section by section like the others, so nothing already read moves.
    public var rewritesSummary: Bool { false }

    /// Lectures get no answers: their questions are the speaker's own, or put to the room.
    /// Meetings only get help with a factual question; interviews with every interview question.
    public var eagerness: AnswerEagerness {
        switch self {
        case .lecture: .off
        case .meeting: .conservative
        case .interview: .eager
        }
    }

    /// Added to the summary prompt.
    var summaryGuidance: String {
        switch self {
        case .lecture:
            "This is a talk, lecture, podcast or video with a main line of argument, and the reader wants to follow it now and review it later. Number the headings in order (\"## 1. …\", \"## 2. …\"), one per part of the talk, following the speaker's own structure. Under each, 1 to 3 bullets: the point, the example or evidence behind it, and any formula or number. When the speaker stresses something (\"the key point is…\"), keep it. When the speaker introduces or defines a term, add a bullet of exactly this shape: \"[Term] the term as said — a short gloss in the notes' language — a one-line definition\". Each term once."
        case .meeting:
            "This is a working meeting. Be sure to capture decisions, commitments with their owners and dates, numbers, and questions left open. Start such bullets with a tag, kept in English: [Decision], [Action → owner] (the owner's name, or me when it is the reader), [Open ?] for a question left open, [Number] for a figure worth keeping. When something said later reverses an earlier decision, add a bullet starting with ↺ that says what changed; never edit the earlier one."
        case .interview:
            "This is an interview. Note each question the interviewer asks as a \"**Question:**\" bullet, shortened, and then in one bullet what the answer covered. Note everything said about the role, the team, the process, pay and next steps."
        }
    }

    /// Added to the answer prompt. `role` is the job the reader is interviewing for.
    func answerGuidance(role: String) -> String {
        switch self {
        case .lecture:
            return ""
        case .meeting:
            return """
            This is a meeting. Most questions in a meeting pass between the participants and need no help from you. Reply SKIP to: opinions and discussion ("what do you think?", "should we…?"), check-ins and confirmations ("right?", "does that work?", "any objections?"), logistics and scheduling, requests to someone about their own work or status ("did you send it?", "where are we on…?"), rhetorical questions, and anything answered in the next lines.
            Answer only a factual or technical question where a short, correct answer would help the reader take part: a definition, a fact, a number, how something works. When in doubt, SKIP.
            One exception: a question put to the reader themselves (by name, or "you" right after the reader spoke) always gets an answer. Add a line "TYPE: for-me" right after the SOURCE line, and instead of the bullets give 3 cue lines, starting with ①, ② and ③, each at most 10 words, in the words the reader could say: ① my position ② the evidence or number behind it ③ the next step or what I need. Ground them in the conversation and the knowledge base; when unsure, a cue can be to ask a clarifying question. Never invent the reader's numbers or commitments.
            """
        case .interview:
            let role = role.trimmingCharacters(in: .whitespacesAndNewlines)
            let job = role.isEmpty ? "a job" : "a \(role) position"
            let field = role.isEmpty ? "the field" : "a \(role)"
            return """
            This is a job interview for \(job), and the reader is the candidate. Answer only questions the interviewer puts to the candidate as part of the interview, of these types:
            - technical: knowledge questions for the role. For \(field) this means whatever the role needs; for data roles that includes statistics and probability, experiment design and A/B testing, causal inference, machine learning, metrics, SQL, Python and data modelling. Treat these as real questions even when phrased as a statement or a scenario ("Say retention dropped 10% last week…").
            - case: a business or product problem to work through.
            - behavioral: "tell me about a time…", conflict, failure, influence, leadership.
            - experience: the candidate's resume, projects and past roles, "walk me through…".
            - motivation: why this role, company or career move; strengths, weaknesses, goals.
            - reverse: "do you have any questions for us?" Suggest 2 or 3 sharp questions to ask.
            Reply SKIP to everything else: small talk, logistics (audio, screen sharing, scheduling, timing), the interviewer describing the company, team, role or process, transitions ("great, let's move on"), the interviewer thinking aloud, questions the interviewer answers themselves, short check-ins on the candidate's last answer ("does that make sense?", "so you used Python?"), and every question the candidate asks (a speaker named "Me", or someone asking about the role, the team, pay, the process or next steps).

            How to answer an interview question:
            - Right after the SOURCE line, add a line "TYPE: technical", "TYPE: case", "TYPE: behavioral", "TYPE: experience", "TYPE: motivation" or "TYPE: reverse".
            - Cues are in the first person where they are words to say ("I re-ran it with a holdout").
            - The skeleton for each type, one cue each:
              technical: ① the answer in one plain sentence ② when to use it ③ the pitfall or caveat worth mentioning.
              case (product or metric): ① clarify the goal ② a north-star metric and two guardrails ③ the approach (segments, funnel, test) and the trade-off.
              case (a metric moved): ① check the definition and the data ② internal, external or logging causes ③ the segments to cut and the next step.
              behavioral: ① situation and task in one line ② what I did, "I" not "we" ③ the result with a number, and the lesson.
              experience: ① the problem ② my role and method ③ the impact, with a number.
              motivation: ① and ② two reasons tied to this company or role, from the candidate's background.
              reverse: ①②③ three sharp questions to ask, each at most 12 words.
            - Never invent the candidate's stories, projects or numbers. With nothing in the knowledge base, the cues say what kind of story to pick and the anchor is "⚓ —".
            """
        }
    }
}

/// How much it takes for a line to be sent to the model as a possible question.
public enum AnswerEagerness: Sendable, Equatable {
    /// Nothing is answered.
    case off
    /// Only a line that ends in a question mark.
    case conservative
    /// A line that ends in a question or a prompt.
    case normal
    /// Any line with a question in it, and any substantial line from the other side.
    case eager

    func accepts(_ text: String, fromThem: Bool) -> Bool {
        switch self {
        case .off:
            return false
        case .conservative:
            guard let last = Questions.lastSentence(text) else { return false }
            return last.hasSuffix("?") || last.hasSuffix("？")
        case .normal:
            return Questions.isQuestion(text)
        case .eager:
            if Questions.isQuestion(text) || text.contains("?") || text.contains("？") { return true }
            // In an interview the other side's every turn may call for a response; the model decides.
            return fromThem && SummaryPrompt.weight(text) >= 60
        }
    }
}
