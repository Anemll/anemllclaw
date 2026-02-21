#if os(iOS) || os(tvOS)
import Foundation
import OpenClawGatewayCore

struct SavedLLMProvider: Codable, Identifiable, Equatable, Sendable {
    var id: String
    var name: String
    var provider: GatewayLocalLLMProviderKind
    var baseURL: String
    /// API key is NOT persisted via Codable — stored in Keychain instead.
    var apiKey: String
    var model: String
    var toolCallingMode: GatewayLocalLLMToolCallingMode

    private enum CodingKeys: String, CodingKey {
        case id, name, provider, baseURL, model, toolCallingMode
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(String.self, forKey: .id)
        self.name = try c.decode(String.self, forKey: .name)
        self.provider = try c.decode(GatewayLocalLLMProviderKind.self, forKey: .provider)
        self.baseURL = try c.decode(String.self, forKey: .baseURL)
        self.model = try c.decode(String.self, forKey: .model)
        self.toolCallingMode = try c.decodeIfPresent(GatewayLocalLLMToolCallingMode.self, forKey: .toolCallingMode) ?? .auto
        self.apiKey = "" // hydrated from Keychain by LLMProviderStore.load()
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(self.id, forKey: .id)
        try c.encode(self.name, forKey: .name)
        try c.encode(self.provider, forKey: .provider)
        try c.encode(self.baseURL, forKey: .baseURL)
        try c.encode(self.model, forKey: .model)
        try c.encode(self.toolCallingMode, forKey: .toolCallingMode)
        // apiKey intentionally omitted — lives in Keychain
    }

    init(
        id: String = UUID().uuidString,
        name: String = "",
        provider: GatewayLocalLLMProviderKind = .disabled,
        baseURL: String = "",
        apiKey: String = "",
        model: String = "",
        toolCallingMode: GatewayLocalLLMToolCallingMode = .auto)
    {
        self.id = id
        self.name = name
        self.provider = provider
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.model = model
        self.toolCallingMode = toolCallingMode
    }

    var displayName: String {
        let trimmed = self.name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
        let modelTrimmed = self.model.trimmingCharacters(in: .whitespacesAndNewlines)
        if !modelTrimmed.isEmpty { return modelTrimmed }
        return self.provider.displayLabel
    }

    var isConfigured: Bool {
        self.provider != .disabled
            && !self.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var shortDisplayName: String {
        let m = self.model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !m.isEmpty else { return self.provider.displayLabel }
        let lower = m.lowercased()

        if lower.hasPrefix("gpt-") {
            let rest = m.dropFirst(4)
            let parts = rest.split(separator: "-", maxSplits: 2)
            if parts.count >= 2 {
                return "GPT-\(parts[0]) \(parts[1])"
            }
            return "GPT-\(rest)"
        }

        if lower.hasPrefix("claude-") {
            let rest = m.dropFirst(7)
            let parts = rest.split(separator: "-")
            if parts.count >= 2,
               let _ = Double(parts[0])
            {
                return "Claude \(parts[0]).\(parts[1])"
            }
            if let first = parts.first {
                let initial = first.prefix(1).uppercased()
                let remaining = parts.dropFirst().prefix(2).joined(separator: ".")
                if !remaining.isEmpty {
                    return "Claude \(initial)\(remaining)"
                }
                return "Claude \(first)"
            }
            return "Claude"
        }

        if lower.hasPrefix("grok-") {
            let rest = m.dropFirst(5)
            let parts = rest.split(separator: "-")
            let version = parts.prefix(2).joined(separator: ".")
            return "Grok \(version)"
        }

        if lower.hasPrefix("minimax-") {
            let rest = m.dropFirst(8)
            return "MiniMax \(rest)"
        }

        if lower.hasPrefix("llama-") || lower.hasPrefix("llama3") {
            let parts = m.split(separator: "-")
            let version = parts.dropFirst().prefix(2).joined(separator: ".")
            if !version.isEmpty {
                return "Llama \(version)"
            }
            return "Llama"
        }

        if lower.hasPrefix("gemini-") {
            let rest = m.dropFirst(7)
            let parts = rest.split(separator: "-")
            let version = parts.prefix(2).joined(separator: " ")
            return "Gemini \(version)"
        }

        if lower.hasPrefix("deepseek-") {
            let rest = m.dropFirst(9)
            return "DeepSeek \(rest.prefix(6))"
        }

        return String(m.prefix(14))
    }
}

extension GatewayLocalLLMProviderKind {
    var displayLabel: String {
        switch self {
        case .disabled: "Disabled"
        case .openAICompatible: "OpenAI"
        case .anthropicCompatible: "Anthropic"
        case .minimaxCompatible: "MiniMax"
        case .grokCompatible: "Grok"
        }
    }
}

enum LLMProviderStore {
    private static let defaultsKey = "llm.savedProviders"
    private static let activeIDKey = "llm.activeProviderID"
    private static let keychainService = "ai.openclaw.llm"

