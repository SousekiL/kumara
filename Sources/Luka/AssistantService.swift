import Foundation
import LukaCore

/// The language model behind the summary and the answers, and what both share: the service and key,
/// the language they write in, their text size, and the note about this conversation.
@MainActor
@Observable
final class AssistantService {
    private let defaults = UserDefaults.standard

    /// The services the user has added, each with the models they use there. Added once, then
    /// each part of the app picks one of their models.
    var providers: [ModelProvider] {
        didSet { if let data = try? JSONEncoder().encode(providers) { defaults.set(data, forKey: "assistant.providers") } }
    }
    /// Each provider's API key, kept with the other secrets rather than in the settings.
    private(set) var keys: [UUID: String]
    /// The model for the live helpers: the summary, the answers, feedback and the review.
    var liveChoice: ModelChoice? { didSet { Self.store(liveChoice, "assistant.liveChoice") } }
    /// The model for deep analysis; nil uses the live helpers' model.
    var deepChoice: ModelChoice? { didSet { Self.store(deepChoice, "assistant.deepChoice") } }

    func key(for provider: UUID) -> String { keys[provider] ?? "" }

    func setKey(_ key: String, for provider: UUID) {
        keys[provider] = key
        SecretStore.save(key, slot: Self.slot(provider))
    }

    @discardableResult
    func addProvider(name: String, kind: SummaryProvider, baseURL: String, model: String) -> UUID {
        let provider = ModelProvider(name: name, kind: kind, baseURL: baseURL, modelList: model)
        providers.append(provider)
        // The first model added is the one to use, so a new install works without a second step.
        if liveChoice == nil, let first = provider.models.first { liveChoice = ModelChoice(provider: provider.id, model: first) }
        return provider.id
    }

    func removeProvider(_ id: UUID) {
        providers.removeAll { $0.id == id }
        setKey("", for: id)
        keys[id] = nil
        if liveChoice?.provider == id { liveChoice = nil }
        if deepChoice?.provider == id { deepChoice = nil }
    }

    private static func slot(_ provider: UUID) -> String { "provider-" + provider.uuidString }

    private static func store(_ choice: ModelChoice?, _ key: String) {
        UserDefaults.standard.set(choice.flatMap { try? JSONEncoder().encode($0) }, forKey: key)
    }

    private static func choice(_ key: String) -> ModelChoice? {
        UserDefaults.standard.data(forKey: key).flatMap { try? JSONDecoder().decode(ModelChoice.self, from: $0) }
    }

    private var apiKey: String { providers.resolve(liveChoice).map { key(for: $0.provider.id) } ?? "" }
    /// Soniox language code; empty follows the translation language, "guide" is bilingual.
    var language: String { didSet { defaults.set(language, forKey: "summary.language") } }
    var fontSize: Double { didSet { defaults.set(fontSize, forKey: "summary.fontSize") } }
    static let fontRange = 11.0...22.0
    /// About this conversation, in the user's words: added to the summary's and the answers' prompts.
    var note: String { didSet { defaults.set(note, forKey: "assistant.note") } }
    /// The names the reader goes by, so a meeting turning to them is noticed.
    var readerNames: String { didSet { defaults.set(readerNames, forKey: "assistant.readerNames") } }
    var names: [String] { ReaderNames.parse(readerNames) }
    /// What the prompts add about the reader and this conversation.
    var context: String {
        [ReaderNames.promptLine(names), note.trimmingCharacters(in: .whitespacesAndNewlines)]
            .filter { !$0.isEmpty }.joined(separator: "\n")
    }

    /// What the prompts about one session add: the standing context, then what the reader wrote about that session.
    func context(for t: Transcript, limit: Int = SessionBackground.limit) -> String {
        SessionBackground.extra(standing: context, background: t.background, limit: limit)
    }

    private(set) var testResult: String?
    private(set) var testing = false

    // A separate model for questions the reader asks: worth a stronger model and a longer wait.
    // A choice whose provider or model has since been removed falls back to the live helpers' model.
    private var askUsesOwnModel: Bool { providers.resolve(deepChoice) != nil }
    private var askAPIKey: String { providers.resolve(deepChoice).map { key(for: $0.provider.id) } ?? "" }
    /// Deepest reasoning for asked questions (extended thinking, or high reasoning effort).
    var askThinks: Bool { didSet { defaults.set(askThinks, forKey: "ask.thinks") } }
    private(set) var askTestResult: String?
    private(set) var askTesting = false

