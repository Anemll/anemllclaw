import Foundation

public enum GatewayLocalLLMProviderKind: String, Codable, Sendable, Equatable {
    case disabled
    case openAICompatible = "openai-compatible"
    case anthropicCompatible = "anthropic-compatible"
    case minimaxCompatible = "minimax-compatible"
    case grokCompatible = "grok-compatible"
}

public enum GatewayLocalLLMTransport: String, Codable, Sendable, Equatable {
    case http
    case websocket
}

public struct GatewayLocalLLMConfig: Codable, Sendable, Equatable {
    private static let minRequestTimeoutSeconds: TimeInterval = 10
    public static let defaultRequestTimeoutSeconds: TimeInterval = 1200
    private static let maxRequestTimeoutSeconds: TimeInterval = 7200

    public let provider: GatewayLocalLLMProviderKind
    public let baseURL: URL?
    public let apiKey: String?
    public let model: String?
    public let transport: GatewayLocalLLMTransport
    public let systemPrompt: String?
    public let temperature: Double?
    public let maxOutputTokens: Int?
    public let requestTimeoutSeconds: Double?

    public init(
        provider: GatewayLocalLLMProviderKind = .disabled,
        baseURL: URL? = nil,
        apiKey: String? = nil,
        model: String? = nil,
        transport: GatewayLocalLLMTransport = .http,
        systemPrompt: String? = nil,
        temperature: Double? = nil,
        maxOutputTokens: Int? = nil,
        requestTimeoutSeconds: Double? = nil)
    {
        self.provider = provider
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.model = model
        self.transport = transport
        self.systemPrompt = systemPrompt
        self.temperature = temperature
        self.maxOutputTokens = maxOutputTokens
        self.requestTimeoutSeconds = requestTimeoutSeconds
    }

    public var isConfigured: Bool {
        guard self.provider != .disabled else { return false }
        guard self.baseURL != nil else { return false }
        guard let model = self.model?.trimmingCharacters(in: .whitespacesAndNewlines), !model.isEmpty else {
            return false
        }
        return true
    }

