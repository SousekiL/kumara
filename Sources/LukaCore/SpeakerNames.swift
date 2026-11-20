import Foundation

/// One speaker's proposed identity, from a model that read the whole session.
public struct SpeakerProposal: Identifiable, Sendable, Equatable {
    public enum Confidence: String, Sendable, Comparable {
        case low, medium, high
        public static func < (a: Self, b: Self) -> Bool { a.rank < b.rank }
        var rank: Int { self == .low ? 0 : self == .medium ? 1 : 2 }
    }

    public var id: SpeakerID
    public var tag: String
    /// The person's name, or a placeholder like "?A" when two speakers are one unnamed person.
    public var person: String
    public var confidence: Confidence
    public var why: String

    /// A stand-in for "same person, name unknown": it merges but names nobody.
    public var isPlaceholder: Bool { person.hasPrefix("?") }

    public init(id: SpeakerID, tag: String, person: String, confidence: Confidence, why: String) {
        self.id = id
        self.tag = tag
        self.person = person
        self.confidence = confidence
        self.why = why
    }
}

/// What the reader knows about who was there.
public struct SpeakerHints: Sendable, Equatable {
    /// How many people took part, the reader included; 0 when not given.
    public var count = 0
    public var names: [String] = []
    /// Free text: roles, who asks the questions, accents, anything that tells people apart.
    public var notes = ""
    /// The reader's own names.
    public var reader: [String] = []

    public init(count: Int = 0, names: [String] = [], notes: String = "", reader: [String] = []) {
        self.count = count
        self.names = names
        self.notes = notes
        self.reader = reader
    }

    /// Names typed with commas, Chinese commas, semicolons or line breaks between them.
    public static func parseNames(_ text: String) -> [String] {
        text.components(separatedBy: CharacterSet(charactersIn: ",，;；、\n"))
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }
}

public enum SpeakerPrompt {
    public static let system = """
    You work out who is who in a transcript of a meeting, interview or call. Speech recognition split the audio into speaker tags (S1, S2, …). The split is imperfect: one person is often given several tags, above all when the audio stream restarted. Decide, for every tag, which person it is.

    Evidence, strongest first:
    - Names said aloud: someone addressed by name answers next ("Irene, what do you think?" then a reply), self-introductions ("我是 Irene", "this is Roy"), sign-offs. Being addressed means the NEXT speaker is likely that person, not the one saying the name.
    - Roles and content: who asks the interview questions, who presents, who owns which topic; the reader's notes about the participants.
    - Continuity: a tag that picks up mid-thought where another tag stopped, in a later stream, is likely the same person.
    - Streams: tags within the same stream were heard as different voices at the same time, so treat them as different people unless the evidence is strong (one of them has only a few short lines, typical of a recognition slip). Tags in different streams can be the same person.
    - Channel: "mic" tags are the reader's own microphone, "other" tags the far side of the call. A mic tag and an other tag are never the same person.

    Rules:
    - When the reader gives the number of participants, the number of distinct people in your answer must not exceed it.
    - When the reader gives names, use those spellings, and assign each name to at most the tags of one person.
    - Speech recognition misspells names; use the reader's spelling, or the most plausible one.
    - When you can tell two tags are the same person but not who, give both the same placeholder: "?A", "?B", ….
    - When you cannot tell who a tag is and it matches no other tag, give it its own placeholder.
    - Be honest about confidence: "high" only with a name said aloud that fits, or unmistakable role evidence; "medium" for a good inference; "low" for a guess.

    Reply with one JSON object and nothing else:
    {"speakers": [{"tag": "S1", "person": "Irene", "confidence": "high", "why": "at most 15 words, quoting the evidence"}], "note": "one sentence on anything the reader should check, or empty"}
    Include every tag exactly once.
    """

    public static func user(sheet: String, hints: SpeakerHints) -> String {
        var parts: [String] = []
        if hints.count > 0 { parts.append("Number of participants, the reader included: \(hints.count)") }
        if !hints.names.isEmpty { parts.append("Participants' names: " + hints.names.joined(separator: ", ")) }
        if !hints.reader.isEmpty { parts.append("The reader (the mic channel, when there is one) is: " + hints.reader.joined(separator: " / ")) }
        let notes = hints.notes.trimmingCharacters(in: .whitespacesAndNewlines)
        if !notes.isEmpty { parts.append("The reader's notes about the participants:\n\(notes)") }
        parts.append(sheet)
        return parts.joined(separator: "\n\n")
    }