    init() {
        let d = UserDefaults.standard
        if let data = d.data(forKey: "assistant.providers"), let saved = try? JSONDecoder().decode([ModelProvider].self, from: data) {
            providers = saved
            keys = Dictionary(uniqueKeysWithValues: saved.compactMap { p in SecretStore.read(Self.slot(p.id)).map { (p.id, $0) } })
            liveChoice = Self.choice("assistant.liveChoice")
            deepChoice = Self.choice("assistant.deepChoice")
        } else {
            // From before providers were a list: one service typed in full, and optionally a second.
            // The old settings and keys are left where they were.
            let live = LegacyModelSettings.Slot(kind: SummaryProvider(rawValue: d.string(forKey: "summary.provider") ?? "") ?? .openAI,
                                                baseURL: d.string(forKey: "summary.baseURL") ?? "", model: d.string(forKey: "summary.model") ?? "",
                                                key: SecretStore.read("summary") ?? "")
            let deep = !d.bool(forKey: "ask.ownModel") ? nil
                : LegacyModelSettings.Slot(kind: SummaryProvider(rawValue: d.string(forKey: "ask.provider") ?? "") ?? .anthropic,
                                           baseURL: d.string(forKey: "ask.baseURL") ?? "", model: d.string(forKey: "ask.model") ?? "",
                                           key: SecretStore.read("ask") ?? "")
            let migrated = LegacyModelSettings.migrate(live: live, deep: deep)
            providers = migrated.providers
            keys = migrated.keys
            liveChoice = migrated.live
            deepChoice = migrated.deep
            // Property observers don't run in init: write what they would have.
            if let data = try? JSONEncoder().encode(migrated.providers) { d.set(data, forKey: "assistant.providers") }
            for (id, key) in migrated.keys { SecretStore.save(key, slot: Self.slot(id)) }
            Self.store(migrated.live, "assistant.liveChoice")
            Self.store(migrated.deep, "assistant.deepChoice")
        }
        language = d.string(forKey: "summary.language") ?? ""
        // 14 pt reads comfortably at arm's length in a side column; 13 is the system's body size.
        fontSize = d.object(forKey: "summary.fontSize") as? Double ?? 14
        readerNames = d.string(forKey: "assistant.readerNames") ?? ""
        askThinks = d.object(forKey: "ask.thinks") as? Bool ?? true
        if let note = d.string(forKey: "assistant.note") {
            self.note = note
        } else {
            // The summary and the answers each had their own instructions; keep both, once.
            let parts = [d.string(forKey: "summary.instructions"), d.string(forKey: "answers.instructions")]
                .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            note = parts.reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }.joined(separator: "\n")
        }
    }

    var endpoint: SummaryEndpoint {
        providers.resolve(liveChoice)?.endpoint ?? SummaryEndpoint(provider: .openAI, baseURL: "", model: "")
    }

    /// A local server such as Ollama needs no key.
    private var isLocal: Bool { ["localhost", "127.0.0.1", "0.0.0.0"].contains(endpoint.url?.host ?? "") }

    var isConfigured: Bool {
        !endpoint.model.isEmpty
            && (!apiKey.trimmingCharacters(in: .whitespaces).isEmpty || isLocal)
            && endpoint.url != nil
    }

    func request(system: String, user: String, shared: String = "", maxTokens: Int, stream: Bool = false) -> URLRequest? {
        endpoint.request(apiKey: apiKey, system: system, user: user, shared: shared, maxTokens: maxTokens, stream: stream)
    }

    /// The model for questions the reader asks: its own when set, otherwise the shared one.
    var askEndpoint: SummaryEndpoint {
        providers.resolve(deepChoice)?.endpoint ?? endpoint
    }

    var isAskConfigured: Bool {
        guard askUsesOwnModel else { return isConfigured }
        let e = askEndpoint
        let local = ["localhost", "127.0.0.1", "0.0.0.0"].contains(e.url?.host ?? "")
        return !e.model.isEmpty && (!askAPIKey.trimmingCharacters(in: .whitespaces).isEmpty || local) && e.url != nil
    }

    /// The thinking style each model turned out to accept, so later questions skip the ones it rejects.
    private var acceptedThinking: [String: SummaryEndpoint.Thinking] = [:]

    /// The thinking styles to try for the next question, best first.
    var askThinkingOrder: [SummaryEndpoint.Thinking] {
        guard askThinks else { return [.none] }
        let e = askEndpoint
        let all = e.thinkingFallbacks
        guard let known = acceptedThinking[Self.key(e)], let i = all.firstIndex(of: known) else { return all }
        return Array(all[i...])
    }

    func noteAccepted(_ thinking: SummaryEndpoint.Thinking) {
        acceptedThinking[Self.key(askEndpoint)] = thinking
    }

    private static func key(_ e: SummaryEndpoint) -> String { "\(e.provider.rawValue)|\(e.baseURL)|\(e.model)" }

    /// Runs one request on the deep model, streamed. Models accept different thinking settings,
    /// so this steps down to the next style when one is rejected, and remembers what worked.
    func deepStream(system: String, user: String, effort: SummaryEndpoint.Effort = .medium,
                    progress: @MainActor (String) -> Void = { _ in }) async throws -> String {
        let order = askThinkingOrder
        let endpoint = askEndpoint
        for (i, thinking) in order.enumerated() {
            guard let request = askRequest(system: system, user: user, thinking: thinking, effort: effort) else { throw URLError(.badURL) }
            do {
                let reply = try await stream(request, via: endpoint, progress: progress)
                noteAccepted(thinking)
                return reply
            } catch let error where i < order.count - 1 && !Task.isCancelled
                && SummaryEndpoint.rejectsThinking(error.localizedDescription) {
                AudioLog.write("deep model: thinking style rejected, trying the next: \(error.localizedDescription)")
            }
        }
        throw SummaryEndpoint.ResponseError.empty
    }

    func askRequest(system: String, user: String, thinking: SummaryEndpoint.Thinking,
                    effort: SummaryEndpoint.Effort = .medium) -> URLRequest? {
        (askUsesOwnModel ? askEndpoint : endpoint)
            .request(apiKey: askUsesOwnModel ? askAPIKey : apiKey, system: system, user: user, maxTokens: 6_000, stream: true,
                     thinking: thinking, effort: effort)
    }

    // MARK: Sending

    /// Sends one request and waits for the whole reply.
    func send(_ request: URLRequest) async throws -> String {
        let endpoint = self.endpoint
        let (data, response) = try await URLSession.shared.data(for: request)
        return try Self.parse(data, response: response, endpoint: endpoint)
    }

    /// Sends a streaming request; `progress` gets the reply so far as it comes in.
    /// A service that answers all at once instead still works.
    func stream(_ request: URLRequest, via endpoint: SummaryEndpoint? = nil, progress: @MainActor (String) -> Void) async throws -> String {
        let endpoint = endpoint ?? self.endpoint
        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        let http = response as? HTTPURLResponse
        let type = http?.value(forHTTPHeaderField: "Content-Type") ?? ""
        guard (http?.statusCode ?? 200) < 400, type.contains("event-stream") else {
            var data = Data()
            for try await byte in bytes { data.append(byte) }
            let text = try Self.parse(data, response: response, endpoint: endpoint)
            progress(text)
            return text
        }
        var text = ""
        var stop: String?
        var shown = Date.distantPast
        reading: for try await line in bytes.lines {
            switch endpoint.streamChunk(line) {
            case .text(let more):
                text += more
                // A few redraws a second is smooth enough, and keeps a fast stream from flooding the view.
                if Date.now.timeIntervalSince(shown) > 0.08 {
                    shown = .now
                    progress(text)
                }
            case .stop(let reason): stop = reason
            case .error(let message): throw SummaryEndpoint.ResponseError.api(message)
            case .done: break reading
            case nil: continue
            }
        }
        progress(text)
        return try endpoint.finish(streamed: text, stop: stop)
    }

    /// The reply, or an error page turned into its HTTP status.
    private static func parse(_ data: Data, response: URLResponse, endpoint: SummaryEndpoint) throws -> String {
        do {
            return try endpoint.parse(data)
        } catch let error as SummaryEndpoint.ResponseError {
            throw error
        } catch {
            // Some gateways stream without saying so: the body is the stream itself.
            if let text = try endpoint.parseStreamBody(data) { return text }
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            throw SummaryEndpoint.ResponseError.api(String(format: tr("The summary model replied with HTTP %d."), code))
        }
    }

    // MARK: Settings

    /// Settings' test button for the asked-questions model.
    func testAsk() {
        guard isAskConfigured else {
            askTestResult = tr("Fill in the model and API key first.")
            return
        }
        let e = askEndpoint
        guard let request = e.request(apiKey: askUsesOwnModel ? askAPIKey : apiKey, system: "Reply with the single word OK.", user: "ping", maxTokens: 2_000) else {
            askTestResult = tr("The summary model’s address isn’t valid.")
            return
        }
        askTesting = true
        askTestResult = nil
        Task {
            defer { askTesting = false }
            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                let reply = try Self.parse(data, response: response, endpoint: e)
                askTestResult = tr("Connected") + " · " + String(reply.prefix(40))
            } catch {
                askTestResult = error.localizedDescription
            }
        }
    }

    /// Settings' test button: one tiny request to check the address, key and model.
    func test() {
        guard isConfigured else {
            testResult = tr("Fill in the model and API key first.")
            return
        }
        guard let request = request(system: "Reply with the single word OK.", user: "ping", maxTokens: 2_000) else {
            testResult = tr("The summary model’s address isn’t valid.")
            return
        }
        testing = true
        testResult = nil
        Task {
            defer { testing = false }
            do {
                let reply = try await send(request)
                testResult = tr("Connected") + " · " + String(reply.prefix(40))
            } catch {
                testResult = error.localizedDescription
            }
        }
    }
}
