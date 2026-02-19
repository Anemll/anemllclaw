import Foundation

public enum GatewayLocalLLMProviderKind: String, Codable, Sendable, Equatable {
    case disabled
    case openAICompatible = "openai-compatible"
    case anthropicCompatible = "anthropic-compatible"
    case minimaxCompatible = "minimax-compatible"
    case grokCompatible = "grok-compatible"
}

public struct GatewayLocalLLMConfig: Codable, Sendable, Equatable {
    public let provider: GatewayLocalLLMProviderKind
    public let baseURL: URL?
    public let apiKey: String?
    public let model: String?
    public let systemPrompt: String?
    public let temperature: Double?
    public let maxOutputTokens: Int?

    public init(
        provider: GatewayLocalLLMProviderKind = .disabled,
        baseURL: URL? = nil,
        apiKey: String? = nil,
        model: String? = nil,
        systemPrompt: String? = nil,
        temperature: Double? = nil,
        maxOutputTokens: Int? = nil)
    {
        self.provider = provider
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.model = model
        self.systemPrompt = systemPrompt
        self.temperature = temperature
        self.maxOutputTokens = maxOutputTokens
    }

    public var isConfigured: Bool {
        guard self.provider != .disabled else { return false }
        guard self.baseURL != nil else { return false }
        guard let apiKey = self.apiKey?.trimmingCharacters(in: .whitespacesAndNewlines), !apiKey.isEmpty else {
            return false
        }
        guard let model = self.model?.trimmingCharacters(in: .whitespacesAndNewlines), !model.isEmpty else {
            return false
        }
        return true
    }
}

public struct GatewayLocalLLMMessage: Sendable, Equatable {
    public let role: String
    public let text: String

    public init(role: String, text: String) {
        self.role = role
        self.text = text
    }
}

public enum GatewayLocalLLMToolMessageRole: String, Codable, Sendable, Equatable {
    case system
    case user
    case assistant
    case tool
}

public struct GatewayLocalLLMToolCall: Sendable, Codable, Equatable {
    public let id: String
    public let name: String
    public let argumentsJSON: String

    public init(id: String, name: String, argumentsJSON: String) {
        self.id = id
        self.name = name
        self.argumentsJSON = argumentsJSON
    }
}

public struct GatewayLocalLLMToolMessage: Sendable, Codable, Equatable {
    public let role: GatewayLocalLLMToolMessageRole
    public let text: String?
    public let toolCallID: String?
    public let name: String?
    public let toolCalls: [GatewayLocalLLMToolCall]

    public init(
        role: GatewayLocalLLMToolMessageRole,
        text: String? = nil,
        toolCallID: String? = nil,
        name: String? = nil,
        toolCalls: [GatewayLocalLLMToolCall] = [])
    {
        self.role = role
        self.text = text
        self.toolCallID = toolCallID
        self.name = name
        self.toolCalls = toolCalls
    }
}

public struct GatewayLocalLLMToolDefinition: Sendable, Codable, Equatable {
    public let name: String
    public let description: String
    public let parameters: GatewayJSONValue

    public init(name: String, description: String, parameters: GatewayJSONValue) {
        self.name = name
        self.description = description
        self.parameters = parameters
    }
}

public struct GatewayLocalLLMToolRequest: Sendable, Codable, Equatable {
    public let messages: [GatewayLocalLLMToolMessage]
    public let tools: [GatewayLocalLLMToolDefinition]
    public let thinkingLevel: String?
    public let systemPrompt: String?

    public init(
        messages: [GatewayLocalLLMToolMessage],
        tools: [GatewayLocalLLMToolDefinition],
        thinkingLevel: String? = nil,
        systemPrompt: String? = nil)
    {
        self.messages = messages
        self.tools = tools
        self.thinkingLevel = thinkingLevel
        self.systemPrompt = systemPrompt
    }
}

public struct GatewayLocalLLMToolResponse: Sendable, Codable, Equatable {
    public let text: String
    public let toolCalls: [GatewayLocalLLMToolCall]
    public let model: String
    public let provider: GatewayLocalLLMProviderKind
    public let usageInputTokens: Int?
    public let usageOutputTokens: Int?

