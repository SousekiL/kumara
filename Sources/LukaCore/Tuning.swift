import Foundation

/// What the answers learn from each session, per mode: a few rules added to the prompt, phrases that
/// mark a turn worth answering, and the trigger's two thresholds. Changes are small by construction:
/// at most two rules and three phrases per session, and a threshold moves one step, only when two
/// sessions in a row point the same way and replaying the session shows no loss.
public struct AnswerTuning: Codable, Sendable, Equatable {
    public struct Rule: Codable, Sendable, Equatable, Identifiable {
        public var id: Int
        public var text: String
        public var why: String
        /// Added by the last review; the next one keeps or drops it.
        public var trial: Bool
        public var added: Date
    }

    /// A threshold change waiting for a second session that agrees.
    public struct Nudge: Codable, Sendable, Equatable {
        public var setting: Setting
        public var delta: Int
        /// The session that asked for it.
        public var session: UUID?

        public init(setting: Setting, delta: Int, session: UUID? = nil) {
            self.setting = setting
            self.delta = delta
            self.session = session
        }
    }

    public enum Setting: String, Codable, Sendable {
        case eagerWeight, floor
    }

    public var rules: [Rule] = []
    public var cues: [String] = []
    /// A turn from the other side at least this heavy (a CJK character counts 2) is sent to the model
    /// even with no question in it. Only in modes that answer eagerly (interviews).
    public var eagerWeight = 60
    /// Turns from the other side lighter than this are never answered: fragments like "会不会？".
    public var floor = 0
    public var nextID = 1
    public var pendingNudge: Nudge?

    public static let maxRules = 12, maxCues = 20, maxRuleLength = 160
    public static let eagerRange = 20...100, floorRange = 0...16
    public static let eagerStep = 10, floorStep = 4
    /// How many more needless calls a session may cost for each question it no longer misses.
    public static let noiseAllowance = 3

    public init() {}

    public var lessons: [String] { rules.map(\.text) }

    // MARK: Triggering

    /// Whether a finished line goes to the model as a possible question.
    public func accepts(_ text: String, fromThem: Bool, eagerness: AnswerEagerness) -> Bool {
        if eagerness == .off { return false }
        let weight = SummaryPrompt.weight(text)
        if fromThem, weight < floor { return false }
        if fromThem, matchesCue(text) { return true }
        if eagerness == .eager {
            if Questions.isQuestion(text) || text.contains("?") || text.contains("？") { return true }
            return fromThem && weight >= eagerWeight
        }
        return eagerness.accepts(text, fromThem: fromThem)
    }

    func matchesCue(_ text: String) -> Bool {
        let t = text.lowercased()
        return cues.contains { !$0.isEmpty && t.contains($0.lowercased()) }
    }

    /// The other side's turns these settings would send to the model.
    public func triggered(_ turns: [(id: Int, text: String)], eagerness: AnswerEagerness) -> Set<Int> {
        Set(turns.filter { accepts($0.text, fromThem: true, eagerness: eagerness) }.map(\.id))
    }

    // MARK: Learning

    /// Turns that needed a response and weren't sent (missed), and turns sent that didn't (noise).
    public func score(_ turns: [(id: Int, text: String)], needed: Set<Int>, eagerness: AnswerEagerness) -> (missed: Int, noise: Int) {
        let sent = triggered(turns, eagerness: eagerness)
        return (needed.subtracting(sent).count, sent.subtracting(needed).count)
    }

    /// The one-step threshold change this session supports, if any: fewer misses at a bounded cost
    /// in noise, or less noise with no more misses.
    public func bestNudge(_ turns: [(id: Int, text: String)], needed: Set<Int>, eagerness: AnswerEagerness) -> Nudge? {
        let base = score(turns, needed: needed, eagerness: eagerness)
        var best: (nudge: Nudge, gain: (Int, Int))?
        var options: [Nudge] = [.init(setting: .floor, delta: Self.floorStep), .init(setting: .floor, delta: -Self.floorStep)]
        if eagerness == .eager {
            options += [.init(setting: .eagerWeight, delta: -Self.eagerStep), .init(setting: .eagerWeight, delta: Self.eagerStep)]
        }
        for nudge in options {
            guard let moved = applying(nudge) else { continue }
            let s = moved.score(turns, needed: needed, eagerness: eagerness)
            let fewerMisses = s.missed < base.missed && s.noise - base.noise <= Self.noiseAllowance * (base.missed - s.missed)
            let lessNoise = s.noise < base.noise && s.missed <= base.missed
            guard fewerMisses || lessNoise else { continue }
            let gain = (base.missed - s.missed, base.noise - s.noise)
            if best == nil || gain > best!.gain { best = (nudge, gain) }
        }
        return best?.nudge
    }

