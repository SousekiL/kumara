import Foundation
import LukaCore

/// Keeps the live session's summary up to date with the assistant's model, one request at a time: running notes appended as talk comes in
/// (Meeting, Interview), or an overview rewritten as the talk goes on (Lecture).
@MainActor
@Observable
final class Summarizer {
    private let defaults = UserDefaults.standard

    let service: AssistantService

    var enabled: Bool { didSet { defaults.set(enabled, forKey: "summary.enabled") } }
    /// How much each update notes down.
    var detail: SummaryDetail { didSet { defaults.set(detail.rawValue, forKey: "summary.detail") } }
    /// The summary column in the transcript window.
    var panelShown: Bool { didSet { defaults.set(panelShown, forKey: "summary.panelShown") } }

    private(set) var working = false
    private(set) var lastError: String?
    /// The latest "catch me up", until dismissed.
    private(set) var recap: (session: UUID, text: String, at: Date)?
    private(set) var recapping = false

    @ObservationIgnored private var lastAttempt = Date.distantPast

    init(service: AssistantService) {
        self.service = service
        let d = UserDefaults.standard
        enabled = d.bool(forKey: "summary.enabled")
        detail = SummaryDetail(rawValue: d.string(forKey: "summary.detail") ?? "") ?? .concise
        // Until the user decides, the column shows only when there is something to put in it.
        panelShown = d.object(forKey: "summary.panelShown") as? Bool
            ?? (d.bool(forKey: "summary.enabled") || d.bool(forKey: "answers.enabled"))
    }

    // MARK: Updating

    /// Called every second while listening; adds to the notes once a little more has been said.
    func tick(_ t: Transcript, mode: AssistantMode, language: OutputLanguage, name: @escaping (SpeakerID) -> String) {
        guard enabled, service.isConfigured, !working else { return }
        let now = Date.now
        // One request at a time, a few seconds apart; back off after a failure.
        guard now.timeIntervalSince(lastAttempt) >= (lastError == nil ? 4 : 30) else { return }
        let new = t.summaryText(after: t.summary?.coveredLineID, closedOnly: true, limit: SummaryPrompt.incrementalLimit, name: name)
        // A finished line with nothing more coming in means the speaker has paused.
        let speaking = t.lines.last?.isOpen == true || t.provisional != nil
        let weight = SummaryPrompt.weight(new.text)
        let since = now.timeIntervalSince(lastAttempt)
        guard mode.rewritesSummary
            ? SummaryPrompt.shouldUpdateOverview(newWeight: weight, sinceUpdate: since)
            : SummaryPrompt.shouldUpdate(newWeight: weight, sinceUpdate: since, sinceLastSpeech: speaking ? 0 : 10) else { return }
        run(t, mode: mode, rewrite: false, closedOnly: true, language: language, name: name)
    }

    /// When listening stops: note whatever is left, including a line still open.
    func catchUp(_ t: Transcript, mode: AssistantMode, language: OutputLanguage, name: @escaping (SpeakerID) -> String) {
        guard enabled, service.isConfigured, !working else { return }
        run(t, mode: mode, rewrite: false, closedOnly: false, language: language, name: name)
    }

    /// The refresh button: write the notes again from the whole transcript.
    func refresh(_ t: Transcript, mode: AssistantMode, language: OutputLanguage, name: @escaping (SpeakerID) -> String) {
        guard service.isConfigured, !working else { return }
        run(t, mode: mode, rewrite: true, closedOnly: false, language: language, name: name)
    }

    private func run(_ t: Transcript, mode: AssistantMode, rewrite: Bool, closedOnly: Bool, language: OutputLanguage, name: @escaping (SpeakerID) -> String) {
        var rewrite = rewrite
        var user = ""
        var lastID: Int?
        if rewrite {
            let all = t.summaryText(after: nil, closedOnly: closedOnly, limit: SummaryPrompt.rewriteLimit, name: name)
            // A transcript too long to reread whole keeps its notes; only what's new gets added.
            if all.truncated {
                rewrite = false
            } else {
                guard !all.text.isEmpty else { return }
                user = mode.rewritesSummary ? SummaryPrompt.rewriteOverview(transcript: all.text) : SummaryPrompt.rewrite(transcript: all.text)
                lastID = all.lastLineID
            }
        }
        if !rewrite {
            let new = t.summaryText(after: t.summary?.coveredLineID, closedOnly: closedOnly, limit: SummaryPrompt.incrementalLimit, name: name)
            guard !new.text.isEmpty else { return }
            user = mode.rewritesSummary
                ? SummaryPrompt.overview(current: t.summary, newTranscript: new.text)
                : SummaryPrompt.append(current: t.summary, newTranscript: new.text)
            lastID = new.lastLineID
        }
        let system = SummaryPrompt.system(language: language, detail: detail, mode: mode, extra: service.context)
        // An overview comes back whole each time, so it replaces what was there.
        let whole = rewrite || mode.rewritesSummary
        guard let request = service.request(system: system, user: user, maxTokens: rewrite ? 10_000 : whole ? 6_000 : 4_000) else {
            lastError = tr("The summary model’s address isn’t valid.")
            return
        }
        let replacing = whole
        working = true
        lastAttempt = .now
        Task {
            defer { working = false }
            do {
                let reply = try await service.send(request)
                // Lines noted meanwhile by another path are never unmarked.
                let covered = max(lastID ?? -1, t.summary?.coveredLineID ?? -1)
                t.summary = SummaryPrompt.merge(t.summary, reply: reply, coveredLineID: covered, replacing: replacing)
                lastError = nil
            } catch SummaryEndpoint.ResponseError.empty {
                lastError = nil
            } catch {
                lastError = error.localizedDescription
                AudioLog.write("summary failed: \(error.localizedDescription)")
            }
        }
    }

    // MARK: Catch me up

    /// What was just said, in a few bullets: one request, made only when asked.
    func catchMeUp(_ t: Transcript, language: OutputLanguage, name: @escaping (SpeakerID) -> String) {
        guard service.isConfigured, !recapping, !t.lines.isEmpty else { return }
        // About the last few minutes of talk.
        let recent = t.summaryText(after: nil, closedOnly: false, limit: 3_000, name: name).text
        guard let request = service.request(system: CatchUpPrompt.system(language: language, extra: service.context),
                                            user: CatchUpPrompt.user(conversation: recent), maxTokens: 3_000) else { return }
        recapping = true
        Task {
            defer { recapping = false }
            do {
                let text = try await service.send(request)
                recap = (session: t.id, text: text, at: Date.now)
                lastError = nil
            } catch {
                lastError = error.localizedDescription
            }
        }
    }

    func dismissRecap() { recap = nil }
}