    public var effectiveRequestTimeoutSeconds: TimeInterval {
        let configured = self.requestTimeoutSeconds ?? Self.defaultRequestTimeoutSeconds
        let normalized = configured.isFinite ? configured : Self.defaultRequestTimeoutSeconds
        return min(Self.maxRequestTimeoutSeconds, max(Self.minRequestTimeoutSeconds, normalized))
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
    /// Base64-encoded image data attached to a tool result (e.g. camera.snap).
    /// When present the image is sent as a vision-compatible content block
    /// alongside the text so multimodal LLMs can see it.
    public var imageDataBase64: String?
    /// MIME type of the image (e.g. "image/jpeg").
    public var imageMimeType: String?

    public init(
        role: GatewayLocalLLMToolMessageRole,
        text: String? = nil,
        toolCallID: String? = nil,
        name: String? = nil,
        toolCalls: [GatewayLocalLLMToolCall] = [],
        imageDataBase64: String? = nil,
        imageMimeType: String? = nil)
    {
        self.role = role
        self.text = text
        self.toolCallID = toolCallID
        self.name = name
        self.toolCalls = toolCalls
        self.imageDataBase64 = imageDataBase64
        self.imageMimeType = imageMimeType
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
    public let transport: GatewayLocalLLMTransport?
    public let usageInputTokens: Int?
    public let usageOutputTokens: Int?
    public let requestBodyBytes: Int?

    public init(
        text: String,
        toolCalls: [GatewayLocalLLMToolCall],
        model: String,
        provider: GatewayLocalLLMProviderKind,
        transport: GatewayLocalLLMTransport? = nil,
        usageInputTokens: Int? = nil,
        usageOutputTokens: Int? = nil,
        requestBodyBytes: Int? = nil)
    {
        self.text = text
        self.toolCalls = toolCalls
        self.model = model
        self.provider = provider
        self.transport = transport
        self.usageInputTokens = usageInputTokens
        self.usageOutputTokens = usageOutputTokens
        self.requestBodyBytes = requestBodyBytes
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
    public let transport: GatewayLocalLLMTransport?
    public let usageInputTokens: Int?
    public let usageOutputTokens: Int?
    public let requestBodyBytes: Int?

    public init(
        text: String,
        model: String,
        provider: GatewayLocalLLMProviderKind,
        transport: GatewayLocalLLMTransport? = nil,
        usageInputTokens: Int? = nil,
        usageOutputTokens: Int? = nil,
        requestBodyBytes: Int? = nil)
    {
        self.text = text
        self.model = model
        self.provider = provider
        self.transport = transport
        self.usageInputTokens = usageInputTokens
        self.usageOutputTokens = usageOutputTokens
        self.requestBodyBytes = requestBodyBytes
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
    private static let maxOpenAIToolNameLength = 64
    private static let openAIResponsesWebSocketBetaHeader = "responses_websockets=2026-02-06"
    private static let openAICodexResponsesHTTPBetaHeader = "responses=experimental"
    private static let openAICodexJWTClaimPath = "https://api.openai.com/auth"
    private static let defaultOpenAICodexInstructions = "You are a helpful AI assistant."

    private let config: GatewayLocalLLMConfig
    private let endpointURL: URL
    private let responsesEndpointURL: URL
    private let websocketResponsesEndpointURL: URL
    private let transport: GatewayLocalLLMTransport
    private let session: URLSession
    private var didLogWebSocketToolBypass = false

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
        let defaultResponsesEndpoint = Self.defaultResponsesEndpointURL(for: kind)
        self.responsesEndpointURL = Self.resolveResponsesEndpoint(
            baseURL: config.baseURL,
            defaultEndpoint: defaultResponsesEndpoint)
        self.websocketResponsesEndpointURL = Self.resolveWebSocketEndpoint(from: self.responsesEndpointURL)
        self.transport = config.transport
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

    static func makeOpenAIToolNameMap(toolNames: [String]) -> [String: String] {
        var map: [String: String] = [:]
        var usedWireNames = Set<String>()
        map.reserveCapacity(toolNames.count)
        usedWireNames.reserveCapacity(toolNames.count)

        for toolName in toolNames {
            let trimmedToolName = toolName.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedToolName.isEmpty else {
                continue
            }
            if map[trimmedToolName] != nil {
                continue
            }

            var candidate = Self.openAICompatibleToolName(trimmedToolName)
            var index = 2
            while usedWireNames.contains(candidate) {
                let suffix = "_\(index)"
                let baseLimit = max(1, Self.maxOpenAIToolNameLength - suffix.count)
                candidate = String(Self.openAICompatibleToolName(trimmedToolName).prefix(baseLimit)) + suffix
                index += 1
            }
            map[trimmedToolName] = candidate
            usedWireNames.insert(candidate)
        }
        return map
    }

    static func openAICompatibleToolName(_ rawName: String) -> String {
        let trimmed = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return "tool"
        }

        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-")
        var scalars: [UnicodeScalar] = []
        scalars.reserveCapacity(trimmed.unicodeScalars.count)
        for scalar in trimmed.unicodeScalars {
            if allowed.contains(scalar) {
                scalars.append(scalar)
            } else {
                scalars.append("_")
            }
        }

        var normalized = String(String.UnicodeScalarView(scalars))
        while normalized.contains("__") {
            normalized = normalized.replacingOccurrences(of: "__", with: "_")
        }
        normalized = normalized.trimmingCharacters(in: CharacterSet(charactersIn: "_"))
        if normalized.isEmpty {
            normalized = "tool"
        }

        if normalized.count > Self.maxOpenAIToolNameLength {
            normalized = String(normalized.prefix(Self.maxOpenAIToolNameLength))
        }
        return normalized
    }

    public func complete(_ request: GatewayLocalLLMRequest) async throws -> GatewayLocalLLMResponse {
        let apiKey = (self.config.apiKey ?? "").trimmingCharacters(in: .whitespacesAndNewlines)

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
        if self.shouldUseOpenAIResponsesWebSocket {
            Self.trace(
                "openai websocket request start model=\(self.model)"
                    + " endpoint=\(self.websocketResponsesEndpointURL.absoluteString)")
            do {
                let response = try await self.completeViaOpenAIResponsesWebSocket(
                    apiKey: apiKey,
                    payloadMessages: payloadMessages,
                    thinkingLevel: request.thinkingLevel)
                Self.trace(
                    "openai websocket request success model=\(self.model)"
                        + " inputTokens=\(Self.tokenLogValue(response.usageInputTokens))"
                        + " outputTokens=\(Self.tokenLogValue(response.usageOutputTokens))")
                return GatewayLocalLLMResponse(
                    text: response.text,
                    model: self.model,
                    provider: self.kind,
                    transport: .websocket,
                    usageInputTokens: response.usageInputTokens,
                    usageOutputTokens: response.usageOutputTokens,
                    requestBodyBytes: response.requestBodyBytes)
            } catch {
                Self.trace(
                    "openai websocket request failed model=\(self.model)"
                        + " reason=\(Self.errorLogMessage(error))"
                        + " fallback=http")
            }
        }

        if self.shouldUseResponsesAPI {
            let response = try await self.completeViaOpenAIResponsesHTTP(
                apiKey: apiKey,
                payloadMessages: payloadMessages,
                thinkingLevel: request.thinkingLevel)
            return GatewayLocalLLMResponse(
                text: response.text,
                model: self.model,
                provider: self.kind,
                transport: .http,
                usageInputTokens: response.usageInputTokens,
                usageOutputTokens: response.usageOutputTokens,
                requestBodyBytes: response.requestBodyBytes)
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
        urlRequest.timeoutInterval = self.config.effectiveRequestTimeoutSeconds
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        let jsonBody = try Self.makeJSONBody(body)
        let bodyBytes = jsonBody.count
        urlRequest.httpBody = jsonBody

        let (data, response) = try await self.session.data(for: urlRequest)
        let httpResponse = response as? HTTPURLResponse
        if let statusCode = httpResponse?.statusCode, !(200...299).contains(statusCode) {
            throw GatewayLocalLLMProviderError.httpError(
                status: statusCode,
                message: Self.errorText(data))
        }

        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw GatewayLocalLLMProviderError.invalidResponse(
                "openai-compatible response is not a JSON object: \(Self.responsePreview(data))")
        }
        guard let choices = root["choices"] as? [[String: Any]],
              let firstChoice = choices.first,
              let message = firstChoice["message"] as? [String: Any]
        else {
            throw GatewayLocalLLMProviderError.invalidResponse(
                "openai-compatible response missing choices[0].message: \(Self.responsePreview(data))")
        }

        let text = Self.readOpenAIContent(message["content"])
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw GatewayLocalLLMProviderError.invalidResponse(
                "openai-compatible response content is empty: \(Self.responsePreview(data))")
        }

        let usage = root["usage"] as? [String: Any]
        let input = Self.readInt(usage?["prompt_tokens"])
        let output = Self.readInt(usage?["completion_tokens"])
        return GatewayLocalLLMResponse(
            text: trimmed,
            model: self.model,
            provider: self.kind,
            transport: .http,
            usageInputTokens: input,
            usageOutputTokens: output,
            requestBodyBytes: bodyBytes)
    }

    public func completeWithTools(_ request: GatewayLocalLLMToolRequest) async throws -> GatewayLocalLLMToolResponse {
        let apiKey = (self.config.apiKey ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !request.messages.isEmpty else {
            throw GatewayLocalLLMProviderError.invalidRequest("at least one message is required")
        }
        if self.shouldUseResponsesAPI {
            if self.kind == .grokCompatible,
               Self.isGrokMultiAgentModel(self.model),
               !request.tools.isEmpty
            {
                throw GatewayLocalLLMProviderError.invalidResponse(
                    "grok multi-agent does not support client-side tools; use plain Responses API")
            }
            let toolNameMap = Self.makeOpenAIToolNameMap(toolNames: request.tools.map(\.name))
            let reverseToolNameMap = Dictionary(uniqueKeysWithValues: toolNameMap.map { ($1, $0) })
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
                            let wireName = toolNameMap[toolCall.name]
                                ?? Self.openAICompatibleToolName(toolCall.name)
                            return [
                                "id": toolCall.id,
                                "type": "function",
                                "function": [
                                    "name": wireName,
                                    "arguments": toolCall.argumentsJSON,
                                ],
                            ] as [String: Any]
                        }
                    }
                    payloadMessages.append(item)
                case .tool:
                    var item: [String: Any] = [
                        "role": "tool",
                    ]
                    if let b64 = message.imageDataBase64,
                       let mime = message.imageMimeType
                    {
                        var parts: [[String: Any]] = [
                            [
                                "type": "image_url",
                                "image_url": [
                                    "url": "data:\(mime);base64,\(b64)",
                                ],
                            ],
                        ]
                        let text = (message.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                        if !text.isEmpty {
                            parts.insert(["type": "text", "text": text], at: 0)
                        }
                        item["content"] = parts
                    } else {
                        item["content"] = message.text ?? ""
                    }
                    if let toolCallID = message.toolCallID, !toolCallID.isEmpty {
                        item["tool_call_id"] = toolCallID
                    }
                    if let name = message.name, !name.isEmpty {
                        let wireName = toolNameMap[name] ?? Self.openAICompatibleToolName(name)
                        item["name"] = wireName
                    }
                    payloadMessages.append(item)
                }
            }
            let responsesTools: [[String: Any]] = request.tools.map { tool in
                let wireName = toolNameMap[tool.name] ?? Self.openAICompatibleToolName(tool.name)
                let params = Self.normalizeOpenAIToolParameters(tool.parameters.foundationJSONObjectValue)
                return [
                    "type": "function",
                    "name": wireName,
                    "description": tool.description,
                    "parameters": params,
                ]
            }
            // Log tool-aware request details for diagnostics.
            let toolNames = responsesTools.compactMap { $0["name"] as? String }
            let hasImage = payloadMessages.contains { msg in
                if let arr = msg["content"] as? [[String: Any]] {
                    return arr.contains { ($0["type"] as? String) == "image_url" }
                }
                return false
            }
            let msgRoles = payloadMessages.compactMap { $0["role"] as? String }
            Self.trace(
                "\(self.responsesTraceLabel) completeWithTools"
                    + " tools=[\(toolNames.joined(separator: ", "))]"
                    + " messages=\(payloadMessages.count)"
                    + " roles=[\(msgRoles.joined(separator: ", "))]"
                    + " hasImage=\(hasImage)")
            if self.shouldUseOpenAIResponsesWebSocket {
                do {
                    let response = try await self.completeViaOpenAIResponsesWebSocket(
                        apiKey: apiKey,
                        payloadMessages: payloadMessages,
                        thinkingLevel: request.thinkingLevel,
                        tools: responsesTools,
                        reverseToolNameMap: reverseToolNameMap)
                    Self.trace(
                        "\(self.responsesTraceLabel) websocket completeWithTools result"
                            + " textLen=\(response.text.count)"
                            + " toolCalls=\(response.toolCalls.count)"
                            +
                            (response.toolCalls
                                .isEmpty ? "" : " calls=[\(response.toolCalls.map(\.name).joined(separator: ", "))]"))
                    return GatewayLocalLLMToolResponse(
                        text: response.text,
                        toolCalls: response.toolCalls,
                        model: self.model,
                        provider: self.kind,
                        transport: .websocket,
                        usageInputTokens: response.usageInputTokens,
                        usageOutputTokens: response.usageOutputTokens,
                        requestBodyBytes: response.requestBodyBytes)
                } catch {
                    Self.trace(
                        "\(self.responsesTraceLabel) websocket completeWithTools failed"
                            + " reason=\(Self.errorLogMessage(error))"
                            + " fallback=http")
                }
            }
            let response = try await self.completeViaOpenAIResponsesHTTP(
                apiKey: apiKey,
                payloadMessages: payloadMessages,
                thinkingLevel: request.thinkingLevel,
                tools: responsesTools,
                reverseToolNameMap: reverseToolNameMap)
            Self.trace(
                "\(self.responsesTraceLabel) completeWithTools result"
                    + " textLen=\(response.text.count)"
                    + " toolCalls=\(response.toolCalls.count)"
                    +
                    (response.toolCalls
                        .isEmpty ? "" : " calls=[\(response.toolCalls.map(\.name).joined(separator: ", "))]"))
            return GatewayLocalLLMToolResponse(
                text: response.text,
                toolCalls: response.toolCalls,
                model: self.model,
                provider: self.kind,
                transport: .http,
                usageInputTokens: response.usageInputTokens,
                usageOutputTokens: response.usageOutputTokens,
                requestBodyBytes: response.requestBodyBytes)
        }
        let toolNameMap = Self.makeOpenAIToolNameMap(toolNames: request.tools.map(\.name))
        let reverseToolNameMap = Dictionary(uniqueKeysWithValues: toolNameMap.map { ($1, $0) })

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
                        let wireName = toolNameMap[toolCall.name]
                            ?? Self.openAICompatibleToolName(toolCall.name)
                        return [
                            "id": toolCall.id,
                            "type": "function",
                            "function": [
                                "name": wireName,
                                "arguments": toolCall.argumentsJSON,
                            ],
                        ] as [String: Any]
                    }
                }
                payloadMessages.append(item)
            case .tool:
                var item: [String: Any] = [
                    "role": Self.openAIRoleTool,
                ]
                // When the tool result includes an image, send it as
                // a multipart content array so multimodal models can
                // see the image via a data URI.
                if let b64 = message.imageDataBase64,
                   let mime = message.imageMimeType
                {
                    var parts: [[String: Any]] = [
                        [
                            "type": "image_url",
                            "image_url": [
                                "url": "data:\(mime);base64,\(b64)",
                            ],
                        ],
                    ]
                    let text = (message.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                    if !text.isEmpty {
                        parts.insert(["type": "text", "text": text], at: 0)
                    }
                    item["content"] = parts
                } else {
                    item["content"] = message.text ?? ""
                }
                if let toolCallID = message.toolCallID, !toolCallID.isEmpty {
                    item["tool_call_id"] = toolCallID
                }
                if let name = message.name, !name.isEmpty {
                    let wireName = toolNameMap[name] ?? Self.openAICompatibleToolName(name)
                    item["name"] = wireName
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
                let wireName = toolNameMap[tool.name] ?? Self.openAICompatibleToolName(tool.name)
                let params = Self.normalizeOpenAIToolParameters(tool.parameters.foundationJSONObjectValue)
                return [
                    "type": "function",
                    "function": [
                        "name": wireName,
                        "description": tool.description,
                        "parameters": params,
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
        urlRequest.timeoutInterval = self.config.effectiveRequestTimeoutSeconds
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        let jsonBody = try Self.makeJSONBody(body)
        let bodyBytes = jsonBody.count
        urlRequest.httpBody = jsonBody

        let (data, response) = try await self.session.data(for: urlRequest)
        let httpResponse = response as? HTTPURLResponse
        if let statusCode = httpResponse?.statusCode, !(200...299).contains(statusCode) {
            throw GatewayLocalLLMProviderError.httpError(
                status: statusCode,
                message: Self.errorText(data))
        }

        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw GatewayLocalLLMProviderError.invalidResponse(
                "openai-compatible response is not a JSON object: \(Self.responsePreview(data))")
        }
        guard let choices = root["choices"] as? [[String: Any]],
              let firstChoice = choices.first,
              let message = firstChoice["message"] as? [String: Any]
        else {
            throw GatewayLocalLLMProviderError.invalidResponse(
                "openai-compatible response missing choices[0].message: \(Self.responsePreview(data))")
        }

        let text = Self.readOpenAIContent(message["content"]).trimmingCharacters(in: .whitespacesAndNewlines)
        let toolCalls = Self.readOpenAIToolCalls(
            message["tool_calls"],
            restoreNamesUsing: reverseToolNameMap)

        if text.isEmpty, toolCalls.isEmpty {
            throw GatewayLocalLLMProviderError.invalidResponse(
                "openai-compatible response missing both content and tool calls: \(Self.responsePreview(data))")
        }

        let usage = root["usage"] as? [String: Any]
        let input = Self.readInt(usage?["prompt_tokens"])
        let output = Self.readInt(usage?["completion_tokens"])
        return GatewayLocalLLMToolResponse(
            text: text,
            toolCalls: toolCalls,
            model: self.model,
            provider: self.kind,
            transport: .http,
            usageInputTokens: input,
            usageOutputTokens: output,
            requestBodyBytes: bodyBytes)
    }

    private struct OpenAIResponsesWebSocketResult {
        let text: String
        var toolCalls: [GatewayLocalLLMToolCall] = []
        let usageInputTokens: Int?
        let usageOutputTokens: Int?
        let requestBodyBytes: Int
    }

    private enum OpenAIResponsesWebSocketEventOutcome {
        case none
        case completed(usage: [String: Any]?)
        case failed(String)
    }

    private enum OpenAIResponsesWebSocketPayloadStyle: String {
        case nestedResponseCreate = "nested-response"
        case topLevelResponseCreate = "top-level"
    }

    private var shouldUseResponsesAPI: Bool {
        self.kind == .grokCompatible
            || (self.kind == .openAICompatible && self.isOpenAICodexBackend)
    }

    private var shouldUseOpenAIResponsesWebSocket: Bool {
        self.transport == .websocket && self.shouldUseResponsesAPI
    }

    private var shouldEnableResponsesParallelToolCalls: Bool {
        self.isOpenAICodexBackend || self.kind == .grokCompatible
    }

    private var responsesTraceLabel: String {
        switch self.kind {
        case .grokCompatible:
            "xai responses"
        case .openAICompatible:
            self.isOpenAICodexBackend ? "openai codex" : "openai responses"
        case .disabled, .anthropicCompatible, .minimaxCompatible:
            "responses"
        }
    }

    private var isOpenAICodexBackend: Bool {
        guard self.kind == .openAICompatible else {
            return false
        }
        let host = self.responsesEndpointURL.host?.lowercased() ?? ""
        guard host.hasSuffix("chatgpt.com") else {
            return false
        }
        let path = self.responsesEndpointURL.path
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            .lowercased()
        return path == "backend-api"
            || path.hasPrefix("backend-api/")
            || path == "backend-api/codex"
            || path == "backend-api/codex/responses"
    }

    private func completeViaOpenAIResponsesWebSocket(
        apiKey: String,
        payloadMessages: [[String: Any]],
        thinkingLevel: String?,
        tools: [[String: Any]] = [],
        reverseToolNameMap: [String: String] = [:]) async throws -> OpenAIResponsesWebSocketResult
    {
        var responsePayload = try self.makeOpenAIResponsesPayload(
            payloadMessages: payloadMessages,
            thinkingLevel: thinkingLevel,
            tools: tools)
        if self.kind == .grokCompatible {
            responsePayload.removeValue(forKey: "stream")
        }
        do {
            return try await self.sendOpenAIResponsesWebSocketRequest(
                apiKey: apiKey,
                responsePayload: responsePayload,
                payloadStyle: .topLevelResponseCreate,
                reverseToolNameMap: reverseToolNameMap)
        } catch {
            guard Self.shouldRetryWebSocketWithNestedPayload(after: error) else {
                throw error
            }
            Self.trace("openai websocket retrying with nested response.create payload")
            return try await self.sendOpenAIResponsesWebSocketRequest(
                apiKey: apiKey,
                responsePayload: responsePayload,
                payloadStyle: .nestedResponseCreate,
                reverseToolNameMap: reverseToolNameMap)
        }
    }

    private func completeViaOpenAIResponsesHTTP(
        apiKey: String,
        payloadMessages: [[String: Any]],
        thinkingLevel: String?,
        tools: [[String: Any]] = [],
        reverseToolNameMap: [String: String] = [:]) async throws -> OpenAIResponsesWebSocketResult
    {
        // OpenAI Responses API requires stream=true.
        // We use SSE streaming over HTTP and accumulate the result.
        var payload = try self.makeOpenAIResponsesPayload(
            payloadMessages: payloadMessages,
            thinkingLevel: thinkingLevel,
            tools: tools)
        payload["stream"] = true
        let jsonBody = try Self.makeJSONBody(payload)
        let bodyBytes = jsonBody.count
        Self.trace(
            "openai responses HTTP request"
                + " endpoint=\(self.responsesEndpointURL.absoluteString)"
                + " bodyBytes=\(bodyBytes)"
                + " tools=\(tools.count)"
                + " messages=\(payloadMessages.count)")

        var request = URLRequest(url: self.responsesEndpointURL)
        request.httpMethod = "POST"
        request.timeoutInterval = self.config.effectiveRequestTimeoutSeconds
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        if self.isOpenAICodexBackend {
            try self.applyOpenAICodexHeaders(
                to: &request,
                apiKey: apiKey,
                webSocket: false)
        }
        request.httpBody = jsonBody

        let (bytes, response) = try await self.session.bytes(for: request)
        let httpResponse = response as? HTTPURLResponse
        if let statusCode = httpResponse?.statusCode, !(200...299).contains(statusCode) {
            // Collect error body from stream.
            var errorChunks: [UInt8] = []
            for try await byte in bytes {
                errorChunks.append(byte)
            }
            let errorData = Data(errorChunks)
            throw GatewayLocalLLMProviderError.httpError(
                status: statusCode,
                message: Self.errorText(errorData))
        }

        // Parse SSE lines: each event is "data: <json>\n".
        var accumulated = ""
        var completedResponse: [String: Any]?
        var finalUsage: [String: Any]?

        sseLoop: for try await line in bytes.lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("data: ") else { continue }
            let jsonStr = String(trimmed.dropFirst(6))
            if jsonStr == "[DONE]" { break }
            guard let jsonData = jsonStr.data(using: .utf8),
                  let event = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any]
            else { continue }

            let outcome = Self.handleOpenAIResponsesWebSocketEvent(
                event,
                accumulated: &accumulated,
                completedResponse: &completedResponse)
            switch outcome {
            case let .completed(usage):
                finalUsage = usage
                break sseLoop
            case let .failed(message):
                throw GatewayLocalLLMProviderError.invalidResponse(
                    "openai responses stream error: \(message)")
            case .none:
                break
            }
        }

        let text = accumulated.trimmingCharacters(in: .whitespacesAndNewlines)
        // Extract tool calls from completed response (Responses API uses
        // output items with type "function_call").
        var toolCalls: [GatewayLocalLLMToolCall] = []
        if let completedResponse {
            toolCalls = Self.extractOpenAIResponsesToolCalls(
                from: completedResponse,
                restoreNamesUsing: reverseToolNameMap)
        }
        Self.trace(
            "openai responses HTTP result"
                + " textLen=\(text.count)"
                + " toolCalls=\(toolCalls.count)"
                + " hasCompletedResponse=\(completedResponse != nil)"
                + (toolCalls.isEmpty ? "" : " toolNames=\(toolCalls.map(\.name).joined(separator: ","))"))
        if text.isEmpty, toolCalls.isEmpty {
            throw GatewayLocalLLMProviderError.invalidResponse(
                "openai responses HTTP stream content is empty")
        }
        let input = Self.readInt(finalUsage?["input_tokens"]) ?? Self.readInt(finalUsage?["prompt_tokens"])
        let output = Self.readInt(finalUsage?["output_tokens"]) ?? Self.readInt(finalUsage?["completion_tokens"])
        return OpenAIResponsesWebSocketResult(
            text: text,
            toolCalls: toolCalls,
            usageInputTokens: input,
            usageOutputTokens: output,
            requestBodyBytes: bodyBytes)
    }

    private func sendOpenAIResponsesWebSocketRequest(
        apiKey: String,
        responsePayload: [String: Any],
        payloadStyle: OpenAIResponsesWebSocketPayloadStyle,
        reverseToolNameMap: [String: String] = [:]) async throws -> OpenAIResponsesWebSocketResult
    {
        let payload = Self.makeOpenAIResponsesWebSocketPayload(
            responsePayload: responsePayload,
            payloadStyle: payloadStyle)
        let payloadData = try Self.makeJSONBody(payload)
        let bodyBytes = payloadData.count
        guard let payloadText = String(data: payloadData, encoding: .utf8) else {
            throw GatewayLocalLLMProviderError.invalidRequest("failed to encode websocket payload")
        }

        var request = URLRequest(url: self.websocketResponsesEndpointURL)
        request.timeoutInterval = self.config.effectiveRequestTimeoutSeconds
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        if self.isOpenAICodexBackend {
            try self.applyOpenAICodexHeaders(
                to: &request,
                apiKey: apiKey,
                webSocket: true)
        } else if self.kind == .openAICompatible {
            request.setValue(Self.openAIResponsesWebSocketBetaHeader, forHTTPHeaderField: "OpenAI-Beta")
        }

        let socket = self.session.webSocketTask(with: request)
        socket.resume()
        defer {
            socket.cancel(with: .normalClosure, reason: nil)
        }

        Self.trace("openai websocket payload style=\(payloadStyle.rawValue)")
        try await socket.send(.string(payloadText))

        var accumulated = ""
        var completedResponse: [String: Any]?
        while true {
            let message = try await socket.receive()
            let frameText: String
            switch message {
            case let .string(text):
                frameText = text
            case let .data(data):
                frameText = String(data: data, encoding: .utf8) ?? ""
            @unknown default:
                continue
            }
            guard !frameText.isEmpty,
                  let frameData = frameText.data(using: .utf8),
                  let event = try? JSONSerialization.jsonObject(with: frameData) as? [String: Any]
            else {
                continue
            }

            switch Self.handleOpenAIResponsesWebSocketEvent(
                event,
                accumulated: &accumulated,
                completedResponse: &completedResponse)
            {
            case .none:
                continue
            case let .failed(message):
                throw GatewayLocalLLMProviderError.invalidResponse(message)
            case let .completed(usage):
                let text = accumulated.trimmingCharacters(in: .whitespacesAndNewlines)
                let toolCalls = Self.extractOpenAIResponsesToolCalls(
                    from: completedResponse ?? event,
                    restoreNamesUsing: reverseToolNameMap)
                guard !text.isEmpty || !toolCalls.isEmpty else {
                    throw GatewayLocalLLMProviderError.invalidResponse(
                        "openai websocket response content is empty")
                }
                let input = Self.readInt(usage?["input_tokens"]) ?? Self.readInt(usage?["prompt_tokens"])
                let output = Self.readInt(usage?["output_tokens"]) ?? Self.readInt(usage?["completion_tokens"])
                return OpenAIResponsesWebSocketResult(
                    text: text,
                    toolCalls: toolCalls,
                    usageInputTokens: input,
                    usageOutputTokens: output,
                    requestBodyBytes: bodyBytes)
            }
        }
    }

    private static func makeOpenAIResponsesWebSocketPayload(
        responsePayload: [String: Any],
        payloadStyle: OpenAIResponsesWebSocketPayloadStyle) -> [String: Any]
    {
        switch payloadStyle {
        case .nestedResponseCreate:
            return [
                "type": "response.create",
                "response": responsePayload,
            ]
        case .topLevelResponseCreate:
            var payload = responsePayload
            payload["type"] = "response.create"
            return payload
        }
    }

    private static func shouldRetryWebSocketWithNestedPayload(after error: Error) -> Bool {
        guard let providerError = error as? GatewayLocalLLMProviderError else {
            return false
        }
        guard case let .invalidResponse(message) = providerError else {
            return false
        }
        let normalized = message.lowercased()
        return normalized.contains("missing required parameter") && normalized.contains("response")
    }

    private func makeOpenAIResponsesPayload(
        payloadMessages: [[String: Any]],
        thinkingLevel: String?,
        tools: [[String: Any]] = []) throws -> [String: Any]
    {
        let includeSystemInInput = !self.isOpenAICodexBackend
        let input = Self.mapOpenAIMessagesToResponsesInput(
            payloadMessages,
            includeSystemMessages: includeSystemInInput)
        guard !input.isEmpty else {
            throw GatewayLocalLLMProviderError.invalidRequest("at least one message is required")
        }

        var payload: [String: Any] = [
            "model": self.model,
            "input": input,
            "stream": true,
        ]
        if self.isOpenAICodexBackend || self.kind == .grokCompatible {
            payload["store"] = false
        }
        if self.isOpenAICodexBackend {
            payload["instructions"] = Self.resolveOpenAICodexInstructions(from: payloadMessages)
            payload["text"] = ["verbosity": "medium"]
        }
        if !tools.isEmpty {
            payload["tools"] = tools
            payload["tool_choice"] = "auto"
            if self.shouldEnableResponsesParallelToolCalls {
                payload["parallel_tool_calls"] = true
            }
        }
        if let effort = self.resolveResponsesReasoningEffort(thinkingLevel) {
            if self.kind == .grokCompatible {
                if Self.grokSupportsReasoningEffort(self.model) {
                    payload["reasoning"] = ["effort": effort]
                }
            } else {
                payload["reasoning"] = [
                    "effort": effort,
                ]
            }
        }
        return payload
    }

    private func resolveResponsesReasoningEffort(_ thinkingLevel: String?) -> String? {
        if self.kind == .grokCompatible {
            return Self.resolveGrokReasoningEffort(thinkingLevel, model: self.model)
        }
        return Self.resolveReasoningEffort(
            thinkingLevel,
            preferXHighForCodex: self.isOpenAICodexBackend)
    }

    private static func mapOpenAIMessagesToResponsesInput(
        _ payloadMessages: [[String: Any]],
        includeSystemMessages: Bool = true) -> [[String: Any]]
    {
        var result: [[String: Any]] = []
        for message in payloadMessages {
            let rawRole = (message["role"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased() ?? Self.openAIRoleUser

            // Tool result → function_call_output item (Responses API format).
            if rawRole == "tool" {
                let callID = (message["tool_call_id"] as? String)?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let output = Self.readOpenAIContent(message["content"])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !callID.isEmpty {
                    result.append([
                        "type": "function_call_output",
                        "call_id": callID,
                        "output": output,
                    ])
                    // If the tool result has an image (multipart content),
                    // emit a user message with the image so the model can
                    // see it. function_call_output only supports text.
                    if let contentArray = message["content"] as? [[String: Any]] {
                        for part in contentArray {
                            let partType = (part["type"] as? String) ?? ""
                            if partType == "image_url",
                               let imgObj = part["image_url"] as? [String: Any],
                               let url = imgObj["url"] as? String
                            {
                                Self.trace(
                                    "mapResponses: emitting input_image from tool result"
                                        + " urlLen=\(url.count)")
                                result.append([
                                    "role": Self.openAIRoleUser,
                                    "content": [
                                        [
                                            "type": "input_image",
                                            "image_url": url,
                                        ],
                                    ],
                                ])
                            }
                        }
                    }
                    continue
                }
            }

            // Assistant with tool_calls → emit function_call items.
            if rawRole == Self.openAIRoleAssistant,
               let toolCalls = message["tool_calls"] as? [[String: Any]],
               !toolCalls.isEmpty
            {
                // Emit any assistant text first.
                let assistantText = Self.readOpenAIContent(message["content"])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !assistantText.isEmpty {
                    result.append([
                        "role": Self.openAIRoleAssistant,
                        "content": [
                            ["type": "output_text", "text": assistantText],
                        ],
                    ])
                }
                for tc in toolCalls {
                    guard let fn = tc["function"] as? [String: Any] else { continue }
                    let name = (fn["name"] as? String)?
                        .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    let callID = (tc["id"] as? String)?
                        .trimmingCharacters(in: .whitespacesAndNewlines) ?? UUID().uuidString
                    let arguments = (fn["arguments"] as? String) ?? "{}"
                    result.append([
                        "type": "function_call",
                        "name": name,
                        "call_id": callID,
                        "arguments": arguments,
                    ])
                }
                continue
            }

            // Responses API websocket payloads accept assistant history blocks as
            // output_text/refusal rather than input_text. Also normalize unknown
            // roles to user for compatibility.
            let role: String = switch rawRole {
            case Self.openAIRoleSystem, Self.openAIRoleUser, Self.openAIRoleAssistant:
                rawRole
            default:
                Self.openAIRoleUser
            }
            if role == Self.openAIRoleSystem, !includeSystemMessages {
                continue
            }
            let text = Self.readOpenAIContent(message["content"])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else {
                continue
            }
            let contentType = role == Self.openAIRoleAssistant ? "output_text" : "input_text"
            result.append([
                "role": role,
                "content": [
                    [
                        "type": contentType,
                        "text": text,
                    ],
                ],
            ])
        }
        return result
    }

    private static func resolveOpenAICodexInstructions(from payloadMessages: [[String: Any]]) -> String {
        let instructionBlocks = payloadMessages.compactMap { message -> String? in
            let role = (message["role"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            guard role == Self.openAIRoleSystem else {
                return nil
            }
            let text = Self.readOpenAIContent(message["content"])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? nil : text
        }
        if instructionBlocks.isEmpty {
            return Self.defaultOpenAICodexInstructions
        }
        return instructionBlocks.joined(separator: "\n\n")
    }

    private static func handleOpenAIResponsesWebSocketEvent(
        _ event: [String: Any],
        accumulated: inout String,
        completedResponse: inout [String: Any]?) -> OpenAIResponsesWebSocketEventOutcome
    {
        let type = (event["type"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() ?? ""
        switch type {
        case "response.output_text.delta":
            if let delta = event["delta"] as? String {
                accumulated += delta
            }
            return .none
        case "response.output_text.done":
            if accumulated.isEmpty, let textChunk = event["text"] as? String {
                accumulated = textChunk
            }
            return .none
        case "response.output_item.done":
            guard let item = event["item"] as? [String: Any] else { return .none }
            var output = completedResponse?["output"] as? [[String: Any]] ?? []
            output.append(item)
            var partialResponse = completedResponse ?? [:]
            partialResponse["output"] = output
            completedResponse = partialResponse
            if accumulated.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                accumulated = Self.extractOpenAIResponsesText(from: partialResponse)
            }
            return .none
        case "response.completed", "response.done":
            if let response = event["response"] as? [String: Any] {
                var mergedResponse = response
                let responseOutput = response["output"] as? [Any] ?? []
                if responseOutput.isEmpty, let streamedOutput = completedResponse?["output"] {
                    // The Codex backend may deliver output only through
                    // response.output_item.done and omit it from response.completed.
                    mergedResponse["output"] = streamedOutput
                }
                completedResponse = mergedResponse
            }
            if accumulated.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                if let completedResponse {
                    accumulated = Self.extractOpenAIResponsesText(from: completedResponse)
                }
                if accumulated.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    accumulated = Self.extractOpenAIResponsesText(from: event)
                }
            }
            let usage = (completedResponse?["usage"] as? [String: Any])
                ?? ((event["response"] as? [String: Any])?["usage"] as? [String: Any])
                ?? (event["usage"] as? [String: Any])
            return .completed(usage: usage)
        case "error", "response.failed":
            return .failed(
                Self.extractOpenAIResponsesErrorMessage(from: event)
                    ?? "openai websocket request failed")
        default:
            if type.hasSuffix(".delta"),
               let delta = event["delta"] as? String
            {
                accumulated += delta
            }
            return .none
        }
    }

    private static func extractOpenAIResponsesText(from object: [String: Any]) -> String {
        if let direct = object["output_text"] as? String, !direct.isEmpty {
            return direct
        }
        if let list = object["output_text"] as? [String], !list.isEmpty {
            return list.joined()
        }
        if let response = object["response"] as? [String: Any] {
            let nested = Self.extractOpenAIResponsesText(from: response)
            if !nested.isEmpty {
                return nested
            }
        }

        guard let output = object["output"] as? [Any] else {
            return ""
        }
        var chunks: [String] = []
        for entry in output {
            guard let item = entry as? [String: Any] else {
                continue
            }
            let itemType = (item["type"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased() ?? ""
            let role = (item["role"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased() ?? ""
            guard itemType == "message" || role == Self.openAIRoleAssistant else {
                continue
            }

            if let text = item["text"] as? String, !text.isEmpty {
                chunks.append(text)
            }
            guard let content = item["content"] as? [Any] else {
                continue
            }
            for blockRaw in content {
                guard let block = blockRaw as? [String: Any] else {
                    continue
                }
                let blockType = (block["type"] as? String)?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .lowercased() ?? ""
                if blockType == "output_text" || blockType == "text",
                   let blockText = block["text"] as? String,
                   !blockText.isEmpty
                {
                    chunks.append(blockText)
                }
            }
        }
        return chunks.joined()
    }

    /// Extract function_call items from a Responses API completed response.
    /// The `output` array may contain items with `type: "function_call"`.
    static func extractOpenAIResponsesToolCalls(
        from object: [String: Any],
        restoreNamesUsing reverseToolNameMap: [String: String] = [:]) -> [GatewayLocalLLMToolCall]
    {
        let root: [String: Any] = if let response = object["response"] as? [String: Any] {
            response
        } else {
            object
        }
        guard let output = root["output"] as? [[String: Any]] else {
            return []
        }
        return output.compactMap { item in
            let itemType = (item["type"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased() ?? ""
            guard itemType == "function_call" else { return nil }
            let wireName = (item["name"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !wireName.isEmpty else { return nil }
            let callID = (item["call_id"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                ?? UUID().uuidString
            let arguments = (item["arguments"] as? String) ?? "{}"
            let name = reverseToolNameMap[wireName] ?? wireName
            return GatewayLocalLLMToolCall(
                id: callID.isEmpty ? UUID().uuidString : callID,
                name: name,
                argumentsJSON: arguments)
        }
    }

    private static func extractOpenAIResponsesErrorMessage(from event: [String: Any]) -> String? {
        if let message = event["message"] as? String, !message.isEmpty {
            return message
        }
        if let error = event["error"] as? String, !error.isEmpty {
            return error
        }
        if let error = event["error"] as? [String: Any] {
            if let message = error["message"] as? String, !message.isEmpty {
                return message
            }
            if let code = error["code"] as? String, !code.isEmpty {
                return code
            }
        }
        if let response = event["response"] as? [String: Any],
           let error = response["error"] as? [String: Any],
           let message = error["message"] as? String,
           !message.isEmpty
        {
            return message
        }
        return nil
    }

    private func applyOpenAICodexHeaders(
        to request: inout URLRequest,
        apiKey: String,
        webSocket: Bool) throws
    {
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        let accountID = Self.extractOpenAICodexAccountID(fromToken: apiKey) ?? ""
        guard !accountID.isEmpty else {
            throw GatewayLocalLLMProviderError.invalidRequest(
                "OpenAI OAuth token is missing ChatGPT account ID.")
        }
        request.setValue(accountID, forHTTPHeaderField: "ChatGPT-Account-Id")
        request.setValue("pi-ios", forHTTPHeaderField: "originator")
        request.setValue(
            webSocket
                ? Self.openAIResponsesWebSocketBetaHeader
                : Self.openAICodexResponsesHTTPBetaHeader,
            forHTTPHeaderField: "OpenAI-Beta")
    }

    private static func extractOpenAICodexAccountID(fromToken token: String) -> String? {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        let segments = trimmed.split(separator: ".")
        guard segments.count == 3,
              let payloadData = Self.decodeBase64URL(String(segments[1])),
              let payload = try? JSONSerialization.jsonObject(with: payloadData) as? [String: Any],
              let auth = payload[Self.openAICodexJWTClaimPath] as? [String: Any],
              let accountID = auth["chatgpt_account_id"] as? String
        else {
            return nil
        }
        let normalized = accountID.trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized.isEmpty ? nil : normalized
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

    private static func errorLogMessage(_ error: Error) -> String {
        let text: String = if let providerError = error as? GatewayLocalLLMProviderError {
            switch providerError {
            case .notConfigured:
                "notConfigured"
            case let .invalidRequest(message):
                "invalidRequest: \(message)"
            case let .httpError(status, message):
                "httpError(\(status)): \(message)"
            case let .invalidResponse(message):
                "invalidResponse: \(message)"
            }
        } else {
            error.localizedDescription
        }
        return text
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func tokenLogValue(_ value: Int?) -> String {
        guard let value else { return "n/a" }
        return String(value)
    }

    private static func trace(_ message: String) {
        print("[OpenClawGatewayCore][LocalLLM] \(message)")
    }

    private static func resolveReasoningEffort(
        _ thinkingLevel: String?,
        preferXHighForCodex: Bool = false) -> String?
    {
        guard let thinkingLevel else {
            return nil
        }
        switch thinkingLevel
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        {
        case "minimal":
            return "minimal"
        case "low":
            return "low"
        case "medium":
            return "medium"
        case "high":
            return "high"
        case "xhigh", "x-high", "extra-high", "extra_high":
            return preferXHighForCodex ? "xhigh" : "high"
        default:
            return nil
        }
    }

    private static func grokSupportsReasoningEffort(_ model: String) -> Bool {
        let normalized = self.normalizedGrokModelID(model)
        return normalized.hasPrefix("grok-3-mini")
            || normalized.hasPrefix("grok-4.20-multi-agent")
            || normalized.hasPrefix("grok-4.3")
    }

    private static func resolveGrokReasoningEffort(_ thinkingLevel: String?, model: String) -> String? {
        let raw = thinkingLevel?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard let value = raw, !value.isEmpty else {
            return nil
        }
        if self.isGrokMultiAgentModel(model) {
            switch value {
            case "high":
                return "high"
            case "xhigh", "x-high", "extra-high", "extra_high":
                return "xhigh"
            case "medium", "mid":
                return "medium"
            case "low", "minimal", "default", "off", "none", "disable", "disabled":
                return "low"
            default:
                return nil
            }
        }
        guard self.grokSupportsReasoningEffort(model) else {
            return nil
        }
        switch value {
        case "off", "none", "disable", "disabled":
            return "none"
        case "minimal", "low", "default":
            return "low"
        case "medium", "mid":
            return "medium"
        case "high":
            return "high"
        case "xhigh", "x-high", "extra-high", "extra_high":
            return "high"
        default:
            return nil
        }
    }

    private static func isGrokMultiAgentModel(_ model: String) -> Bool {
        self.normalizedGrokModelID(model).hasPrefix("grok-4.20-multi-agent")
    }

    private static func normalizedGrokModelID(_ model: String) -> String {
        var normalized = model
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        if let slashIndex = normalized.lastIndex(of: "/") {
            normalized = String(normalized[normalized.index(after: slashIndex)...])
        }
        return normalized
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
            URL(string: "https://api.minimax.io/v1/chat/completions")!
        case .grokCompatible:
            URL(string: "https://api.x.ai/v1/chat/completions")!
        case .disabled, .openAICompatible, .anthropicCompatible:
            URL(string: "https://api.openai.com/v1/chat/completions")!
        }
    }

    private static func defaultResponsesEndpointURL(for provider: GatewayLocalLLMProviderKind) -> URL {
        switch provider {
        case .minimaxCompatible:
            URL(string: "https://api.minimax.io/v1/responses")!
        case .grokCompatible:
            URL(string: "https://api.x.ai/v1/responses")!
        case .disabled, .openAICompatible, .anthropicCompatible:
            URL(string: "https://api.openai.com/v1/responses")!
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

    private static func resolveResponsesEndpoint(baseURL: URL?, defaultEndpoint: URL) -> URL {
        guard let baseURL else {
            return defaultEndpoint
        }

        let path = baseURL.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let lowerPath = path.lowercased()
        let host = baseURL.host?.lowercased() ?? ""
        if host.hasSuffix("chatgpt.com"), path.isEmpty {
            return baseURL.appendingPathComponent("backend-api/codex/responses")
        }
        if lowerPath.hasSuffix("backend-api/codex/responses") || lowerPath.hasSuffix("codex/responses") {
            return baseURL
        }
        if lowerPath.hasSuffix("backend-api/codex") {
            return baseURL.appendingPathComponent("responses")
        }
        if lowerPath.hasSuffix("backend-api") {
            return baseURL.appendingPathComponent("codex/responses")
        }
        if path.isEmpty {
            return baseURL.appendingPathComponent("v1/responses")
        }
        if path.hasSuffix("responses") {
            return baseURL
        }
        if path.hasSuffix("chat/completions") {
            return baseURL
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("responses")
        }
        if path.hasSuffix("v1") {
            return baseURL.appendingPathComponent("responses")
        }
        return baseURL.appendingPathComponent("v1/responses")
    }

    private static func resolveWebSocketEndpoint(from responsesURL: URL) -> URL {
        guard var components = URLComponents(url: responsesURL, resolvingAgainstBaseURL: false) else {
            return responsesURL
        }
        switch components.scheme?.lowercased() {
        case "http":
            components.scheme = "ws"
        case "https":
            components.scheme = "wss"
        default:
            break
        }
        return components.url ?? responsesURL
    }

    static func normalizeOpenAIToolParameters(_ raw: [String: Any]?) -> [String: Any] {
        var params = raw ?? [:]

        // LM Studio validates function parameters with a stricter JSON schema:
        // object schemas must include an explicit properties object.
        if params["type"] == nil {
            params["type"] = "object"
        }
        let lowerType = (params["type"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let isObjectType = lowerType == nil || lowerType == "object"
        if isObjectType {
            if let existing = params["properties"] as? [String: Any] {
                params["properties"] = existing
            } else {
                params["properties"] = [String: Any]()
            }
        }
        return params
    }
}

public actor GatewayAnthropicCompatibleLLMProvider: GatewayLocalLLMToolCallableProvider {
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
        let apiKey = (self.config.apiKey ?? "").trimmingCharacters(in: .whitespacesAndNewlines)

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
            "max_tokens": max(64, self.config.maxOutputTokens ?? 1024),
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
        urlRequest.timeoutInterval = self.config.effectiveRequestTimeoutSeconds
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        urlRequest.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        let jsonBody = try Self.makeJSONBody(body)
        let bodyBytes = jsonBody.count
        urlRequest.httpBody = jsonBody

        let (data, response) = try await self.session.data(for: urlRequest)
        let httpResponse = response as? HTTPURLResponse
        if let statusCode = httpResponse?.statusCode, !(200...299).contains(statusCode) {
            throw GatewayLocalLLMProviderError.httpError(
                status: statusCode,
                message: Self.errorText(data))
        }

        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw GatewayLocalLLMProviderError.invalidResponse(
                "anthropic-compatible response is not a JSON object: \(Self.responsePreview(data))")
        }

        let text = Self.readAnthropicText(root["content"])
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw GatewayLocalLLMProviderError.invalidResponse(
                "anthropic-compatible response content is empty: \(Self.responsePreview(data))")
        }

        let usage = root["usage"] as? [String: Any]
        let input = Self.readInt(usage?["input_tokens"])
        let output = Self.readInt(usage?["output_tokens"])
        return GatewayLocalLLMResponse(
            text: trimmed,
            model: self.model,
            provider: self.kind,
            transport: .http,
            usageInputTokens: input,
            usageOutputTokens: output,
            requestBodyBytes: bodyBytes)
    }

    public func completeWithTools(_ request: GatewayLocalLLMToolRequest) async throws -> GatewayLocalLLMToolResponse {
        let apiKey = (self.config.apiKey ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !request.messages.isEmpty else {
            throw GatewayLocalLLMProviderError.invalidRequest("at least one message is required")
        }

        let toolNameMap = GatewayOpenAICompatibleLLMProvider.makeOpenAIToolNameMap(toolNames: request.tools.map(\.name))
        let reverseToolNameMap = Dictionary(uniqueKeysWithValues: toolNameMap.map { ($1, $0) })

        var systemParts: [String] = []
        if let systemPrompt = request.systemPrompt?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !systemPrompt.isEmpty
        {
            systemParts.append(systemPrompt)
        }

        var anthropicMessages: [[String: Any]] = []
        for message in request.messages {
            switch message.role {
            case .system:
                let text = (message.text ?? "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty {
                    systemParts.append(text)
                }
            case .user:
                let text = (message.text ?? "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { continue }
                anthropicMessages.append([
                    "role": "user",
                    "content": [
                        [
                            "type": "text",
                            "text": text,
                        ] as [String: Any],
                    ],
                ])
            case .assistant:
                var content: [[String: Any]] = []
                if let text = message.text?
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                    !text.isEmpty
                {
                    content.append([
                        "type": "text",
                        "text": text,
                    ])
                }
                for toolCall in message.toolCalls {
                    let wireName = toolNameMap[toolCall.name]
                        ?? GatewayOpenAICompatibleLLMProvider.openAICompatibleToolName(toolCall.name)
                    content.append([
                        "type": "tool_use",
                        "id": toolCall.id,
                        "name": wireName,
                        "input": Self.decodeToolArguments(toolCall.argumentsJSON),
                    ])
                }
                guard !content.isEmpty else { continue }
                anthropicMessages.append([
                    "role": "assistant",
                    "content": content,
                ])
            case .tool:
                guard let toolCallID = message.toolCallID?
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                    !toolCallID.isEmpty
                else {
                    let text = (message.text ?? "")
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !text.isEmpty else { continue }
                    anthropicMessages.append([
                        "role": "user",
                        "content": [
                            [
                                "type": "text",
                                "text": text,
                            ] as [String: Any],
                        ],
                    ])
                    continue
                }
                anthropicMessages.append([
                    "role": "user",
                    "content": [
                        [
                            "type": "tool_result",
                            "tool_use_id": toolCallID,
                            "content": message.text ?? "",
                        ] as [String: Any],
                    ],
                ])
            }
        }

        guard !anthropicMessages.isEmpty else {
            throw GatewayLocalLLMProviderError.invalidRequest("at least one message is required")
        }

        var body: [String: Any] = [
            "model": self.model,
            "messages": anthropicMessages,
            "max_tokens": max(64, self.config.maxOutputTokens ?? 1024),
        ]
        if !systemParts.isEmpty {
            body["system"] = systemParts.joined(separator: "\n\n")
        }
        if !request.tools.isEmpty {
            body["tools"] = request.tools.map { tool in
                let wireName = toolNameMap[tool.name]
                    ?? GatewayOpenAICompatibleLLMProvider.openAICompatibleToolName(tool.name)
                let inputSchema = GatewayOpenAICompatibleLLMProvider.normalizeOpenAIToolParameters(
                    tool.parameters.foundationJSONObjectValue)
                return [
                    "name": wireName,
                    "description": tool.description,
                    "input_schema": inputSchema,
                ] as [String: Any]
            }
            body["tool_choice"] = [
                "type": "auto",
            ]
        }
        if let temperature = self.config.temperature {
            body["temperature"] = temperature
        }

        var urlRequest = URLRequest(url: self.endpointURL)
        urlRequest.httpMethod = "POST"
        urlRequest.timeoutInterval = self.config.effectiveRequestTimeoutSeconds
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        urlRequest.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        let jsonBody = try Self.makeJSONBody(body)
        let bodyBytes = jsonBody.count
        urlRequest.httpBody = jsonBody

        let (data, response) = try await self.session.data(for: urlRequest)
        let httpResponse = response as? HTTPURLResponse
        if let statusCode = httpResponse?.statusCode, !(200...299).contains(statusCode) {
            throw GatewayLocalLLMProviderError.httpError(
                status: statusCode,
                message: Self.errorText(data))
        }

        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw GatewayLocalLLMProviderError.invalidResponse(
                "anthropic-compatible response is not a JSON object: \(Self.responsePreview(data))")
        }
        let content = root["content"]
        let text = Self.readAnthropicText(content)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let toolCalls = Self.readAnthropicToolCalls(content, restoreNamesUsing: reverseToolNameMap)

        if text.isEmpty, toolCalls.isEmpty {
            throw GatewayLocalLLMProviderError.invalidResponse(
                "anthropic-compatible response missing both content and tool calls: \(Self.responsePreview(data))")
        }

        let usage = root["usage"] as? [String: Any]
        let input = Self.readInt(usage?["input_tokens"])
        let output = Self.readInt(usage?["output_tokens"])
        return GatewayLocalLLMToolResponse(
            text: text,
            toolCalls: toolCalls,
            model: self.model,
            provider: self.kind,
            transport: .http,
            usageInputTokens: input,
            usageOutputTokens: output,
            requestBodyBytes: bodyBytes)
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

    private static func decodeToolArguments(_ argumentsJSON: String) -> [String: Any] {
        let trimmed = argumentsJSON.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let data = trimmed.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return [:]
        }
        return object
    }

    static func decodeToolCallsFromAnthropicContent(
        _ raw: Any?,
        restoreNamesUsing reverseToolNameMap: [String: String] = [:]) -> [GatewayLocalLLMToolCall]
    {
        readAnthropicToolCalls(raw, restoreNamesUsing: reverseToolNameMap)
    }
}

extension GatewayLocalLLMProvider {
    fileprivate static func makeJSONBody(_ value: [String: Any]) throws -> Data {
        guard JSONSerialization.isValidJSONObject(value) else {
            throw GatewayLocalLLMProviderError.invalidRequest("request body contains non-JSON values")
        }
        return try JSONSerialization.data(withJSONObject: value)
    }

    fileprivate static func readOpenAIContent(_ raw: Any?) -> String {
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

    fileprivate static func readAnthropicText(_ raw: Any?) -> String {
        guard let blocks = raw as? [[String: Any]] else { return "" }
        let texts = blocks.compactMap { block -> String? in
            guard let type = block["type"] as? String, type == "text" else { return nil }
            return block["text"] as? String
        }
        return texts.joined(separator: "\n")
    }

    fileprivate static func readInt(_ raw: Any?) -> Int? {
        if let value = raw as? Int {
            return value
        }
        if let value = raw as? NSNumber {
            return value.intValue
        }
        return nil
    }

    fileprivate static func readOpenAIToolCalls(
        _ raw: Any?,
        restoreNamesUsing reverseToolNameMap: [String: String] = [:]) -> [GatewayLocalLLMToolCall]
    {
        guard let calls = raw as? [[String: Any]] else {
            return []
        }
        return calls.compactMap { call in
            let id = (call["id"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard let function = call["function"] as? [String: Any] else {
                return nil
            }
            let wireName = (function["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !wireName.isEmpty else {
                return nil
            }
            let name = reverseToolNameMap[wireName] ?? wireName
            let arguments: String = if let rawArguments = function["arguments"] as? String {
                rawArguments
            } else {
                "{}"
            }
            return GatewayLocalLLMToolCall(
                id: id.isEmpty ? UUID().uuidString : id,
                name: name,
                argumentsJSON: arguments)
        }
    }

    fileprivate static func readAnthropicToolCalls(
        _ raw: Any?,
        restoreNamesUsing reverseToolNameMap: [String: String] = [:]) -> [GatewayLocalLLMToolCall]
    {
        guard let blocks = raw as? [[String: Any]] else {
            return []
        }
        return blocks.compactMap { block in
            let type = (block["type"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            guard type == "tool_use" else {
                return nil
            }

            let id = (block["id"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let wireName = (block["name"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !wireName.isEmpty else {
                return nil
            }
            let name = reverseToolNameMap[wireName] ?? wireName

            let argumentsJSON: String = if let input = block["input"],
                                           JSONSerialization.isValidJSONObject(input),
                                           let data = try? JSONSerialization.data(withJSONObject: input),
                                           let text = String(data: data, encoding: .utf8)
            {
                text
            } else {
                "{}"
            }

            return GatewayLocalLLMToolCall(
                id: id.isEmpty ? UUID().uuidString : id,
                name: name,
                argumentsJSON: argumentsJSON)
        }
    }

    fileprivate static func errorText(_ data: Data) -> String {
        guard let text = String(data: data, encoding: .utf8),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            return "upstream returned an empty error body"
        }
        return text
    }

    fileprivate static func responsePreview(_ data: Data, maxChars: Int = 512) -> String {
        guard let text = String(data: data, encoding: .utf8) else {
            return "<non-utf8 \(data.count) bytes>"
        }
        let compact = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !compact.isEmpty else {
            return "<empty body>"
        }
        if compact.count <= maxChars {
            return compact
        }
        return String(compact.prefix(maxChars)) + "…"
    }
}