    /// The settings moved by one step, or nil past the allowed range.
    public func applying(_ nudge: Nudge) -> AnswerTuning? {
        var t = self
        switch nudge.setting {
        case .eagerWeight:
            let v = eagerWeight + nudge.delta
            guard Self.eagerRange.contains(v) else { return nil }
            t.eagerWeight = v
        case .floor:
            let v = floor + nudge.delta
            guard Self.floorRange.contains(v) else { return nil }
            t.floor = v
        }
        return t
    }

    /// Applies one session's review, within the limits. Returns what changed, for the reader.
    public mutating func learn(from review: TuningReview, turns: [(id: Int, text: String)],
                               eagerness: AnswerEagerness, session: UUID? = nil, now: Date = .now) -> [String] {
        var changes: [String] = []
        let ids = Set(turns.map(\.id))
        let needed = review.needed.intersection(ids)

        // Last session's trial rules: dropped when this one says they hurt, otherwise kept for good.
        for i in rules.indices.reversed() where rules[i].trial {
            if review.drop.contains(rules[i].id) {
                changes.append("− " + rules[i].text)
                rules.remove(at: i)
            } else {
                rules[i].trial = false
            }
        }

        // At most two rule changes, each short and backed by something said.
        for op in review.rules.prefix(2) {
            let text = op.text.trimmingCharacters(in: .whitespacesAndNewlines)
            switch op.op {
            case "remove":
                guard let id = op.id, let i = rules.firstIndex(where: { $0.id == id }) else { continue }
                changes.append("− " + rules[i].text)
                rules.remove(at: i)
            case "replace":
                guard let id = op.id, let i = rules.firstIndex(where: { $0.id == id }),
                      Self.valid(text), !op.evidence.isEmpty else { continue }
                changes.append("~ " + text)
                rules[i] = Rule(id: nextID, text: text, why: op.why, trial: true, added: now)
                nextID += 1
            default:
                guard Self.valid(text), !op.evidence.isEmpty, rules.count < Self.maxRules,
                      !rules.contains(where: { $0.text == text }) else { continue }
                changes.append("+ " + text)
                rules.append(Rule(id: nextID, text: text, why: op.why, trial: true, added: now))
                nextID += 1
            }
        }

        // Without turns that needed an answer there is no measure: every trigger would count as noise.
        guard !needed.isEmpty else {
            pendingNudge = nil
            return changes
        }

        // A phrase in place that only made noise this session goes.
        for cue in cues {
            var without = self
            without.cues.removeAll { $0 == cue }
            let lost = triggered(turns, eagerness: eagerness).subtracting(without.triggered(turns, eagerness: eagerness))
            if lost.count >= 2, lost.intersection(needed).isEmpty {
                cues.removeAll { $0 == cue }
                changes.append("− “\(cue)”")
            }
        }

        // Phrases: each must catch a needed turn that was missed, at the cost of at most one other.
        for cue in review.cues.prefix(3) {
            let phrase = cue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard (2...16).contains(phrase.count), !cues.contains(where: { $0.lowercased() == phrase.lowercased() }) else { continue }
            var trial = self
            trial.cues.append(phrase)
            let before = triggered(turns, eagerness: eagerness)
            let after = trial.triggered(turns, eagerness: eagerness)
            let added = after.subtracting(before)
            guard !added.intersection(needed).isEmpty, added.subtracting(needed).count <= 1 else { continue }
            cues.append(phrase)
            if cues.count > Self.maxCues { cues.removeFirst() }
            changes.append("+ “\(phrase)”")
        }

        // Thresholds: one step, only when two sessions in a row agree.
        if var nudge = bestNudge(turns, needed: needed, eagerness: eagerness) {
            nudge.session = session
            // The second vote has to come from a different session.
            if let pending = pendingNudge, pending.setting == nudge.setting, pending.delta == nudge.delta,
               pending.session != session || session == nil, let moved = applying(nudge) {
                let name = nudge.setting == .floor ? "floor" : "eagerWeight"
                let old = nudge.setting == .floor ? floor : eagerWeight
                let new = nudge.setting == .floor ? moved.floor : moved.eagerWeight
                floor = moved.floor
                eagerWeight = moved.eagerWeight
                pendingNudge = nil
                changes.append("\(name) \(old) → \(new)")
            } else {
                pendingNudge = nudge
            }
        } else {
            pendingNudge = nil
        }
        return changes
    }