    public init(
        text: String,
        toolCalls: [GatewayLocalLLMToolCall],
        model: String,
        provider: GatewayLocalLLMProviderKind,
        usageInputTokens: Int? = nil,
        usageOutputTokens: Int? = nil)
    {
        self.text = text
        self.toolCalls = toolCalls
        self.model = model
        self.provider = provider
        self.usageInputTokens = usageInputTokens
        self.usageOutputTokens = usageOutputTokens
    }
}

public struct GatewayLocalLLMRequest: Sendable, Equatable {
    public let messages: [GatewayLocalLLMMessage]
    public let thinkingLevel: String?
    public let systemPrompt: String?

    public init(
        messages: [GatewayLocalLLMMessage],
        thinkingLevel: String? = nil,
        systemPrompt: String? = nil)
    {
        self.messages = messages
        self.thinkingLevel = thinkingLevel
        self.systemPrompt = systemPrompt
    }
}

public struct GatewayLocalLLMResponse: Sendable, Equatable {
    public let text: String
    public let model: String
    public let provider: GatewayLocalLLMProviderKind
    public let usageInputTokens: Int?
    public let usageOutputTokens: Int?

    public init(
        text: String,
        model: String,
        provider: GatewayLocalLLMProviderKind,
        usageInputTokens: Int? = nil,
        usageOutputTokens: Int? = nil)
    {
        self.text = text
        self.model = model
        self.provider = provider
        self.usageInputTokens = usageInputTokens
        self.usageOutputTokens = usageOutputTokens
    }
}

public enum GatewayLocalLLMProviderError: Error, Sendable, Equatable {
    case notConfigured
    case invalidRequest(String)
    case httpError(status: Int, message: String)
    case invalidResponse(String)
}

public protocol GatewayLocalLLMProvider: Sendable {
    var kind: GatewayLocalLLMProviderKind { get }
    var model: String { get }
    func complete(_ request: GatewayLocalLLMRequest) async throws -> GatewayLocalLLMResponse
}

public protocol GatewayLocalLLMToolCallableProvider: GatewayLocalLLMProvider {
    func completeWithTools(_ request: GatewayLocalLLMToolRequest) async throws -> GatewayLocalLLMToolResponse
}

public enum GatewayLocalLLMProviderFactory {
    public static func make(
        config: GatewayLocalLLMConfig,
        session: URLSession = URLSession(configuration: .ephemeral)) -> (any GatewayLocalLLMProvider)?
    {
        guard config.isConfigured else { return nil }
        switch config.provider {
        case .disabled:
            return nil
        case .openAICompatible:
            return GatewayOpenAICompatibleLLMProvider(config: config, session: session)
        case .anthropicCompatible:
            return GatewayAnthropicCompatibleLLMProvider(config: config, session: session)
        case .minimaxCompatible:
            return GatewayOpenAICompatibleLLMProvider(
                config: config,
                session: session,
                kind: .minimaxCompatible)
        case .grokCompatible:
            return GatewayOpenAICompatibleLLMProvider(
                config: config,
                session: session,
                kind: .grokCompatible)
        }
    }
}

