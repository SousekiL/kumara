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

    public var eagerness: AnswerEagerness {
        switch self {
        case .lecture: .conservative
        case .meeting: .normal
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

    /// Added to the answer prompt.
    var answerGuidance: String {
        switch self {
        case .lecture:
            "This is a talk or lecture, so be selective. Most questions in a talk are rhetorical or answered by the speaker a moment later: reply SKIP to those. Answer only a question genuinely put to the audience or left open, and explain the idea behind it briefly."
        case .meeting:
            ""
        case .interview:
            "This is an interview and the reader is the one being interviewed. Treat prompts and requests as questions too: \"tell me about…\", \"walk me through…\", or a statement that invites a response. Write the answer in the first person, as the reader would say it. For a behavioral question give a situation, action, result outline drawn from the knowledge base; for a technical one give the answer, then the key terms to mention. Reply SKIP only to pure small talk and logistics."
        }
    }
}

/// How much it takes for a line to be sent to the model as a possible question.
public enum AnswerEagerness: Sendable {
    /// Only a line that ends in a question mark.
    case conservative
    /// A line that ends in a question or a prompt.
    case normal
    /// Any line with a question in it, and any substantial line from the other side.
    case eager

    func accepts(_ text: String, fromThem: Bool) -> Bool {
        switch self {
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