    static func load(defaults: UserDefaults = .standard) -> [SavedLLMProvider] {
        guard let data = defaults.data(forKey: defaultsKey) else { return [] }
        var providers = (try? JSONDecoder().decode([SavedLLMProvider].self, from: data)) ?? []
        // Hydrate API keys from Keychain
        for i in providers.indices {
            providers[i].apiKey = KeychainStore.loadString(
                service: Self.keychainService,
                account: providers[i].id) ?? ""
        }
        // One-time migration: if Keychain is empty but UserDefaults still has
        // apiKey encoded (from the pre-Keychain format), migrate it over.
        Self.migrateKeysFromDefaults(&providers, defaults: defaults)
        return providers
    }

    static func save(_ providers: [SavedLLMProvider], defaults: UserDefaults = .standard) {
        // Persist API keys in Keychain (not UserDefaults)
        for provider in providers {
            let key = provider.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
            if key.isEmpty {
                _ = KeychainStore.delete(service: Self.keychainService, account: provider.id)
            } else {
                _ = KeychainStore.saveString(key, service: Self.keychainService, account: provider.id)
            }
        }
        // Encode without apiKey (excluded by CodingKeys)
        guard let data = try? JSONEncoder().encode(providers) else { return }
        defaults.set(data, forKey: Self.defaultsKey)
    }

    /// Remove a provider's Keychain entry when the provider is deleted.
    static func deleteAPIKey(forProviderID id: String) {
        _ = KeychainStore.delete(service: Self.keychainService, account: id)
    }

    static func activeID(defaults: UserDefaults = .standard) -> String? {
        defaults.string(forKey: self.activeIDKey)
    }

    static func setActiveID(_ id: String?, defaults: UserDefaults = .standard) {
        if let id {
            defaults.set(id, forKey: self.activeIDKey)
        } else {
            defaults.removeObject(forKey: Self.activeIDKey)
        }
    }

    /// Migrate the legacy single-provider config from `gateway.tvos.localLLM.*`
    /// into the saved providers list. Called once on first load when no saved
    /// providers exist yet.
    static func migrateFromLegacyIfNeeded(
        defaults: UserDefaults = .standard) -> (providers: [SavedLLMProvider], activeID: String?)
    {
        let existing = Self.load(defaults: defaults)
        if !existing.isEmpty {
            return (existing, Self.activeID(defaults: defaults))
        }

        let providerRaw = defaults.string(forKey: "gateway.tvos.localLLM.provider") ?? ""
        let provider = GatewayLocalLLMProviderKind(rawValue: providerRaw) ?? .disabled
        guard provider != .disabled else { return ([], nil) }

        let baseURL = (defaults.string(forKey: "gateway.tvos.localLLM.baseURL") ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let apiKey = (defaults.string(forKey: "gateway.tvos.localLLM.apiKey") ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let model = (defaults.string(forKey: "gateway.tvos.localLLM.model") ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !model.isEmpty else { return ([], nil) }

        let migrated = SavedLLMProvider(
            name: provider.displayLabel,
            provider: provider,
            baseURL: baseURL,
            apiKey: apiKey,
            model: model)

        let providers = [migrated]
        Self.save(providers, defaults: defaults)
        Self.setActiveID(migrated.id, defaults: defaults)
        return (providers, migrated.id)
    }

    // MARK: - Internal migration helper

    /// One-time migration: older builds stored apiKey inside the JSON blob in
    /// UserDefaults. If we find a provider whose Keychain entry is empty but
    /// the raw JSON still contains an "apiKey" field, move it to Keychain and
    /// re-save without the key.
    private static func migrateKeysFromDefaults(
        _ providers: inout [SavedLLMProvider],
        defaults: UserDefaults)
    {
        guard let data = defaults.data(forKey: defaultsKey),
              let raw = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else { return }

        var didMigrate = false
        for i in providers.indices where providers[i].apiKey.isEmpty {
            guard i < raw.count,
                  let legacyKey = raw[i]["apiKey"] as? String,
                  !legacyKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else { continue }
            let trimmed = legacyKey.trimmingCharacters(in: .whitespacesAndNewlines)
            providers[i].apiKey = trimmed
            _ = KeychainStore.saveString(trimmed, service: Self.keychainService, account: providers[i].id)
            didMigrate = true
        }
        // Re-save without the apiKey field in UserDefaults
        if didMigrate {
            if let cleanData = try? JSONEncoder().encode(providers) {
                defaults.set(cleanData, forKey: Self.defaultsKey)
            }
        }
    }
}

#endif