    static func valid(_ rule: String) -> Bool {
        !rule.isEmpty && rule.count <= maxRuleLength
    }
}

/// What the model said about one session.
public struct TuningReview: Sendable, Equatable {
    public struct RuleOp: Sendable, Equatable {
        public var op: String
        public var id: Int?
        public var text: String
        public var why: String
        public var evidence: [Int]
    }

    public var needed: Set<Int> = []
    public var rules: [RuleOp] = []
    public var cues: [String] = []
    public var keep: Set<Int> = []
    public var drop: Set<Int> = []

    public init(needed: Set<Int> = [], rules: [RuleOp] = [], cues: [String] = [], keep: Set<Int> = [], drop: Set<Int> = []) {
        self.needed = needed
        self.rules = rules
        self.cues = cues
        self.keep = keep
        self.drop = drop
    }
}

/// Asks the model to review a finished session: which of the other side's turns needed a response,
/// and the few rule changes that would have helped most.
public enum TuningPrompt {
    public static func system(mode: AssistantMode) -> String {
        """
        You review a finished \(mode == .interview ? "job interview" : "meeting") in which an assistant showed the reader short live answers to what the other side asked. Your review tunes the assistant for next time, in small steps. Stability matters more than coverage: suggest a change only for a clear problem in this session that a short rule would have fixed, and prefer no change at all.

        The session is given as numbered turns. "Them" is the other side, "Me" the reader. Under a turn, "→ answered" shows a live answer and its first line, "→ feedback" a tip on the reader's own answer.

        Reply with one JSON object and nothing else:
        {"needed": [ids], "rules": [ops], "cues": [phrases], "keep": [ids], "drop": [ids]}

        - needed: the ids of every "Them" turn that called for a response from the reader: questions, follow-ups, requests to explain or go deeper, and hints during a task ("there may be a problem with the join", "look at this part"). Not small talk, acknowledgements ("OK", "了解") or turns the other side answers themselves. This list is used to measure misses, so be complete and exact.
        - rules: at most 2, often none. Each op is {"op": "add", "text": "...", "why": "...", "evidence": [ids]}, {"op": "replace", "id": n, "text": "...", "why": "...", "evidence": [ids]} or {"op": "remove", "id": n, "why": "..."}. A rule is one imperative sentence under 30 words, in English, about what to answer or what to put first (for example "During a coding task, treat the interviewer's hints as questions and name the likely bug first"). Never about output format, length or language. Never repeat or contradict a rule already in place except to replace it. evidence: the turn ids that show the problem.
        - cues: at most 3 short phrases, copied as said (2 to 16 characters), that marked a needed "Them" turn the assistant did not answer, and would rarely appear in turns that need nothing.
        - keep / drop: for each rule marked (trial), keep it if it did no harm in this session, drop it only if answers got worse because of it.
        """
    }

    public static func user(digest: String, tuning: AnswerTuning) -> String {
        var parts: [String] = []
        if tuning.rules.isEmpty {
            parts.append("Rules in place: none.")
        } else {
            parts.append("Rules in place:\n" + tuning.rules.map { "\($0.id). \($0.text)\($0.trial ? " (trial)" : "")" }.joined(separator: "\n"))
        }
        if !tuning.cues.isEmpty { parts.append("Cue phrases in place: " + tuning.cues.joined(separator: " · ")) }
        parts.append("The session:\n<session>\n\(digest)\n</session>")
        return parts.joined(separator: "\n\n")
    }

