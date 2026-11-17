import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Running notes of a session, added to by a language model while listening.
public struct LiveSummary: Codable, Sendable, Equatable {
    /// Markdown: `## ` topic headings and `- ` bullets, in the order things were said.
    public var text: String
    public var updatedAt: Date
    /// The last line the summary has read; later lines are new to it.
    public var coveredLineID: Int
    /// One line on what kind of conversation this is; shown above the notes.
    public var context: String?
    /// How many lines the notes had before the latest update; the lines from there on are new.
    public var freshLine: Int?

    public init(text: String, updatedAt: Date, coveredLineID: Int, context: String? = nil, freshLine: Int? = nil) {
        self.text = text
        self.updatedAt = updatedAt
        self.coveredLineID = coveredLineID
        self.context = context
        self.freshLine = freshLine
    }
}

/// How much the summary keeps.
public enum SummaryDetail: String, Codable, CaseIterable, Sendable {
    case concise, standard, detailed

    /// For an overview: main points, bullets in all, and words per bullet.
    var overviewLimits: (points: Int, total: Int, words: Int) {
        switch self {
        case .concise: (5, 8, 20)
        case .standard: (8, 13, 26)
        case .detailed: (12, 20, 32)
        }
    }

    /// Bullets per update, and words per bullet.
    var limits: (bullets: String, words: Int) {
        switch self {
        case .concise: ("1 or 2", 20)
        case .standard: ("2 to 4", 26)
        case .detailed: ("3 to 6", 32)
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

/// What to send the model, and when. The summary is running notes: each update adds lines
/// at the end for what was just said, and what is already written stays as it is.
public enum SummaryPrompt {
    /// Characters of new transcript sent in one update, at most.
    public static let incrementalLimit = 12_000
    /// Characters of transcript a full rewrite (the refresh button) reads.
    public static let rewriteLimit = 60_000
    /// Characters of the notes' end sent along, so the model continues them instead of repeating them.
    public static let tailLimit = 700

    public static func system(language: String, detail: SummaryDetail = .concise, mode: AssistantMode = .meeting, extra: String = "") -> String {
        if mode.rewritesSummary { return overviewSystem(language: language, detail: detail, mode: mode, extra: extra) }
        let limits = detail.limits
        var prompt = """
        You keep running notes of a conversation that is being transcribed live (a meeting, an interview, a call, a lecture, a podcast or a video). The reader follows the notes as they grow and reads only the newest lines to keep up, so what is already written stays exactly as it is. Write in \(language).

        Each time you get the last lines of the notes so far and the new part of the transcript. Reply with only the lines to add at the end. Never repeat, rephrase or rewrite what the notes already say.

        What to add
        - Substance, in the order it was said: topics, claims, facts, numbers, conclusions, and disagreements with their reasons. A bullet states a point; it doesn't narrate who said what.
        - Name a person only when who said it changes the meaning: who owns a decision or task, who committed to something, who disagrees with whom. Never write placeholder labels such as "Speaker 1"; leave the person out, or use their role ("the host", "the interviewer") when the transcript makes it clear.
        - Leave out greetings, small talk, banter, filler and repetition. If a joke carries a real point, state the point.
        - Usually \(limits.bullets) bullets per update; fewer when little was said. Each bullet is one sentence of at most \(limits.words) words (about \(limits.words * 2) characters in Chinese, Japanese or Korean) that makes sense on its own, without the earlier notes.
        - Start a bullet with a bold label when it is one of these, translated into the notes' language: "**Decision:**" for something agreed, "**Action:**" for a task (with its owner when named), "**Question:**" for a question left open.
        - If the new part corrects or reverses something noted earlier, add a bullet saying so. Don't restate the earlier line.
        - If the new part adds nothing worth noting, reply with exactly NONE.

        Topics
        - Notes are grouped under "## " headings of a few words each. While the conversation stays on the topic of the last heading, reply with bullets only. When it moves to a new topic, start your reply with a new "## " heading. Don't open a heading for every update.

        Context
        - Once it is clear what kind of conversation this is, what it is about and, if evident, who is taking part, begin your reply with one line "CONTEXT: …" saying so in one sentence. Send it again only if that understanding changes in a way that matters.
        - Infer only from clear evidence in the transcript and mark what you inferred with a word like "likely" or "appears". Never invent names, titles, employers or relationships.

        Rules
        - Reply with nothing but the optional CONTEXT line, an optional "## " heading and "- " bullets. No preamble.
        - Keep names, numbers, dates and technical terms exactly as said. The transcript comes from speech recognition: correct a misheard name or term only when the context makes the right reading clear.
        - Only what was said. No advice, no opinions, no outside facts.

        \(mode.summaryGuidance)
        """
        return prompt + own(extra)
    }

    private static func own(_ extra: String) -> String {
        let extra = extra.trimmingCharacters(in: .whitespacesAndNewlines)
        return extra.isEmpty ? "" : "\n\nThe reader's own instructions, which override the above where they conflict:\n\(extra)"
    }

    /// The other way to keep a summary: one structured overview, rewritten whole as the talk goes on.
    static func overviewSystem(language: String, detail: SummaryDetail, mode: AssistantMode, extra: String) -> String {
        let limits = detail.overviewLimits
        return """
        You maintain a structured summary of a talk that is being transcribed live. The reader glances at it to see where the talk stands as a whole. Write in \(language), headings included.

        Each time you get the current summary and the new part of the transcript. Reply with the complete updated summary: rewrite and merge, so it always covers the whole talk within the limits below.

        Format
        Line 1: "CONTEXT: …", one sentence on what this is, what it is about and, if evident, who is speaking. Infer only from clear evidence and mark what you inferred with a word like "likely"; never invent names or titles.
        Then Markdown with "## " headings and "- " bullets, using these sections, each only when it has content:
        ## Main points: at most \(limits.points) bullets, in the order of the argument
        ## Key terms: terms the speaker introduced, each with a few words of definition
        ## Takeaways: conclusions, recommendations, or what to do next
        At most \(limits.total) bullets in total. Each bullet is one sentence of at most \(limits.words) words (about \(limits.words * 2) characters in Chinese, Japanese or Korean).

        Rules
        - A bullet states a point; it doesn't narrate. Leave out greetings, banter, filler and repetition.
        - Keep names, numbers, dates and technical terms exactly as said. The transcript comes from speech recognition: correct a misheard name or term only when the context makes the right reading clear.
        - Only what was said. No advice, no opinions, no outside facts.
        - Reply with the summary only, no preamble.

        \(mode.summaryGuidance)
        """ + own(extra)
    }

    /// One update of the overview: the whole current summary and what was said since.
    public static func overview(current: LiveSummary?, newTranscript: String) -> String {
        var out = ""
        if let current, !current.text.isEmpty {
            out += "Current summary:\n<summary>\n"
            if let context = current.context { out += "CONTEXT: \(context)\n" }
            out += "\(current.text)\n</summary>\n\n"
        }
        out += "New transcript:\n<transcript>\n\(newTranscript)\n</transcript>\n\nReply with the complete updated summary."
        return out
    }

    /// An overview changes less often than notes: every few paragraphs, or a minute with something new.
    public static func shouldUpdateOverview(newWeight: Int, sinceUpdate: TimeInterval) -> Bool {
        newWeight >= 900 || (newWeight >= 150 && sinceUpdate >= 60)
    }

    /// One update: the end of the notes and what was said since.
    public static func append(current: LiveSummary?, newTranscript: String) -> String {
        var out = "Context so far: \(current?.context ?? "not established yet")\n\n"
        let notes = current?.text ?? ""
        if notes.isEmpty {
            out += "The notes are empty; this is their beginning.\n\n"
        } else {
            out += "Last lines of the notes, already written (do not repeat them):\n<notes>\n\(tail(notes))\n</notes>\n\n"
        }
        out += "New transcript:\n<transcript>\n\(newTranscript)\n</transcript>\n\nReply with the lines to add."
        return out
    }

    /// The refresh button: notes for everything said so far, written in one go.
    public static func rewrite(transcript: String) -> String {
        """
        There are no notes yet. Transcript of the conversation so far:
        <transcript>
        \(transcript)
        </transcript>

        Write the notes for all of it, in order, under topic headings, starting with the CONTEXT line. Cover every part of the conversation at the usual density; the per-update bullet count doesn't apply here.
        """
    }

    /// The same for an overview: one summary of everything said so far.
    public static func rewriteOverview(transcript: String) -> String {
        "Transcript of the talk so far:\n<transcript>\n\(transcript)\n</transcript>\n\nReply with the complete summary."
    }

    /// The notes' last heading and the lines after it, cut to the last `tailLimit` characters at a line break.
    static func tail(_ notes: String) -> String {
        let lines = notes.split(separator: "\n", omittingEmptySubsequences: true)
        var picked: [Substring] = []
        var total = 0
        for line in lines.reversed() {
            if total + line.count > tailLimit, !picked.isEmpty { break }
            picked.insert(line, at: 0)
            total += line.count
        }
        // Always show the current topic, so the model knows whether to continue it.
        if let heading = lines.last(where: { $0.hasPrefix("#") }), !picked.contains(heading) {
            picked.insert(heading, at: 0)
        }
        return picked.joined(separator: "\n")
    }

    /// The notes after a reply: its lines go at the end, and a CONTEXT line replaces the context.
    /// `replacing` starts the notes over, for a full rewrite.
    public static func merge(_ current: LiveSummary?, reply: String, coveredLineID: Int, replacing: Bool = false, now: Date = .now) -> LiveSummary {
        var context = current?.context
        var added: [String] = []
        for raw in clean(reply).split(separator: "\n", omittingEmptySubsequences: true) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.uppercased().hasPrefix("CONTEXT:") {
                let value = line.dropFirst(8).trimmingCharacters(in: .whitespaces)
                if !value.isEmpty { context = value }
            } else if !line.isEmpty, line.uppercased() != "NONE" {
                added.append(line)
            }
        }
        // Nothing new (a NONE, or only a CONTEXT line) keeps the notes as they are, whatever the mode.
        if added.isEmpty {
            return LiveSummary(text: current?.text ?? "", updatedAt: current?.updatedAt ?? now, coveredLineID: coveredLineID,
                               context: context, freshLine: current?.freshLine)
        }
        let old = replacing ? "" : (current?.text ?? "")
        let oldLines = old.split(separator: "\n", omittingEmptySubsequences: true)
        // A heading that repeats the current topic isn't a new topic.
        if let first = added.first, first.hasPrefix("#"), let last = oldLines.last(where: { $0.hasPrefix("#") }),
           heading(first) == heading(String(last)) {
            added.removeFirst()
        }
        guard !added.isEmpty else {
            return LiveSummary(text: old, updatedAt: current?.updatedAt ?? now, coveredLineID: coveredLineID,
                               context: context, freshLine: current?.freshLine)
        }
        var text = old
        for line in added {
            if text.isEmpty { text = line } else { text += (line.hasPrefix("#") ? "\n\n" : "\n") + line }
        }
        return LiveSummary(text: text, updatedAt: now, coveredLineID: coveredLineID, context: context,
                           freshLine: replacing ? nil : oldLines.count)
    }

    private static func heading(_ line: String) -> String {
        line.drop(while: { $0 == "#" }).trimmingCharacters(in: .whitespaces).lowercased()
    }

    /// Strips code fences some models add anyway.
    public static func clean(_ text: String) -> String {
        var t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.hasPrefix("```") {
            t = t.split(separator: "\n", omittingEmptySubsequences: false).dropFirst().joined(separator: "\n")
            if t.hasSuffix("```") { t = String(t.dropLast(3)) }
            t = t.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return t
    }

    /// How much was said, comparable across languages: a Chinese, Japanese or Korean character
    /// carries about as much as two Latin letters.
    public static func weight(_ text: String) -> Int {
        text.unicodeScalars.reduce(0) { $0 + ($1.value >= 0x2E80 ? 2 : 1) }
    }

    /// Whether enough was said since the last update to add to the notes. Notes should trail the
    /// talk by seconds: after a couple of sentences, sooner at a pause, and never long with anything waiting.
    public static func shouldUpdate(newWeight: Int, sinceUpdate: TimeInterval, sinceLastSpeech: TimeInterval) -> Bool {
        guard newWeight >= 40 else { return false }
        if newWeight >= 320 { return true }
        if newWeight >= 100 && sinceLastSpeech >= 3 { return true }
        return sinceUpdate >= 30
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
