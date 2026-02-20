#if os(iOS) || os(tvOS)
import Foundation
import OpenClawGatewayCore

struct SavedLLMProvider: Codable, Identifiable, Equatable, Sendable {
    var id: String
    var name: String
    var provider: GatewayLocalLLMProviderKind
    var baseURL: String
    var apiKey: String
    var model: String
    var toolCallingMode: GatewayLocalLLMToolCallingMode

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
        case .disabled: return "Disabled"
        case .openAICompatible: return "OpenAI"
        case .anthropicCompatible: return "Anthropic"
        case .minimaxCompatible: return "MiniMax"
        case .grokCompatible: return "Grok"
        }
    }
}

enum LLMProviderStore {
    private static let defaultsKey = "llm.savedProviders"
    private static let activeIDKey = "llm.activeProviderID"

    static func load(defaults: UserDefaults = .standard) -> [SavedLLMProvider] {
        guard let data = defaults.data(forKey: Self.defaultsKey) else { return [] }
        return (try? JSONDecoder().decode([SavedLLMProvider].self, from: data)) ?? []
    }

    static func save(_ providers: [SavedLLMProvider], defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(providers) else { return }
        defaults.set(data, forKey: Self.defaultsKey)
    }

    static func activeID(defaults: UserDefaults = .standard) -> String? {
        defaults.string(forKey: Self.activeIDKey)
    }

    static func setActiveID(_ id: String?, defaults: UserDefaults = .standard) {
        if let id {
            defaults.set(id, forKey: Self.activeIDKey)
        } else {
            defaults.removeObject(forKey: Self.activeIDKey)
        }
    }

    /// Migrate the legacy single-provider config from `gateway.tvos.localLLM.*`
    /// into the saved providers list. Called once on first load when no saved
    /// providers exist yet.
    static func migrateFromLegacyIfNeeded(
        defaults: UserDefaults = .standard
    ) -> (providers: [SavedLLMProvider], activeID: String?)
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
}

#endif
