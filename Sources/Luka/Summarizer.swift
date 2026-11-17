import Foundation
import LukaCore

/// Keeps the live session's summary up to date with a language model of the user's choice,
/// on its own API key. One request at a time: small incremental updates as talk comes in,
/// and every few updates a rewrite from the transcript, so earlier points get revised.
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
    /// The summary column in the transcript window.
    var panelShown: Bool { didSet { defaults.set(panelShown, forKey: "summary.panelShown") } }

    private(set) var working = false
    private(set) var lastError: String?
    private(set) var testResult: String?
    private(set) var testing = false

    @ObservationIgnored private var updatesSinceRewrite = 0
    @ObservationIgnored private var lastAttempt = Date.distantPast
    @ObservationIgnored private var sessionID: UUID?

    init() {
        let d = UserDefaults.standard
        enabled = d.bool(forKey: "summary.enabled")
        provider = SummaryProvider(rawValue: d.string(forKey: "summary.provider") ?? "") ?? .openAI
        baseURL = d.string(forKey: "summary.baseURL") ?? ""
        model = d.string(forKey: "summary.model") ?? ""
        language = d.string(forKey: "summary.language") ?? ""
        apiKey = SecretStore.read("summary") ?? ""
        panelShown = d.object(forKey: "summary.panelShown") as? Bool ?? true
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

    /// Called every few seconds while listening; updates the summary when enough was said.
    func tick(_ t: Transcript, languageName: String, name: @escaping (SpeakerID) -> String) {
        guard enabled, isConfigured, !working else { return }
        if sessionID != t.id {
            sessionID = t.id
            updatesSinceRewrite = 0
        }
        let now = Date.now
        // Back off after a failure instead of retrying every tick.
        guard now.timeIntervalSince(lastAttempt) >= (lastError == nil ? 8 : 45) else { return }
        let new = t.summaryText(after: t.summary?.coveredLineID, closedOnly: true, limit: SummaryPrompt.incrementalLimit, name: name)
        let since = now.timeIntervalSince(t.summary?.updatedAt ?? t.createdAt)
        guard SummaryPrompt.shouldUpdate(newCharacters: new.text.count, sinceUpdate: since,
                                         sinceLastSpeech: now.timeIntervalSince(t.updatedAt)) else { return }
        let rewrite = t.summary == nil || updatesSinceRewrite >= SummaryPrompt.rewriteEvery || new.truncated
        run(t, rewrite: rewrite, closedOnly: true, languageName: languageName, name: name)
    }

    /// When listening stops: fold in whatever is left, including a line still open.
    func catchUp(_ t: Transcript, languageName: String, name: @escaping (SpeakerID) -> String) {
        guard enabled, isConfigured, !working else { return }
        let new = t.summaryText(after: t.summary?.coveredLineID, closedOnly: false, limit: SummaryPrompt.incrementalLimit, name: name)
        guard !new.text.isEmpty else { return }
        run(t, rewrite: t.summary == nil || new.truncated, closedOnly: false, languageName: languageName, name: name)
    }

    /// The refresh button: rewrite from the whole transcript now.
    func refresh(_ t: Transcript, languageName: String, name: @escaping (SpeakerID) -> String) {
        guard isConfigured, !working else { return }
        sessionID = t.id
        run(t, rewrite: true, closedOnly: false, languageName: languageName, name: name)
    }

    private func run(_ t: Transcript, rewrite: Bool, closedOnly: Bool, languageName: String, name: @escaping (SpeakerID) -> String) {
        let current = t.summary?.text
        let user: String
        let lastID: Int?
        if rewrite {
            let all = t.summaryText(after: nil, closedOnly: closedOnly, limit: SummaryPrompt.rewriteLimit, name: name)
            guard !all.text.isEmpty else { return }
            user = SummaryPrompt.rewrite(current: current, transcript: all.text, truncated: all.truncated)
            lastID = all.lastLineID
        } else {
            let new = t.summaryText(after: t.summary?.coveredLineID, closedOnly: closedOnly, limit: SummaryPrompt.incrementalLimit, name: name)
            guard !new.text.isEmpty else { return }
            user = SummaryPrompt.incremental(current: current ?? "", newTranscript: new.text)
            lastID = new.lastLineID
        }
        let endpoint = self.endpoint
        guard let request = endpoint.request(apiKey: apiKey, system: SummaryPrompt.system(language: languageName), user: user) else {
            lastError = tr("The summary model’s address isn’t valid.")
            return
        }
        working = true
        lastAttempt = .now
        Task {
            defer { working = false }
            do {
                let text = try await Self.send(request, endpoint: endpoint)
                let covered = max(lastID ?? -1, t.summary?.coveredLineID ?? -1)
                t.summary = LiveSummary(text: text, updatedAt: .now, coveredLineID: covered)
                updatesSinceRewrite = rewrite ? 0 : updatesSinceRewrite + 1
                lastError = nil
            } catch {
                lastError = error.localizedDescription
                AudioLog.write("summary failed: \(error.localizedDescription)")
            }
        }
    }

    /// Sends one request; turns a non-JSON error page into its HTTP status.
    private static func send(_ request: URLRequest, endpoint: SummaryEndpoint) async throws -> String {
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