public actor GatewayOpenAICompatibleLLMProvider: GatewayLocalLLMToolCallableProvider {
    public let kind: GatewayLocalLLMProviderKind
    public let model: String

    private static let openAIRoleSystem = "system"
    private static let openAIRoleUser = "user"
    private static let openAIRoleAssistant = "assistant"
    private static let openAIRoleTool = "tool"
    private static let openAISupportedRoles: Set<String> = [
        openAIRoleSystem,
        openAIRoleUser,
        openAIRoleAssistant,
        openAIRoleTool,
    ]
    private static let minimaxCanonicalModelIDs: [String: String] = [
        "minimax-m2.1": "MiniMax-M2.1",
        "minimax-m2.1-lightning": "MiniMax-M2.1-lightning",
        "minimax-m2.5": "MiniMax-M2.5",
        "minimax-m2.5-lightning": "MiniMax-M2.5-Lightning",
    ]

    private let config: GatewayLocalLLMConfig
    private let endpointURL: URL
    private let session: URLSession

    public init(
        config: GatewayLocalLLMConfig,
        session: URLSession = URLSession(configuration: .ephemeral),
        kind: GatewayLocalLLMProviderKind = .openAICompatible)
    {
        self.config = config
        self.kind = kind
        self.model = Self.normalizedModelName(config.model ?? "", for: kind)
        let defaultEndpoint = Self.defaultEndpointURL(for: kind)
        self.endpointURL = Self.resolveEndpoint(baseURL: config.baseURL, defaultEndpoint: defaultEndpoint)
        self.session = session
    }

    static func normalizedModelName(_ rawModel: String, for provider: GatewayLocalLLMProviderKind) -> String {
        let trimmedModel = rawModel.trimmingCharacters(in: .whitespacesAndNewlines)
        guard provider == .minimaxCompatible, !trimmedModel.isEmpty else {
            return trimmedModel
        }

        let loweredModel = trimmedModel
            .lowercased()
            .replacingOccurrences(of: "minmax/", with: "minimax/")
        var candidates: [String] = [loweredModel]
        if let slashIndex = loweredModel.lastIndex(of: "/") {
            candidates.append(String(loweredModel[loweredModel.index(after: slashIndex)...]))
        }

        for candidate in candidates {
            let normalizedCandidate = candidate.replacingOccurrences(of: "minmax-", with: "minimax-")
            if let canonical = Self.minimaxCanonicalModelIDs[normalizedCandidate] {
                return canonical
            }
        }
        return trimmedModel
    }

    public func complete(_ request: GatewayLocalLLMRequest) async throws -> GatewayLocalLLMResponse {
        guard let apiKey = self.config.apiKey?.trimmingCharacters(in: .whitespacesAndNewlines), !apiKey.isEmpty else {
            throw GatewayLocalLLMProviderError.notConfigured
        }

        var payloadMessages: [[String: Any]] = []
        if let systemPrompt = (request.systemPrompt ?? self.config.systemPrompt)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !systemPrompt.isEmpty
        {
            self.appendOpenAIMessage(
                role: Self.openAIRoleSystem,
                text: systemPrompt,
                into: &payloadMessages)
        }
        for message in request.messages {
            self.appendOpenAIMessage(role: message.role, text: message.text, into: &payloadMessages)
        }

        var body: [String: Any] = [
            "model": self.model,
            "messages": payloadMessages,
            "stream": false,
        ]
        if let temperature = self.config.temperature {
            body["temperature"] = temperature
        }
        if let maxTokens = self.config.maxOutputTokens {
            body["max_tokens"] = max(1, maxTokens)
        }

        var urlRequest = URLRequest(url: self.endpointURL)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        urlRequest.httpBody = try Self.makeJSONBody(body)

        let (data, response) = try await self.session.data(for: urlRequest)
        let httpResponse = response as? HTTPURLResponse
        if let statusCode = httpResponse?.statusCode, !(200...299).contains(statusCode) {
            throw GatewayLocalLLMProviderError.httpError(
                status: statusCode,
                message: Self.errorText(data))
        }

        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw GatewayLocalLLMProviderError.invalidResponse("openai-compatible response is not a JSON object")
        }
        guard let choices = root["choices"] as? [[String: Any]],
              let firstChoice = choices.first,
              let message = firstChoice["message"] as? [String: Any]
        else {
            throw GatewayLocalLLMProviderError.invalidResponse("openai-compatible response missing choices[0].message")
        }

        let text = Self.readOpenAIContent(message["content"])
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw GatewayLocalLLMProviderError.invalidResponse("openai-compatible response content is empty")
        }

        let usage = root["usage"] as? [String: Any]
        let input = Self.readInt(usage?["prompt_tokens"])
        let output = Self.readInt(usage?["completion_tokens"])
        return GatewayLocalLLMResponse(
            text: trimmed,
            model: self.model,
            provider: self.kind,
            usageInputTokens: input,
            usageOutputTokens: output)
    }

    public func completeWithTools(_ request: GatewayLocalLLMToolRequest) async throws -> GatewayLocalLLMToolResponse {
        guard let apiKey = self.config.apiKey?.trimmingCharacters(in: .whitespacesAndNewlines), !apiKey.isEmpty else {
            throw GatewayLocalLLMProviderError.notConfigured
        }
        guard !request.messages.isEmpty else {
            throw GatewayLocalLLMProviderError.invalidRequest("at least one message is required")
        }

        var payloadMessages: [[String: Any]] = []
        if let systemPrompt = (request.systemPrompt ?? self.config.systemPrompt)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !systemPrompt.isEmpty
        {
            self.appendOpenAIMessage(
                role: Self.openAIRoleSystem,
                text: systemPrompt,
                into: &payloadMessages)
        }

        for message in request.messages {
            switch message.role {
            case .system:
                self.appendOpenAIMessage(
                    role: GatewayLocalLLMToolMessageRole.system.rawValue,
                    text: message.text ?? "",
                    into: &payloadMessages)
            case .user:
                payloadMessages.append([
                    "role": Self.openAIRoleUser,
                    "content": message.text ?? "",
                ])
            case .assistant:
                var item: [String: Any] = [
                    "role": Self.openAIRoleAssistant,
                ]
                item["content"] = message.text ?? ""
                if !message.toolCalls.isEmpty {
                    item["tool_calls"] = message.toolCalls.map { toolCall in
                        [
                            "id": toolCall.id,
                            "type": "function",
                            "function": [
                                "name": toolCall.name,
                                "arguments": toolCall.argumentsJSON,
                            ],
                        ] as [String: Any]
                    }
                }
                payloadMessages.append(item)
            case .tool:
                var item: [String: Any] = [
                    "role": Self.openAIRoleTool,
                    "content": message.text ?? "",
                ]
                if let toolCallID = message.toolCallID, !toolCallID.isEmpty {
                    item["tool_call_id"] = toolCallID
                }
                if let name = message.name, !name.isEmpty {
                    item["name"] = name
                }
                payloadMessages.append(item)
            }
        }

        var body: [String: Any] = [
            "model": self.model,
            "messages": payloadMessages,
            "stream": false,
            "tool_choice": "auto",
        ]
        if !request.tools.isEmpty {
            body["tools"] = request.tools.map { tool in
                [
                    "type": "function",
                    "function": [
                        "name": tool.name,
                        "description": tool.description,
                        "parameters": tool.parameters.foundationJSONObjectValue ?? [:],
                    ] as [String: Any],
                ] as [String: Any]
            }
        }
        if let temperature = self.config.temperature {
            body["temperature"] = temperature
        }
        if let maxTokens = self.config.maxOutputTokens {
            body["max_tokens"] = max(1, maxTokens)
        }

        var urlRequest = URLRequest(url: self.endpointURL)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        urlRequest.httpBody = try Self.makeJSONBody(body)

        let (data, response) = try await self.session.data(for: urlRequest)
        let httpResponse = response as? HTTPURLResponse
        if let statusCode = httpResponse?.statusCode, !(200...299).contains(statusCode) {
            throw GatewayLocalLLMProviderError.httpError(
                status: statusCode,
                message: Self.errorText(data))
        }

        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw GatewayLocalLLMProviderError.invalidResponse("openai-compatible response is not a JSON object")
        }
        guard let choices = root["choices"] as? [[String: Any]],
              let firstChoice = choices.first,
              let message = firstChoice["message"] as? [String: Any]
        else {
            throw GatewayLocalLLMProviderError.invalidResponse("openai-compatible response missing choices[0].message")
        }

        let text = Self.readOpenAIContent(message["content"]).trimmingCharacters(in: .whitespacesAndNewlines)
        let toolCalls = Self.readOpenAIToolCalls(message["tool_calls"])

        if text.isEmpty, toolCalls.isEmpty {
            throw GatewayLocalLLMProviderError.invalidResponse(
                "openai-compatible response missing both content and tool calls")
        }

        let usage = root["usage"] as? [String: Any]
        let input = Self.readInt(usage?["prompt_tokens"])
        let output = Self.readInt(usage?["completion_tokens"])
        return GatewayLocalLLMToolResponse(
            text: text,
            toolCalls: toolCalls,
            model: self.model,
            provider: self.kind,
            usageInputTokens: input,
            usageOutputTokens: output)
    }

    private var shouldRemapSystemRole: Bool {
        self.kind == .minimaxCompatible
    }

    private func appendOpenAIMessage(role rawRole: String, text: String, into payloadMessages: inout [[String: Any]]) {
        let normalizedRole = self.normalizeOpenAIRole(rawRole)
        let content = self.normalizeOpenAIContent(rawRole: rawRole, text: text)
        payloadMessages.append([
            "role": normalizedRole,
            "content": content,
        ])
    }

    private func normalizeOpenAIRole(_ rawRole: String) -> String {
        let role = rawRole
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let resolvedRole: String = Self.openAISupportedRoles.contains(role) ? role : Self.openAIRoleUser
        if self.shouldRemapSystemRole, resolvedRole == Self.openAIRoleSystem {
            return Self.openAIRoleUser
        }
        return resolvedRole
    }

    private func normalizeOpenAIContent(rawRole: String, text: String) -> String {
        let role = rawRole
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard self.shouldRemapSystemRole, role == Self.openAIRoleSystem else {
            return text
        }
        return "System instruction:\n\(text)"
    }

    private static func defaultEndpointURL(for provider: GatewayLocalLLMProviderKind) -> URL {
        switch provider {
        case .minimaxCompatible:
            return URL(string: "https://api.minimax.io/v1/chat/completions")!
        case .grokCompatible:
            return URL(string: "https://api.x.ai/v1/chat/completions")!
        case .disabled, .openAICompatible, .anthropicCompatible:
            return URL(string: "https://api.openai.com/v1/chat/completions")!
        }
    }

    private static func resolveEndpoint(baseURL: URL?, defaultEndpoint: URL) -> URL {
        guard let baseURL else {
            return defaultEndpoint
        }

        let path = baseURL.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if path.isEmpty {
            return baseURL.appendingPathComponent("v1/chat/completions")
        }
        if path.hasSuffix("chat/completions") {
            return baseURL
        }
        if path.hasSuffix("v1") {
            return baseURL.appendingPathComponent("chat/completions")
        }
        return baseURL.appendingPathComponent("v1/chat/completions")
    }
}

