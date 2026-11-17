import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// A running summary of a session, kept up to date by a language model while listening.
public struct LiveSummary: Codable, Sendable, Equatable {
    /// Markdown: `## ` section headings and `- ` bullets.
    public var text: String
    public var updatedAt: Date
    /// The last line the summary has read; later lines are new to it.
    public var coveredLineID: Int

    public init(text: String, updatedAt: Date, coveredLineID: Int) {
        self.text = text
        self.updatedAt = updatedAt
        self.coveredLineID = coveredLineID
    }
}

/// How much the summary keeps.
public enum SummaryDetail: String, Codable, CaseIterable, Sendable {
    case concise, standard, detailed

    var limits: (keyPoints: Int, total: Int, words: Int) {
        switch self {
        case .concise: (4, 7, 18)
        case .standard: (6, 10, 24)
        case .detailed: (10, 16, 30)
        }
    }
}

/// Which API shape the summary model speaks.
public enum SummaryProvider: String, Codable, CaseIterable, Sendable {
    /// `/chat/completions`: OpenAI, DeepSeek, Qwen (DashScope), OpenRouter, Ollama and most others.
    case openAI
    /// Anthropic's `/v1/messages`, for Claude.
    case anthropic

    public var defaultBaseURL: String {
        switch self {
        case .openAI: "https://api.openai.com/v1"
        case .anthropic: "https://api.anthropic.com"
        }
    }
}

public struct SummaryEndpoint: Sendable, Equatable {
    public var provider: SummaryProvider
    /// Empty uses the provider's default.
    public var baseURL: String
    public var model: String

    public init(provider: SummaryProvider, baseURL: String, model: String) {
        self.provider = provider
        self.baseURL = baseURL
        self.model = model
    }

    public var url: URL? {
        var base = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if base.isEmpty { base = provider.defaultBaseURL }
        while base.hasSuffix("/") { base.removeLast() }
        switch provider {
        case .openAI:
            return URL(string: base.hasSuffix("/chat/completions") ? base : base + "/chat/completions")
        case .anthropic:
            if base.hasSuffix("/v1/messages") { return URL(string: base) }
            return URL(string: base.hasSuffix("/v1") ? base + "/messages" : base + "/v1/messages")
        }
    }

    public func request(apiKey: String, system: String, user: String, maxTokens: Int = 1_500) -> URLRequest? {
        guard let url else { return nil }
        var r = URLRequest(url: url)
        r.httpMethod = "POST"
        r.timeoutInterval = 60
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let body: [String: Any]
        switch provider {
        case .openAI:
            if !key.isEmpty { r.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }
            // No temperature or token cap: newer OpenAI models reject them, and the prompt keeps it short.
            body = [
                "model": model,
                "messages": [["role": "system", "content": system], ["role": "user", "content": user]],
            ]
        case .anthropic:
            r.setValue(key, forHTTPHeaderField: "x-api-key")
            r.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
            body = [
                "model": model,
                "max_tokens": maxTokens,
                "system": system,
                "messages": [["role": "user", "content": user]],
            ]
        }
        r.httpBody = try? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        return r
    }

    public enum ResponseError: Error, Equatable, LocalizedError {
        case api(String), empty

        public var errorDescription: String? {
            switch self {
            case .api(let m): m
            case .empty: "The model returned no text."
            }
        }
    }

    /// The reply text, or the API's own error message.
    public func parse(_ data: Data) throws -> String {
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        if let error = json["error"] as? [String: Any] {
            throw ResponseError.api(error["message"] as? String ?? "\(error)")
        }
        if let error = json["error"] as? String { throw ResponseError.api(error) }
        let text: String
        switch provider {
        case .openAI:
            let choices = json["choices"] as? [[String: Any]] ?? []
            let message = choices.first?["message"] as? [String: Any]
            text = message?["content"] as? String ?? ""
        case .anthropic:
            let content = json["content"] as? [[String: Any]] ?? []
            text = content.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }.joined()
        }
        let cleaned = SummaryPrompt.clean(text)
        if cleaned.isEmpty { throw ResponseError.empty }
        return cleaned
    }
}

/// What to send the model, and when.
public enum SummaryPrompt {
    /// Characters of new transcript sent in one incremental update, at most.
    public static let incrementalLimit = 8_000
    /// Characters of transcript a full rewrite reads; older talk is carried by the current summary.
    public static let rewriteLimit = 24_000
    /// After this many incremental updates, the next one rereads the transcript and rewrites from scratch.
    public static let rewriteEvery = 6

