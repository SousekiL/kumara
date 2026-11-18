import Foundation
import LukaCore

/// The language model behind the summary and the answers, and what both share: the service and key,
/// the language they write in, their text size, and the note about this conversation.
@MainActor
@Observable
final class AssistantService {
    private let defaults = UserDefaults.standard

    // Stored under the keys the summary used before the two shared a service, so nothing is lost.
    var provider: SummaryProvider { didSet { defaults.set(provider.rawValue, forKey: "summary.provider") } }
    /// Empty uses the provider's default endpoint.
    var baseURL: String { didSet { defaults.set(baseURL, forKey: "summary.baseURL") } }
    var model: String { didSet { defaults.set(model, forKey: "summary.model") } }
    var apiKey: String { didSet { SecretStore.save(apiKey, slot: "summary") } }
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

    private(set) var testResult: String?
    private(set) var testing = false

    // A separate model for questions the reader asks: worth a stronger model and a longer wait.
    var askUsesOwnModel: Bool { didSet { defaults.set(askUsesOwnModel, forKey: "ask.ownModel") } }
    var askProvider: SummaryProvider { didSet { defaults.set(askProvider.rawValue, forKey: "ask.provider") } }
    var askBaseURL: String { didSet { defaults.set(askBaseURL, forKey: "ask.baseURL") } }
    var askModel: String { didSet { defaults.set(askModel, forKey: "ask.model") } }
    var askAPIKey: String { didSet { SecretStore.save(askAPIKey, slot: "ask") } }
    /// Deepest reasoning for asked questions (extended thinking, or high reasoning effort).
    var askThinks: Bool { didSet { defaults.set(askThinks, forKey: "ask.thinks") } }
    private(set) var askTestResult: String?
    private(set) var askTesting = false

    init() {
        let d = UserDefaults.standard
        provider = SummaryProvider(rawValue: d.string(forKey: "summary.provider") ?? "") ?? .openAI
        baseURL = d.string(forKey: "summary.baseURL") ?? ""
        model = d.string(forKey: "summary.model") ?? ""
        apiKey = SecretStore.read("summary") ?? ""
        language = d.string(forKey: "summary.language") ?? ""
        // 14 pt reads comfortably at arm's length in a side column; 13 is the system's body size.
        fontSize = d.object(forKey: "summary.fontSize") as? Double ?? 14
        readerNames = d.string(forKey: "assistant.readerNames") ?? "Felix, Weifeng"
        askUsesOwnModel = d.bool(forKey: "ask.ownModel")
        askProvider = SummaryProvider(rawValue: d.string(forKey: "ask.provider") ?? "") ?? .anthropic
        askBaseURL = d.string(forKey: "ask.baseURL") ?? ""
        askModel = d.string(forKey: "ask.model") ?? ""
        askAPIKey = SecretStore.read("ask") ?? ""
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

    var endpoint: SummaryEndpoint { SummaryEndpoint(provider: provider, baseURL: baseURL, model: model.trimmingCharacters(in: .whitespaces)) }

    /// A local server such as Ollama needs no key.
    private var isLocal: Bool { ["localhost", "127.0.0.1", "0.0.0.0"].contains(endpoint.url?.host ?? "") }

    var isConfigured: Bool {
        !model.trimmingCharacters(in: .whitespaces).isEmpty
            && (!apiKey.trimmingCharacters(in: .whitespaces).isEmpty || isLocal)
            && endpoint.url != nil
    }

    func request(system: String, user: String, maxTokens: Int, stream: Bool = false) -> URLRequest? {
        endpoint.request(apiKey: apiKey, system: system, user: user, maxTokens: maxTokens, stream: stream)
    }

    /// The model for questions the reader asks: its own when set, otherwise the shared one.
    var askEndpoint: SummaryEndpoint {
        askUsesOwnModel ? SummaryEndpoint(provider: askProvider, baseURL: askBaseURL, model: askModel.trimmingCharacters(in: .whitespaces)) : endpoint
    }

    var isAskConfigured: Bool {
        guard askUsesOwnModel else { return isConfigured }
        let e = askEndpoint
        let local = ["localhost", "127.0.0.1", "0.0.0.0"].contains(e.url?.host ?? "")
        return !e.model.isEmpty && (!askAPIKey.trimmingCharacters(in: .whitespaces).isEmpty || local) && e.url != nil
    }

    func askRequest(system: String, user: String) -> URLRequest? {
        askUsesOwnModel
            ? askEndpoint.request(apiKey: askAPIKey, system: system, user: user, maxTokens: 6_000, stream: true, thinks: askThinks)
            : endpoint.request(apiKey: apiKey, system: system, user: user, maxTokens: 6_000, stream: true, thinks: askThinks)
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
        guard let request = e.request(apiKey: askAPIKey, system: "Reply with the single word OK.", user: "ping", maxTokens: 2_000) else {
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
