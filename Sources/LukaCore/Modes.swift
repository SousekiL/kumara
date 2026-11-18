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

    /// A lecture gets one structured summary, rewritten as it goes; the others get running notes.
    public var rewritesSummary: Bool { self == .lecture }

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
            "This is a talk, lecture, podcast or video with a main line of argument. Follow the speaker's own structure: the thesis, the main arguments, the evidence or examples behind them, and the takeaways. Define the key terms the speaker introduces."
        case .meeting:
            "This is a working meeting. Be sure to capture decisions, commitments with their owners and dates, numbers, and questions left open."
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
            - Words to say are in the first person, as the candidate would say them.
            - technical: the correct answer in plain words first; hints with the key terms, formulas or caveats worth mentioning.
            - case: hints that give a structure: clarify the goal, the metrics to look at, hypotheses, how to test them.
            - behavioral and experience: a situation, action, result outline drawn from the knowledge base. If it has nothing that fits, say which kind of story to pick and how to structure it; never invent one.
            - motivation: from the knowledge base, connecting the candidate's background to this role.
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