    /// Reads the reply against the tags that were sent; unknown tags are dropped.
    public static func parse(_ reply: String, tags: [String: SpeakerID]) -> (proposals: [SpeakerProposal], note: String)? {
        let text = SummaryPrompt.clean(reply)
        guard let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}"), start < end,
              let data = String(text[start...end]).data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let list = object["speakers"] as? [Any] else { return nil }
        var seen: Set<String> = []
        var out: [SpeakerProposal] = []
        for case let item as [String: Any] in list {
            guard let tag = (item["tag"] as? String)?.uppercased(), let id = tags[tag], seen.insert(tag).inserted else { continue }
            let person = (item["person"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !person.isEmpty else { continue }
            let confidence = SpeakerProposal.Confidence(rawValue: (item["confidence"] as? String ?? "").lowercased()) ?? .low
            out.append(.init(id: id, tag: tag, person: person, confidence: confidence, why: item["why"] as? String ?? ""))
        }
        return out.isEmpty ? nil : (out, object["note"] as? String ?? "")
    }
}

extension Transcript {
    /// The session with every line under its speaker's tag, and what is known of each tag,
    /// for working out who is who. Long sessions keep their beginning and their end.
    public func speakerSheet(limit: Int = 60_000) -> (text: String, tags: [String: SpeakerID]) {
        let visible = visibleSpeakers
        guard let start = lines.first?.startedAt else { return ("", [:]) }
        var tagOf: [SpeakerID: String] = [:]
        var tags: [String: SpeakerID] = [:]
        for (i, s) in visible.enumerated() {
            tagOf[s.id] = "S\(i + 1)"
            tags["S\(i + 1)"] = s.id
        }
        func clock(_ d: Date) -> String {
            let s = max(0, Int(d.timeIntervalSince(start)))
            return String(format: "%02d:%02d", s / 60, s % 60)
        }
        // Streams numbered in order of appearance; the fixed Me / Them channels have none.
        var streams: [Int: Int] = [:]
        for s in visible where s.id.epoch != -1 && streams[s.id.epoch] == nil { streams[s.id.epoch] = streams.count + 1 }

        var header: [String] = ["Speaker tags:"]
        for s in visible {
            let own = lines.filter { $0.speaker.map(canonical) == s.id && !$0.original.isEmpty }
            guard let first = own.first, let last = own.last else { continue }
            let channel = Channel(s.id).map { $0 == .me ? "mic" : "other" } ?? "single stream"
            var row = "\(tagOf[s.id] ?? "?"): \(own.count) lines, \(clock(first.startedAt))–\(clock(last.startedAt)), channel \(channel)"
            if let n = streams[s.id.epoch] { row += ", stream \(n)" }
            if !s.name.isEmpty { row += ", currently named \"\(s.name)\"" }
            header.append(row)
        }

        var body: [String] = []
        for line in lines {
            let text = line.original.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty, let id = line.speaker.map(canonical), let tag = tagOf[id] else { continue }
            body.append("[\(tag) \(clock(line.startedAt))] \(text.count > 320 ? String(text.prefix(320)) + "…" : text)")
        }
        var total = body.reduce(0) { $0 + $1.count + 1 }
        if total > limit {
            // Introductions come first and sign-offs last: keep both ends.
            var head: [String] = [], tail: [String] = []
            var used = 0
            var i = 0, j = body.count - 1
            while i <= j {
                if used + body[i].count > limit { break }
                head.append(body[i]); used += body[i].count + 1; i += 1
                guard i <= j, used + body[j].count <= limit else { break }
                tail.insert(body[j], at: 0); used += body[j].count + 1; j -= 1
            }
            body = head + ["… (\(j - i + 1) lines left out) …"] + tail
            total = used
        }
        return (header.joined(separator: "\n") + "\n\nTranscript:\n" + body.joined(separator: "\n"), tags)
    }
}