    public static func system(language: String, detail: SummaryDetail = .concise, extra: String = "") -> String {
        let limits = detail.limits
        var prompt = """
        You maintain a live briefing of a conversation that is being transcribed in real time (a meeting, an interview, a call, a lecture, a podcast or a video). The reader glances at it to learn what matters so far, and may have missed the conversation entirely. Write it in \(language), headings included.

        What to write
        - Substance, not a record of the talk. State the topics, claims, facts, numbers, conclusions, and disagreements with their reasons. A bullet states a point; it never narrates who said what in what order.
        - Name a person only when who said it changes the meaning: who owns a decision or a task, who committed to something, who disagrees with whom, who must answer a question. Never write placeholder labels such as "Speaker 1". If someone has no real name, leave them out, or use their role ("the host", "the interviewer", "the candidate") when the transcript makes the role clear.
        - Leave out greetings, small talk, banter, filler, repetition and asides. If a joke carries a real point, state the point plainly. Ask of each bullet: would someone who missed the conversation need this? If not, drop it.
        - Merge related remarks into one bullet. Prefer fewer, denser bullets to many thin ones.

        Context line
        - Open with one line under "## Context": what kind of conversation this is, what it is about, and who is taking part if that is evident. Example: "Political talk show; two hosts on a local election scandal."
        - Infer only from clear evidence in the transcript, and mark what you inferred with a word like "likely" or "appears". When the evidence is thin, state only what is certain, or leave the line out. Never invent names, titles, employers or relationships, and never guess at anyone's private circumstances.
        - Revise the line as more evidence arrives.

        Format
        Markdown with "## " headings and "- " bullets only. Use these sections in this order, each only when it has content:
        ## Context: one plain line, no bullet
        ## Key points: at most \(limits.keyPoints) bullets, most important first
        ## Decisions: what was agreed or settled
        ## Open questions and next steps: unresolved questions, and tasks with their owner when one was named
        If the speakers are "Me" and "Them", add after Key points:
        ## What they want: at most 3 bullets on what Them asked about or cares about most. Refer to Me as "you".
        At most \(limits.total) bullets in total. Each bullet is one sentence of at most \(limits.words) words (about \(limits.words * 2) characters in Chinese, Japanese or Korean).

        Rules
        - Rewrite, never append. As the conversation develops, update, merge or drop earlier bullets. The summary must stay within the limits however long the conversation runs, so make room by dropping what matters least.
        - Keep names, numbers, dates and technical terms exactly as said. The transcript comes from speech recognition: when a name or term looks misheard, correct it only if the context makes the right reading clear.
        - Only what was said. No advice, no opinions, no outside facts.
        - Reply with the summary only, no preamble.
        """
        let extra = extra.trimmingCharacters(in: .whitespacesAndNewlines)
        if !extra.isEmpty {
            prompt += "\n\nThe reader's own instructions, which override the above where they conflict:\n\(extra)"
        }
        return prompt
    }

    public static func incremental(current: String, newTranscript: String) -> String {
        """
        Current summary:
        <summary>
        \(current)
        </summary>

        New transcript since the last update:
        <transcript>
        \(newTranscript)
        </transcript>

        Update the summary so it covers the whole conversation so far. Stay within the limits: fold the new material into existing bullets where it belongs, and drop what now matters least.
        """
    }

    /// `current` carries what came before `transcript` when the transcript had to be cut.
    public static func rewrite(current: String?, transcript: String, truncated: Bool) -> String {
        var out = ""
        if truncated, let current, !current.isEmpty {
            out += """
            Summary of the conversation so far (the transcript below is only its latest part):
            <summary>
            \(current)
            </summary>


            """
        }
        out += """
        Transcript:
        <transcript>
        \(transcript)
        </transcript>

        Write the summary of the whole conversation from scratch.
        """
        return out
    }

    /// Strips code fences and preambles some models add anyway.
    static func clean(_ text: String) -> String {
        var t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.hasPrefix("```") {
            t = t.split(separator: "\n", omittingEmptySubsequences: false).dropFirst().joined(separator: "\n")
            if t.hasSuffix("```") { t = String(t.dropLast(3)) }
            t = t.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return t
    }

    /// Whether enough happened since the last update to ask for another.
    /// Updates come every ~500 new characters, at a pause after at least a sentence,
    /// or after 90 s with anything new, so a slow talker still gets a summary.
    public static func shouldUpdate(newCharacters: Int, sinceUpdate: TimeInterval, sinceLastSpeech: TimeInterval) -> Bool {
        guard newCharacters > 0 else { return false }
        if newCharacters >= 500 { return true }
        if newCharacters >= 80 && sinceLastSpeech >= 6 && sinceUpdate >= 15 { return true }
        return sinceUpdate >= 90
    }
}

extension Transcript {
    /// Lines as "Name: text", in the language spoken. `after` skips lines the summary has read;
    /// `closedOnly` holds back a line still being spoken. Keeps the newest `limit` characters.
    public func summaryText(after lineID: Int?, closedOnly: Bool, limit: Int, name: (SpeakerID) -> String)
        -> (text: String, lastLineID: Int?, truncated: Bool)
    {
        var picked: [String] = []
        var total = 0
        var last: Int?
        var truncated = false
        let candidates = lines.filter { line in
            (lineID.map { line.id > $0 } ?? true) && !(closedOnly && line.isOpen)
                && !line.original.trimmingCharacters(in: .whitespaces).isEmpty
        }
        for line in candidates.reversed() {
            let who = line.speaker.map { name(canonical($0)) } ?? "Speaker"
            let entry = "\(who): \(line.original.trimmingCharacters(in: .whitespacesAndNewlines))"
            if total + entry.count > limit, !picked.isEmpty {
                truncated = true
                break
            }
            picked.insert(entry, at: 0)
            total += entry.count + 1
            if last == nil { last = line.id }
        }
        return (picked.joined(separator: "\n"), last, truncated)
    }
}
