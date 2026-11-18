import Foundation
import LukaCore

/// Keeps the live session's summary up to date with a language model of the user's choice,
/// on its own API key, one request at a time: running notes appended as talk comes in
/// (Meeting, Interview), or an overview rewritten as the talk goes on (Lecture).
@MainActor
@Observable
final class Summarizer {
    private let defaults = UserDefaults.standard

    var enabled: Bool { didSet { defaults.set(enabled, forKey: "summary.enabled") } }
    var provider: SummaryProvider { didSet { defaults.set(provider.rawValue, forKey: "summary.provider") } }
    /// Empty uses the provider's default endpoint.
    var baseURL: String { didSet { defaults.set(baseURL, forKey: "summary.baseURL") } }
    var model: String { didSet { defaults.set(model, forKey: "summary.model") } }
    /// Soniox language code; empty follows the translation language.
    var language: String { didSet { defaults.set(language, forKey: "summary.language") } }
    var apiKey: String { didSet { SecretStore.save(apiKey, slot: "summary") } }
    /// How much each update notes down.
    var detail: SummaryDetail { didSet { defaults.set(detail.rawValue, forKey: "summary.detail") } }
    /// The user's own additions to the built-in prompt.
    var instructions: String { didSet { defaults.set(instructions, forKey: "summary.instructions") } }
    /// The kind of conversation: sets how the summary is kept and how readily questions are answered.
    var mode: AssistantMode { didSet { defaults.set(mode.rawValue, forKey: "assistant.mode") } }
    var fontSize: Double { didSet { defaults.set(fontSize, forKey: "summary.fontSize") } }
    static let fontRange = 11.0...22.0
    /// The summary column in the transcript window.
    var panelShown: Bool { didSet { defaults.set(panelShown, forKey: "summary.panelShown") } }

    private(set) var working = false
    private(set) var lastError: String?
    private(set) var testResult: String?
    private(set) var testing = false

    @ObservationIgnored private var lastAttempt = Date.distantPast

    init() {
        let d = UserDefaults.standard
        enabled = d.bool(forKey: "summary.enabled")
        provider = SummaryProvider(rawValue: d.string(forKey: "summary.provider") ?? "") ?? .openAI
        baseURL = d.string(forKey: "summary.baseURL") ?? ""
        model = d.string(forKey: "summary.model") ?? ""
        language = d.string(forKey: "summary.language") ?? ""
        apiKey = SecretStore.read("summary") ?? ""
        detail = SummaryDetail(rawValue: d.string(forKey: "summary.detail") ?? "") ?? .concise
        instructions = d.string(forKey: "summary.instructions") ?? ""
        mode = AssistantMode(rawValue: d.string(forKey: "assistant.mode") ?? "") ?? .meeting
        // 14 pt reads comfortably at arm's length in a side column; 13 is the system's body size.
        fontSize = d.object(forKey: "summary.fontSize") as? Double ?? 14
        // Until the user decides, the column shows only when there is something to put in it.
        panelShown = d.object(forKey: "summary.panelShown") as? Bool
            ?? (d.bool(forKey: "summary.enabled") || d.bool(forKey: "answers.enabled"))
    }

    var endpoint: SummaryEndpoint { SummaryEndpoint(provider: provider, baseURL: baseURL, model: model.trimmingCharacters(in: .whitespaces)) }

    /// A local server such as Ollama needs no key.
    private var isLocal: Bool { ["localhost", "127.0.0.1", "0.0.0.0"].contains(endpoint.url?.host ?? "") }

    var isConfigured: Bool {
        !model.trimmingCharacters(in: .whitespaces).isEmpty
            && (!apiKey.trimmingCharacters(in: .whitespaces).isEmpty || isLocal)
            && endpoint.url != nil
    }

    // MARK: Updating

    /// Called every second while listening; adds to the notes once a little more has been said.
    func tick(_ t: Transcript, language: OutputLanguage, name: @escaping (SpeakerID) -> String) {
        guard enabled, isConfigured, !working else { return }
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
        run(t, rewrite: false, closedOnly: true, language: language, name: name)
    }

    /// When listening stops: note whatever is left, including a line still open.
    func catchUp(_ t: Transcript, language: OutputLanguage, name: @escaping (SpeakerID) -> String) {
        guard enabled, isConfigured, !working else { return }
        run(t, rewrite: false, closedOnly: false, language: language, name: name)
    }

    /// The refresh button: write the notes again from the whole transcript.
    func refresh(_ t: Transcript, language: OutputLanguage, name: @escaping (SpeakerID) -> String) {
        guard isConfigured, !working else { return }
        run(t, rewrite: true, closedOnly: false, language: language, name: name)
    }

    private func run(_ t: Transcript, rewrite: Bool, closedOnly: Bool, language: OutputLanguage, name: @escaping (SpeakerID) -> String) {
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
        let endpoint = self.endpoint
        let system = SummaryPrompt.system(language: language, detail: detail, mode: mode, extra: instructions)
        // An overview comes back whole each time, so it replaces what was there.
        let whole = rewrite || mode.rewritesSummary
        guard let request = endpoint.request(apiKey: apiKey, system: system, user: user, maxTokens: rewrite ? 6_000 : whole ? 2_500 : 1_000) else {
            lastError = tr("The summary model’s address isn’t valid.")
            return
        }
        let replacing = whole
        working = true
        lastAttempt = .now
        Task {
            defer { working = false }
            do {
                let reply = try await Self.send(request, endpoint: endpoint)
                // Lines noted meanwhile by another path are never unmarked.
                let covered = max(lastID ?? -1, t.summary?.coveredLineID ?? -1)
                t.summary = SummaryPrompt.merge(t.summary, reply: reply, coveredLineID: covered, replacing: replacing)
                lastError = nil
            } catch {
                lastError = error.localizedDescription
                AudioLog.write("summary failed: \(error.localizedDescription)")
            }
        }
    }

    /// Sends one request; turns a non-JSON error page into its HTTP status.
    static func send(_ request: URLRequest, endpoint: SummaryEndpoint) async throws -> String {
        let (data, response) = try await URLSession.shared.data(for: request)
        do {
            return try endpoint.parse(data)
        } catch let error as SummaryEndpoint.ResponseError {
            throw error
        } catch {
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            throw SummaryEndpoint.ResponseError.api(String(format: tr("The summary model replied with HTTP %d."), code))
        }
    }

    // MARK: Settings

    /// Settings' test button: one tiny request to check the address, key and model.
    func test() {
        guard isConfigured else {
            testResult = tr("Fill in the model and API key first.")
            return
        }
        guard let request = endpoint.request(apiKey: apiKey, system: "Reply with the single word OK.", user: "ping", maxTokens: 20) else {
            testResult = tr("The summary model’s address isn’t valid.")
            return
        }
        testing = true
        testResult = nil
        let endpoint = self.endpoint
        Task {
            defer { testing = false }
            do {
                let reply = try await Self.send(request, endpoint: endpoint)
                testResult = tr("Connected") + " · " + String(reply.prefix(40))
            } catch {
                testResult = error.localizedDescription
            }
        }
    }
}