public actor GatewayAnthropicCompatibleLLMProvider: GatewayLocalLLMProvider {
    public let kind: GatewayLocalLLMProviderKind = .anthropicCompatible
    public let model: String

    private let config: GatewayLocalLLMConfig
    private let endpointURL: URL
    private let session: URLSession

    public init(config: GatewayLocalLLMConfig, session: URLSession = URLSession(configuration: .ephemeral)) {
        self.config = config
        self.model = config.model ?? ""
        self.endpointURL = Self.resolveEndpoint(baseURL: config.baseURL)
        self.session = session
    }

    public func complete(_ request: GatewayLocalLLMRequest) async throws -> GatewayLocalLLMResponse {
        guard let apiKey = self.config.apiKey?.trimmingCharacters(in: .whitespacesAndNewlines), !apiKey.isEmpty else {
            throw GatewayLocalLLMProviderError.notConfigured
        }

        let anthropicMessages: [[String: Any]] = request.messages.compactMap { message in
            let role = message.role == "assistant" ? "assistant" : "user"
            return [
                "role": role,
                "content": message.text,
            ]
        }
        guard !anthropicMessages.isEmpty else {
            throw GatewayLocalLLMProviderError.invalidRequest("at least one message is required")
        }

        var body: [String: Any] = [
            "model": self.model,
            "messages": anthropicMessages,
            "max_tokens": max(64, self.config.maxOutputTokens ?? 1_024),
        ]
        if let systemPrompt = request.systemPrompt ?? self.config.systemPrompt,
           !systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            body["system"] = systemPrompt
        }
        if let temperature = self.config.temperature {
            body["temperature"] = temperature
        }

        var urlRequest = URLRequest(url: self.endpointURL)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        urlRequest.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        urlRequest.httpBody = try Self.makeJSONBody(body)

        let (data, response) = try await self.session.data(for: urlRequest)
        let httpResponse = response as? HTTPURLResponse
        if let statusCode = httpResponse?.statusCode, !(200...299).contains(statusCode) {
            throw GatewayLocalLLMProviderError.httpError(
                status: statusCode,
                message: Self.errorText(data))
        }

        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw GatewayLocalLLMProviderError.invalidResponse(
                "anthropic-compatible response is not a JSON object")
        }

        let text = Self.readAnthropicText(root["content"])
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw GatewayLocalLLMProviderError.invalidResponse("anthropic-compatible response content is empty")
        }

        let usage = root["usage"] as? [String: Any]
        let input = Self.readInt(usage?["input_tokens"])
        let output = Self.readInt(usage?["output_tokens"])
        return GatewayLocalLLMResponse(
            text: trimmed,
            model: self.model,
            provider: self.kind,
            usageInputTokens: input,
            usageOutputTokens: output)
    }

    private static func resolveEndpoint(baseURL: URL?) -> URL {
        guard let baseURL else {
            return URL(string: "https://api.anthropic.com/v1/messages")!
        }

        let path = baseURL.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if path.isEmpty {
            return baseURL.appendingPathComponent("v1/messages")
        }
        if path.hasSuffix("messages") {
            return baseURL
        }
        if path.hasSuffix("v1") {
            return baseURL.appendingPathComponent("messages")
        }
        return baseURL.appendingPathComponent("v1/messages")
    }
}

