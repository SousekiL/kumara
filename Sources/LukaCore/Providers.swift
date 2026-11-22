import Foundation

/// A language-model service the user has added: where it is, how to talk to it, and the models
/// they use there. Its API key is kept apart, with the other secrets.
public struct ModelProvider: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var name: String
    public var kind: SummaryProvider
    /// Empty uses the kind's default address.
    public var baseURL: String
    /// The model names as typed, separated by commas or new lines.
    public var modelList: String

    public init(id: UUID = UUID(), name: String, kind: SummaryProvider, baseURL: String = "", modelList: String = "") {
        self.id = id
        self.name = name
        self.kind = kind
        self.baseURL = baseURL
        self.modelList = modelList
    }

    public var models: [String] {
        var seen = Set<String>()
        return modelList.split(whereSeparator: { $0 == "," || $0 == "，" || $0.isNewline })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    /// The name to show: the one given, or the service its address belongs to
    /// ("Anthropic" for api.anthropic.com).
    public var title: String {
        let name = name.trimmingCharacters(in: .whitespaces)
        if !name.isEmpty { return name }
        guard let host = URL(string: baseURL.isEmpty ? kind.defaultBaseURL : baseURL)?.host?.lowercased() else { return baseURL }
        if let known = Self.services.first(where: { host == $0.domain || host.hasSuffix("." + $0.domain) }) { return known.name }
        // Otherwise the name in the address: "api.example.com" is "Example". A bare host or an IP address stays as it is.
        let labels = host.split(separator: ".")
        guard labels.count >= 2, !labels.allSatisfy({ $0.allSatisfy(\.isNumber) }) else { return host }
        return labels[labels.count - 2].capitalized
    }

    static let services: [(domain: String, name: String)] = [
        ("anthropic.com", "Anthropic"), ("openai.com", "OpenAI"), ("deepseek.com", "DeepSeek"),
        ("aliyuncs.com", "Qwen"), ("openrouter.ai", "OpenRouter"),
    ]

    public func endpoint(model: String) -> SummaryEndpoint {
        SummaryEndpoint(provider: kind, baseURL: baseURL, model: model)
    }

    mutating func add(model: String) {
        guard !model.isEmpty, !models.contains(model) else { return }
        modelList += (modelList.trimmingCharacters(in: .whitespaces).isEmpty ? "" : ", ") + model
    }
}

/// One model at one provider: what a part of the app is set to use.
public struct ModelChoice: Codable, Hashable, Sendable {
    public var provider: UUID
    public var model: String

    public init(provider: UUID, model: String) {
        self.provider = provider
        self.model = model
    }
}

extension [ModelProvider] {
    /// The provider and model a choice points at; nil once either has been removed.
    public func resolve(_ choice: ModelChoice?) -> (provider: ModelProvider, endpoint: SummaryEndpoint)? {
        guard let choice, let provider = first(where: { $0.id == choice.provider }), provider.models.contains(choice.model) else { return nil }
        return (provider, provider.endpoint(model: choice.model))
    }

    /// Every model that can be chosen, in the order the providers and their models are listed.
    public var choices: [(choice: ModelChoice, title: String)] {
        flatMap { p in p.models.map { (ModelChoice(provider: p.id, model: $0), p.title + " · " + $0) } }
    }
}

/// The settings from before providers were a list: one service for the live helpers, and
/// optionally another for deep analysis, each typed in full.
public struct LegacyModelSettings: Sendable {
    public struct Slot: Sendable {
        public var kind: SummaryProvider
        public var baseURL: String
        public var model: String
        public var key: String

        public init(kind: SummaryProvider, baseURL: String, model: String, key: String) {
            self.kind = kind
            self.baseURL = baseURL
            self.model = model
            self.key = key
        }

        var isEmpty: Bool { [baseURL, model, key].allSatisfy { $0.trimmingCharacters(in: .whitespaces).isEmpty } }
    }

    public struct Migrated: Sendable {
        public var providers: [ModelProvider] = []
        public var keys: [UUID: String] = [:]
        public var live: ModelChoice?
        public var deep: ModelChoice?
    }

    /// The same settings as a list of providers. Two slots at the same address with the same key
    /// are one provider with two models.
    public static func migrate(live: Slot, deep: Slot?) -> Migrated {
        var out = Migrated()
        func place(_ slot: Slot) -> ModelChoice? {
            guard !slot.isEmpty else { return nil }
            let model = slot.model.trimmingCharacters(in: .whitespaces)
            let key = slot.key.trimmingCharacters(in: .whitespacesAndNewlines)
            let base = slot.baseURL.trimmingCharacters(in: .whitespaces)
            var index = out.providers.firstIndex { $0.kind == slot.kind && $0.baseURL == base && out.keys[$0.id, default: ""] == key }
            if index == nil {
                out.providers.append(ModelProvider(name: "", kind: slot.kind, baseURL: base))
                index = out.providers.count - 1
                if !key.isEmpty { out.keys[out.providers[index!].id] = key }
            }
            out.providers[index!].add(model: model)
            return model.isEmpty ? nil : ModelChoice(provider: out.providers[index!].id, model: model)
        }
        out.live = place(live)
        if let deep { out.deep = place(deep) }
        return out
    }
}
