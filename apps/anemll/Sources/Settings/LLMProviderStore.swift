#if os(iOS) || os(tvOS)
import CryptoKit
import Foundation
import OpenClawGatewayCore
import Security

enum SavedLLMProviderAuthMode: String, Codable, Equatable, Sendable {
    case apiKey = "api-key"
    case openAIOAuthSub = "openai-oauth-sub"

    var displayLabel: String {
        switch self {
        case .apiKey:
            "API Key"
        case .openAIOAuthSub:
            "OpenAI-OAuth-sub"
        }
    }
}

struct OpenAIOAuthSubAuthorizationContext: Sendable, Equatable {
    let verifier: String
    let state: String
    let url: URL
}

struct OpenAIOAuthSubTokenSet: Sendable, Equatable {
    let accessToken: String
    let refreshToken: String
    let expiresAtMs: Int64
    let accountID: String
}

enum OpenAIOAuthSubClientError: LocalizedError {
    case cryptoUnavailable(OSStatus)
    case invalidAuthorizeURL
    case callbackMissingCode
    case callbackAuthorizationFailed(code: String, description: String?)
    case stateMismatch
    case tokenExchangeFailed(status: Int, message: String)
    case invalidTokenResponse
    case missingAccountID
    case modelsFetchFailed(status: Int, message: String)
    case invalidModelsResponse

    var errorDescription: String? {
        switch self {
        case let .cryptoUnavailable(status):
            return "Failed to generate secure random bytes (status \(status))."
        case .invalidAuthorizeURL:
            return "Failed to construct OpenAI OAuth authorization URL."
        case .callbackMissingCode:
            return "OpenAI OAuth callback did not include an authorization code."
        case let .callbackAuthorizationFailed(code, description):
            let normalizedCode = code
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: "_", with: " ")
            if let description,
               !description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            {
                return "OpenAI OAuth authorization failed (\(normalizedCode)): \(description)"
            }
            return "OpenAI OAuth authorization failed (\(normalizedCode))."
        case .stateMismatch:
            return "OpenAI OAuth callback state did not match the request."
        case let .tokenExchangeFailed(status, message):
            let suffix = message.isEmpty ? "" : " \(message)"
            return "OpenAI OAuth token request failed (HTTP \(status)).\(suffix)"
        case .invalidTokenResponse:
            return "OpenAI OAuth token response was missing required fields."
        case .missingAccountID:
            return "OpenAI OAuth token did not include a ChatGPT account ID."
        case let .modelsFetchFailed(status, message):
            let suffix = message.isEmpty ? "" : " \(message)"
            return "Fetching OpenAI models failed (HTTP \(status)).\(suffix)"
        case .invalidModelsResponse:
            return "OpenAI models response format was invalid."
        }
    }
}

enum OpenAIOAuthSubClient {
    static let callbackURLScheme = "http"
    static let subscriptionBaseURL = "https://chatgpt.com/backend-api"
    private static let clientID = "app_EMoamEEZ73f0CkXaXp7hrann"
    private static let authorizeURL = URL(string: "https://auth.openai.com/oauth/authorize")!
    private static let tokenURL = URL(string: "https://auth.openai.com/oauth/token")!
    private static let modelsURL = URL(string: "https://api.openai.com/v1/models")!
    private static let redirectURI = "http://localhost:1455/auth/callback"
    private static let scope = [
        "openid",
        "profile",
        "email",
        "offline_access",
    ].joined(separator: " ")
    private static let codexModelFallbackIDs = [
        "gpt-5.3-codex",
        "gpt-5.3-codex-spark",
        "gpt-5.2-codex",
        "gpt-5.2",
        "gpt-5.1-codex",
        "gpt-5.1-codex-mini",
        "gpt-5.1-codex-max",
        "gpt-5.1",
    ]
    private static let jwtClaimPath = "https://api.openai.com/auth"

