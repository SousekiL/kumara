import Foundation
import LukaCore
import Observation

/// Learns from each finished interview or meeting how to answer better next time, in small steps.
/// One request per session to the assistant model; every version is kept so any change can be undone.
@MainActor
@Observable
final class AnswerTuner {
    struct Version: Codable, Identifiable {
        var id = UUID()
        var date: Date
        var mode: AssistantMode
        /// The settings before this change, to go back to.
        var before: AnswerTuning
        var changes: [String]
    }

    var enabled: Bool { didSet { defaults.set(enabled, forKey: "answers.tuning.enabled") } }
    private(set) var tunings: [AssistantMode: AnswerTuning] = [:]
    private(set) var history: [Version] = []
    private(set) var reviewing = false
    /// What the last review did, shown in Settings.
    private(set) var lastReport: String?

    @ObservationIgnored private let defaults = UserDefaults.standard
    /// Sessions already learned from, with how long they were then, kept across launches.
    @ObservationIgnored private var reviewed: [String: Int] = [:]
    static let modes: [AssistantMode] = [.interview, .meeting]

    init() {
        enabled = defaults.object(forKey: "answers.tuning.enabled") as? Bool ?? true
        if let data = defaults.data(forKey: "answers.tuning"),
           let saved = try? JSONDecoder().decode([String: AnswerTuning].self, from: data) {
            for (key, value) in saved { if let mode = AssistantMode(rawValue: key) { tunings[mode] = value } }
        }
        reviewed = defaults.dictionary(forKey: "answers.tuning.reviewed") as? [String: Int] ?? [:]
        if let data = defaults.data(forKey: "answers.tuning.history"),
           let saved = try? JSONDecoder().decode([Version].self, from: data) {
            history = saved
        }
    }

    func tuning(for mode: AssistantMode) -> AnswerTuning {
        tunings[mode] ?? AnswerTuning()
    }

    /// Reviews a finished session in the background, once. Skips ones too short to learn from.
    func review(_ t: Transcript, mode: AssistantMode, service: AssistantService, onChange: @escaping (String) -> Void) {
        guard enabled, Self.modes.contains(mode), service.isConfigured, !reviewing else { return }
        // Once per session; again only when it has grown by a fair amount since.
        let key = t.id.uuidString
        if let seen = reviewed[key], t.lines.count < seen + 40 { return }
        guard let first = t.lines.first?.startedAt, let last = t.lines.last?.startedAt,
              last.timeIntervalSince(first) >= 5 * 60, t.theirTurns.count >= 8 else { return }
        let current = tuning(for: mode)
        let input = t.tuningReviewInput()
        guard let request = service.request(system: TuningPrompt.system(mode: mode),
                                            user: TuningPrompt.user(digest: input.digest, tuning: current),
                                            maxTokens: 4_000) else { return }
        // Judge only the turns the model was shown.
        let turns = t.theirTurns.filter { $0.id >= input.firstID }
        let session = t.id
        let size = t.lines.count
        reviewing = true
        Task {
            defer { reviewing = false }
            do {
                let reply = try await service.send(request)
                guard let review = TuningPrompt.parse(reply) else {
                    lastReport = tr("The last review couldn’t be read; nothing changed.")
                    return
                }
                // Marked only now: a failed review gets another chance.
                if reviewed.count > 300 { reviewed.removeAll() }
                reviewed[key] = size
                defaults.set(reviewed, forKey: "answers.tuning.reviewed")
                apply(review, turns: turns, mode: mode, session: session, onChange: onChange)
            } catch {
                AudioLog.write("tuning review failed: \(error.localizedDescription)")
            }
        }
    }

    private func apply(_ review: TuningReview, turns: [(id: Int, text: String)], mode: AssistantMode, session: UUID,
                       onChange: (String) -> Void) {
        let before = tuning(for: mode)
        var after = before
        let changes = after.learn(from: review, turns: turns, eagerness: mode.eagerness, session: session)
        let missed = before.score(turns, needed: review.needed, eagerness: mode.eagerness).missed
        tunings[mode] = after
        if !changes.isEmpty {
            history.insert(Version(date: .now, mode: mode, before: before, changes: changes), at: 0)
            if history.count > 40 { history.removeLast(history.count - 40) }
        }
        save()
        let summary = changes.isEmpty
            ? tr("No change") + " · " + String(format: tr("%d of %d turns that needed an answer were missed"), missed, review.needed.count)
            : changes.joined(separator: "\n")
        lastReport = "\(mode.title) · " + Date.now.formatted(date: .abbreviated, time: .shortened) + "\n" + summary
        if !changes.isEmpty {
            onChange(String(format: tr("Answers tuned from this session: %d change(s)"), changes.count))
        }
    }

    /// Goes back to the settings before a change (and drops the changes after it for that mode).
    func undo(_ version: Version) {
        tunings[version.mode] = version.before
        history.removeAll { $0.mode == version.mode && $0.date >= version.date }
        save()
    }

    func removeRule(_ id: Int, mode: AssistantMode) {
        var t = tuning(for: mode)
        guard let rule = t.rules.first(where: { $0.id == id }) else { return }
        history.insert(Version(date: .now, mode: mode, before: t, changes: ["− " + rule.text]), at: 0)
        t.rules.removeAll { $0.id == id }
        tunings[mode] = t
        save()
    }

    func removeCue(_ cue: String, mode: AssistantMode) {
        var t = tuning(for: mode)
        guard t.cues.contains(cue) else { return }
        history.insert(Version(date: .now, mode: mode, before: t, changes: ["− “\(cue)”"]), at: 0)
        t.cues.removeAll { $0 == cue }
        tunings[mode] = t
        save()
    }

    func reset(_ mode: AssistantMode) {
        let before = tuning(for: mode)
        guard before != AnswerTuning() else { return }
        history.insert(Version(date: .now, mode: mode, before: before, changes: [tr("Reset to the defaults")]), at: 0)
        tunings[mode] = AnswerTuning()
        save()
    }

    private func save() {
        let plain = Dictionary(uniqueKeysWithValues: tunings.map { ($0.key.rawValue, $0.value) })
        if let data = try? JSONEncoder().encode(plain) { defaults.set(data, forKey: "answers.tuning") }
        if let data = try? JSONEncoder().encode(history) { defaults.set(data, forKey: "answers.tuning.history") }
    }
}
