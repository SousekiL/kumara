import Foundation

/// The language the assistant writes in. In guide mode it explains in one language (the translation's)
/// and keeps what matters in its own words (terms, quotes, things to say) in the language being spoken.
public struct OutputLanguage: Sendable, Equatable {
    /// English name of the language for explanations, such as "Simplified Chinese".
    public var explain: String
    /// English name of the spoken language in guide mode; nil writes everything in `explain`.
    public var spoken: String?

    public init(_ explain: String, spoken: String? = nil) {
        self.explain = explain
        // Guide mode only means something when the two differ.
        self.spoken = spoken == explain ? nil : spoken
    }

    public var isGuide: Bool { spoken != nil }

    /// The language rule for the summary's prompt.
    var summaryRule: String {
        guard let spoken else { return "Write in \(explain), headings included." }
        return "Write in \(explain), headings included, but keep in \(spoken), exactly as said: technical terms, names, and any short phrase whose exact wording matters (a definition, a commitment, a key line). The first time a technical term appears, add a brief \(explain) gloss in parentheses after it."
    }

    /// The language rule for the answers' prompt.
    var answerRule: String {
        guard let spoken else { return "Write in \(explain)." }
        return "Explain in \(explain): structure, hints and notes. Everything meant to be said aloud in the conversation (the answer itself, a sample answer, a phrase to use, questions to ask back) goes in \(spoken), ready to say as it stands. Keep technical terms in \(spoken) throughout, with a brief \(explain) gloss the first time if it helps."
    }
}