    /// The JSON object in the reply, read leniently: a missing field is an empty one.
    public static func parse(_ reply: String) -> TuningReview? {
        let text = SummaryPrompt.clean(reply)
        guard let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}"), start < end,
              let data = String(text[start...end]).data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              // Misses and noise are measured against this list: without it there is nothing to learn from.
              object["needed"] is [Any] else { return nil }
        func ints(_ key: String) -> Set<Int> { Set((object[key] as? [Any] ?? []).compactMap { ($0 as? Int) ?? Int("\($0)") }) }
        var review = TuningReview(needed: ints("needed"), keep: ints("keep"), drop: ints("drop"))
        review.cues = (object["cues"] as? [Any] ?? []).compactMap { $0 as? String }
        for case let op as [String: Any] in object["rules"] as? [Any] ?? [] {
            review.rules.append(.init(op: (op["op"] as? String ?? "add").lowercased(),
                                      id: (op["id"] as? Int) ?? (op["id"] as? String).flatMap(Int.init),
                                      text: op["text"] as? String ?? "",
                                      why: op["why"] as? String ?? "",
                                      evidence: (op["evidence"] as? [Any] ?? []).compactMap { ($0 as? Int) ?? Int("\($0)") }))
        }
        return review
    }
}

extension Transcript {
    /// The other side's finished turns, by id: what the trigger is judged on.
    public var theirTurns: [(id: Int, text: String)] {
        lines.filter { !$0.isOpen && Channel($0.speaker) == .them && !$0.original.isEmpty }.map { ($0.id, $0.original) }
    }

    /// A compact numbered account of the session for review: turns, and under them what the
    /// assistant showed. Long turns are cut, the reader's backchannel ("嗯") left out.
    public func tuningDigest(limit: Int = 45_000) -> String {
        tuningReviewInput(limit: limit).digest
    }

    /// The digest and the first line id in it: turns before that were not shown to the model,
    /// so they must not be judged.
    public func tuningReviewInput(limit: Int = 45_000) -> (digest: String, firstID: Int) {
        guard let start = lines.first?.startedAt else { return ("", 0) }
        func clock(_ d: Date) -> String {
            let s = max(0, Int(d.timeIntervalSince(start)))
            return String(format: "%02d:%02d", s / 60, s % 60)
        }
        let byLine = Dictionary(grouping: answers, by: \.id)
        var out: [String] = []
        for line in lines {
            let text = line.original.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            let them = Channel(line.speaker) == .them
            if !them, SummaryPrompt.weight(text) < 8 { continue }
            let cut = them ? 400 : 160
            let shown = text.count > cut ? String(text.prefix(cut)) + "…" : text
            out.append("[\(line.id)] \(clock(line.startedAt)) \(them ? "Them" : "Me"): \(shown)")
            for a in byLine[line.id] ?? [] where !a.answer.isEmpty {
                let first = a.answer.split(separator: "\n").first.map(String.init) ?? ""
                let after = Int(a.createdAt.timeIntervalSince(line.startedAt))
                if a.kind == "polish" {
                    out.append("    → feedback: \(first.prefix(120))")
                } else if a.kind != "asked" {
                    out.append("    → answered \(after)s after the turn began: \(first.prefix(120))")
                }
            }
        }
        // Drop whole entries from the front until it fits.
        var total = out.reduce(0) { $0 + $1.count + 1 }
        var first = 0
        while total > limit, first < out.count - 1 {
            total -= out[first].count + 1
            first += 1
        }
        while first < out.count, !out[first].hasPrefix("[") { first += 1 }
        let kept = Array(out[first...])
        let firstID = kept.first.flatMap { entry -> Int? in
            guard let close = entry.firstIndex(of: "]") else { return nil }
            return Int(entry[entry.index(after: entry.startIndex)..<close])
        } ?? 0
        return (kept.joined(separator: "\n"), firstID)
    }
}