    static func makeAuthorizationContext(originator: String = "pi") throws -> OpenAIOAuthSubAuthorizationContext {
        let verifier = try self.randomVerifier()
        let challenge = self.sha256Base64URL(verifier)
        let state = try self.randomHex(bytes: 16)

        var components = URLComponents(url: Self.authorizeURL, resolvingAgainstBaseURL: false)
        components?.queryItems = [
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "client_id", value: Self.clientID),
            URLQueryItem(name: "redirect_uri", value: Self.redirectURI),
            URLQueryItem(name: "scope", value: Self.scope),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "id_token_add_organizations", value: "true"),
            URLQueryItem(name: "codex_cli_simplified_flow", value: "true"),
            URLQueryItem(name: "originator", value: originator),
        ]
        guard let url = components?.url else {
            throw OpenAIOAuthSubClientError.invalidAuthorizeURL
        }
        return OpenAIOAuthSubAuthorizationContext(verifier: verifier, state: state, url: url)
    }

    static func parseAuthorizationCallback(
        _ callbackURL: URL) -> (code: String?, state: String?, error: String?, errorDescription: String?)
    {
        let components = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false)
        let code = components?.queryItems?.first(where: { $0.name == "code" })?.value
        let state = components?.queryItems?.first(where: { $0.name == "state" })?.value
        let error = components?.queryItems?.first(where: { $0.name == "error" })?.value
        let errorDescription = components?.queryItems?.first(where: { $0.name == "error_description" })?.value
        return (code, state, error, errorDescription)
    }

    static func exchangeCode(
        code: String,
        verifier: String,
        session: URLSession = .shared) async throws -> OpenAIOAuthSubTokenSet
    {
        let trimmedCode = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedCode.isEmpty else {
            throw OpenAIOAuthSubClientError.callbackMissingCode
        }
        return try await self.performTokenRequest(
            parameters: [
                "grant_type": "authorization_code",
                "client_id": Self.clientID,
                "code": trimmedCode,
                "code_verifier": verifier,
                "redirect_uri": Self.redirectURI,
            ],
            fallbackRefreshToken: nil,
            session: session)
    }

    static func refresh(
        refreshToken: String,
        session: URLSession = .shared) async throws -> OpenAIOAuthSubTokenSet
    {
        let trimmed = refreshToken.trimmingCharacters(in: .whitespacesAndNewlines)
        return try await self.performTokenRequest(
            parameters: [
                "grant_type": "refresh_token",
                "refresh_token": trimmed,
                "client_id": Self.clientID,
            ],
            fallbackRefreshToken: trimmed,
            session: session)
    }

    static func fetchModelIDs(
        accessToken: String,
        session: URLSession = .shared) async throws -> [String]
    {
        if !self.extractAccountID(accessToken: accessToken).isEmpty {
            return Self.codexModelFallbackIDs
        }

        var request = URLRequest(url: Self.modelsURL)
        request.httpMethod = "GET"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw OpenAIOAuthSubClientError.invalidModelsResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            let text = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            throw OpenAIOAuthSubClientError.modelsFetchFailed(status: http.statusCode, message: text)
        }

        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let dataEntries = root["data"] as? [Any]
        else {
            throw OpenAIOAuthSubClientError.invalidModelsResponse
        }

        let ids = dataEntries.compactMap { entry -> String? in
            guard let dict = entry as? [String: Any],
                  let id = dict["id"] as? String
            else {
                return nil
            }
            let trimmed = id.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }

        return Array(Set(ids)).sorted()
    }

    static func preferredModelID(from modelIDs: [String]) -> String? {
        let preferred = [
            "gpt-5.3-codex",
            "gpt-5.2-codex",
            "gpt-5.1-codex",
            "gpt-5.3",
            "gpt-5.2",
        ]
        for candidate in preferred where modelIDs.contains(candidate) {
            return candidate
        }
        return modelIDs.first
    }

    // MARK: - Private

    private static func performTokenRequest(
        parameters: [String: String],
        fallbackRefreshToken: String?,
        session: URLSession) async throws -> OpenAIOAuthSubTokenSet
    {
        var request = URLRequest(url: Self.tokenURL)
        request.httpMethod = "POST"
        request.httpBody = self.formEncoded(parameters).data(using: .utf8)
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw OpenAIOAuthSubClientError.invalidTokenResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            let text = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            throw OpenAIOAuthSubClientError.tokenExchangeFailed(status: http.statusCode, message: text)
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let accessToken = json["access_token"] as? String
        else {
            throw OpenAIOAuthSubClientError.invalidTokenResponse
        }

        let refreshToken = (json["refresh_token"] as? String) ?? fallbackRefreshToken ?? ""
        guard !refreshToken.isEmpty else {
            throw OpenAIOAuthSubClientError.invalidTokenResponse
        }

        let expiresInSeconds = self.readDouble(json["expires_in"]) ?? 0
        guard expiresInSeconds > 0 else {
            throw OpenAIOAuthSubClientError.invalidTokenResponse
        }

        let accountID = self.extractAccountID(accessToken: accessToken)
        guard !accountID.isEmpty else {
            throw OpenAIOAuthSubClientError.missingAccountID
        }

        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        let expiresAtMs = nowMs + Int64(expiresInSeconds * 1000)
        return OpenAIOAuthSubTokenSet(
            accessToken: accessToken,
            refreshToken: refreshToken,
            expiresAtMs: expiresAtMs,
            accountID: accountID)
    }

    private static func readDouble(_ raw: Any?) -> Double? {
        if let value = raw as? Double { return value }
        if let value = raw as? Int { return Double(value) }
        if let value = raw as? NSNumber { return value.doubleValue }
        if let value = raw as? String { return Double(value) }
        return nil
    }

    private static func extractAccountID(accessToken: String) -> String {
        let segments = accessToken.split(separator: ".")
        guard segments.count == 3 else { return "" }
        guard let payloadData = self.decodeBase64URL(String(segments[1])),
              let payload = try? JSONSerialization.jsonObject(with: payloadData) as? [String: Any],
              let auth = payload[Self.jwtClaimPath] as? [String: Any],
              let accountID = auth["chatgpt_account_id"] as? String
        else {
            return ""
        }
        return accountID.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func decodeBase64URL(_ raw: String) -> Data? {
        var normalized = raw
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        switch normalized.count % 4 {
        case 0:
            break
        case 2:
            normalized += "=="
        case 3:
            normalized += "="
        default:
            return nil
        }
        return Data(base64Encoded: normalized)
    }

    private static func formEncoded(_ values: [String: String]) -> String {
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        return values
            .map { key, value in
                let encodedKey = key.addingPercentEncoding(withAllowedCharacters: allowed) ?? key
                let encodedValue = value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
                return "\(encodedKey)=\(encodedValue)"
            }
            .joined(separator: "&")
    }

    private static func randomVerifier() throws -> String {
        let data = try self.randomData(count: 32)
        return self.base64URL(data)
    }

    private static func randomHex(bytes count: Int) throws -> String {
        let data = try self.randomData(count: count)
        return data.map { String(format: "%02x", $0) }.joined()
    }

    private static func randomData(count: Int) throws -> Data {
        var bytes = [UInt8](repeating: 0, count: count)
        let status = SecRandomCopyBytes(kSecRandomDefault, count, &bytes)
        guard status == errSecSuccess else {
            throw OpenAIOAuthSubClientError.cryptoUnavailable(status)
        }
        return Data(bytes)
    }

    private static func sha256Base64URL(_ raw: String) -> String {
        let digest = SHA256.hash(data: Data(raw.utf8))
        return self.base64URL(Data(digest))
    }

    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

struct SavedLLMProvider: Codable, Identifiable, Equatable, Sendable {
    var id: String
    var name: String
    var provider: GatewayLocalLLMProviderKind
    var baseURL: String
    /// API key is NOT persisted via Codable — stored in Keychain instead.
    var apiKey: String
    var model: String
    var toolCallingMode: GatewayLocalLLMToolCallingMode
    var transport: GatewayLocalLLMTransport
    var authMode: SavedLLMProviderAuthMode
    var oauthAccessExpiresAtMs: Int64?
    var oauthAccountID: String
    /// OAuth refresh token is NOT persisted via Codable — stored in Keychain.
    var oauthRefreshToken: String

    private enum CodingKeys: String, CodingKey {
        case id, name, provider, baseURL, model, toolCallingMode, transport
        case authMode, oauthAccessExpiresAtMs, oauthAccountID
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(String.self, forKey: .id)
        self.name = try c.decode(String.self, forKey: .name)
        self.provider = try c.decode(GatewayLocalLLMProviderKind.self, forKey: .provider)
        self.baseURL = try c.decode(String.self, forKey: .baseURL)
        self.model = try c.decode(String.self, forKey: .model)
        self.toolCallingMode = try c.decodeIfPresent(
            GatewayLocalLLMToolCallingMode.self,
            forKey: .toolCallingMode) ?? .auto
        self.transport = try c.decodeIfPresent(GatewayLocalLLMTransport.self, forKey: .transport) ?? .http
        let decodedAuthMode = try c.decodeIfPresent(
            SavedLLMProviderAuthMode.self,
            forKey: .authMode) ?? .apiKey
        self.authMode = self.provider == .openAICompatible ? decodedAuthMode : .apiKey
        self.oauthAccessExpiresAtMs = try c.decodeIfPresent(Int64.self, forKey: .oauthAccessExpiresAtMs)
        self.oauthAccountID = try c.decodeIfPresent(String.self, forKey: .oauthAccountID) ?? ""
        self.apiKey = "" // hydrated from Keychain by LLMProviderStore.load()
        self.oauthRefreshToken = "" // hydrated from Keychain by LLMProviderStore.load()
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        let normalizedAuthMode = self.provider == .openAICompatible ? self.authMode : .apiKey
        try c.encode(self.id, forKey: .id)
        try c.encode(self.name, forKey: .name)
        try c.encode(self.provider, forKey: .provider)
        try c.encode(self.baseURL, forKey: .baseURL)
        try c.encode(self.model, forKey: .model)
        try c.encode(self.toolCallingMode, forKey: .toolCallingMode)
        try c.encode(self.transport, forKey: .transport)
        try c.encode(normalizedAuthMode, forKey: .authMode)
        try c.encodeIfPresent(
            normalizedAuthMode == .openAIOAuthSub ? self.oauthAccessExpiresAtMs : nil,
            forKey: .oauthAccessExpiresAtMs)
        try c.encode(
            normalizedAuthMode == .openAIOAuthSub ? self.oauthAccountID : "",
            forKey: .oauthAccountID)
        // apiKey intentionally omitted — lives in Keychain
        // oauthRefreshToken intentionally omitted — lives in Keychain
    }

    init(
        id: String = UUID().uuidString,
        name: String = "",
        provider: GatewayLocalLLMProviderKind = .disabled,
        baseURL: String = "",
        apiKey: String = "",
        model: String = "",
        toolCallingMode: GatewayLocalLLMToolCallingMode = .auto,
        transport: GatewayLocalLLMTransport = .http,
        authMode: SavedLLMProviderAuthMode = .apiKey,
        oauthAccessExpiresAtMs: Int64? = nil,
        oauthAccountID: String = "",
        oauthRefreshToken: String = "")
    {
        self.id = id
        self.name = name
        self.provider = provider
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.model = model
        self.toolCallingMode = toolCallingMode
        self.transport = transport
        self.authMode = provider == .openAICompatible ? authMode : .apiKey
        self.oauthAccessExpiresAtMs = oauthAccessExpiresAtMs
        self.oauthAccountID = oauthAccountID
        self.oauthRefreshToken = oauthRefreshToken
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
    private static let refreshTokenAccountSuffix = ".openai-oauth.refresh"

    static func load(defaults: UserDefaults = .standard) -> [SavedLLMProvider] {
        guard let data = defaults.data(forKey: defaultsKey) else { return [] }
        var providers = (try? JSONDecoder().decode([SavedLLMProvider].self, from: data)) ?? []
        // Hydrate API keys from Keychain
        for i in providers.indices {
            providers[i].apiKey = KeychainStore.loadString(
                service: Self.keychainService,
                account: providers[i].id) ?? ""
            providers[i].oauthRefreshToken = KeychainStore.loadString(
                service: Self.keychainService,
                account: Self.oauthRefreshAccount(forProviderID: providers[i].id)) ?? ""
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

            let refreshToken = provider.oauthRefreshToken.trimmingCharacters(in: .whitespacesAndNewlines)
            let refreshAccount = Self.oauthRefreshAccount(forProviderID: provider.id)
            if provider.provider == .openAICompatible,
               provider.authMode == .openAIOAuthSub,
               !refreshToken.isEmpty
            {
                _ = KeychainStore.saveString(refreshToken, service: Self.keychainService, account: refreshAccount)
            } else {
                _ = KeychainStore.delete(service: Self.keychainService, account: refreshAccount)
            }
        }
        // Encode without apiKey (excluded by CodingKeys)
        guard let data = try? JSONEncoder().encode(providers) else { return }
        defaults.set(data, forKey: Self.defaultsKey)
    }

    /// Remove a provider's Keychain entry when the provider is deleted.
    static func deleteAPIKey(forProviderID id: String) {
        _ = KeychainStore.delete(service: Self.keychainService, account: id)
        _ = KeychainStore.delete(service: Self.keychainService, account: Self.oauthRefreshAccount(forProviderID: id))
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

    @MainActor
    static func refreshOpenAIOAuthIfNeeded(_ provider: SavedLLMProvider) async throws -> SavedLLMProvider {
        guard provider.provider == .openAICompatible,
              provider.authMode == .openAIOAuthSub
        else {
            return provider
        }

        let refreshToken = provider.oauthRefreshToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !refreshToken.isEmpty else {
            return provider
        }

        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        let refreshSkewMs: Int64 = 90_000
        if let expiry = provider.oauthAccessExpiresAtMs,
           expiry > nowMs + refreshSkewMs,
           !provider.apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            return provider
        }

        let refreshed = try await OpenAIOAuthSubClient.refresh(refreshToken: refreshToken)
        var updated = provider
        updated.apiKey = refreshed.accessToken
        updated.oauthRefreshToken = refreshed.refreshToken
        updated.oauthAccessExpiresAtMs = refreshed.expiresAtMs
        updated.oauthAccountID = refreshed.accountID
        return updated
    }

    private static func oauthRefreshAccount(forProviderID id: String) -> String {
        "\(id)\(Self.refreshTokenAccountSuffix)"
    }
}

#endif