private extension GatewayLocalLLMProvider {
    static func makeJSONBody(_ value: [String: Any]) throws -> Data {
        guard JSONSerialization.isValidJSONObject(value) else {
            throw GatewayLocalLLMProviderError.invalidRequest("request body contains non-JSON values")
        }
        return try JSONSerialization.data(withJSONObject: value)
    }

    static func readOpenAIContent(_ raw: Any?) -> String {
        if let text = raw as? String {
            return text
        }
        if let list = raw as? [[String: Any]] {
            let parts = list.compactMap { item in
                (item["text"] as? String) ?? (item["content"] as? String)
            }
            return parts.joined(separator: "\n")
        }
        return ""
    }

    static func readAnthropicText(_ raw: Any?) -> String {
        guard let blocks = raw as? [[String: Any]] else { return "" }
        let texts = blocks.compactMap { block -> String? in
            guard let type = block["type"] as? String, type == "text" else { return nil }
            return block["text"] as? String
        }
        return texts.joined(separator: "\n")
    }

    static func readInt(_ raw: Any?) -> Int? {
        if let value = raw as? Int {
            return value
        }
        if let value = raw as? NSNumber {
            return value.intValue
        }
        return nil
    }

    static func readOpenAIToolCalls(_ raw: Any?) -> [GatewayLocalLLMToolCall] {
        guard let calls = raw as? [[String: Any]] else {
            return []
        }
        return calls.compactMap { call in
            let id = (call["id"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard let function = call["function"] as? [String: Any] else {
                return nil
            }
            let name = (function["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !name.isEmpty else {
                return nil
            }
            let arguments: String
            if let rawArguments = function["arguments"] as? String {
                arguments = rawArguments
            } else {
                arguments = "{}"
            }
            return GatewayLocalLLMToolCall(
                id: id.isEmpty ? UUID().uuidString : id,
                name: name,
                argumentsJSON: arguments)
        }
    }

    static func errorText(_ data: Data) -> String {
        guard let text = String(data: data, encoding: .utf8),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            return "upstream returned an empty error body"
        }
        return text
    }
}
