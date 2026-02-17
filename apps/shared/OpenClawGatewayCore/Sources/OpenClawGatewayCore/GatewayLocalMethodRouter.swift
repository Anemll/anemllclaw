import Foundation

public struct GatewayLocalMethodRouterConfig: Sendable, Equatable {
    public let hostLabel: String
    public let upstreamConfigured: Bool
    public let llmConfig: GatewayLocalLLMConfig
    public let memoryStorePath: URL
    public let enableLocalSafeTools: Bool

    public init(
        hostLabel: String = "tvos-local",
        upstreamConfigured: Bool,
        llmConfig: GatewayLocalLLMConfig,
        memoryStorePath: URL,
        enableLocalSafeTools: Bool = true)
    {
        self.hostLabel = hostLabel
        self.upstreamConfigured = upstreamConfigured
        self.llmConfig = llmConfig
        self.memoryStorePath = memoryStorePath
        self.enableLocalSafeTools = enableLocalSafeTools
    }
}

public actor GatewayLocalMethodRouter: GatewayLocalMethodHandling {
    private struct ChatSendParams: Codable {
        let sessionKey: String
        let message: String
        let thinking: String?
        let idempotencyKey: String?
    }

    private struct ChatHistoryParams: Codable {
        let sessionKey: String
        let limit: Int?
    }

    private struct SessionsListParams: Codable {
        let limit: Int?
    }

    private struct MemorySearchParams: Codable {
        let query: String
        let sessionKey: String?
        let limit: Int?
    }

    private struct MemoryGetParams: Codable {
        let id: GatewayJSONValue
    }

    private struct NodeInvokeParams: Codable {
        let nodeId: String?
        let command: String
        let params: GatewayJSONValue?
    }

    private struct NetworkFetchParams: Codable {
        let url: String
        let timeoutMs: Int?
    }

    private struct MethodCapability: Codable {
        let method: String
        let route: String
        let details: String
    }

    private struct ToolPolicy: Codable {
        let localSafeCommands: [String]
        let upstreamOnlyPrefixRules: [String]
    }

    private struct CapabilityMapPayload: Codable {
        let host: String
        let ts: Int64
        let upstreamConfigured: Bool
        let llmConfigured: Bool
        let llmProvider: String
        let memoryStorePath: String
        let methods: [MethodCapability]
        let toolPolicy: ToolPolicy
    }

    private static let safeLocalToolCommands = [
        "time.now",
        "device.info",
        "network.fetch",
    ]

    private let config: GatewayLocalMethodRouterConfig
    private let sessionStore: GatewaySessionStore
    private let memoryStore: GatewaySQLiteMemoryStore
    private let llmProvider: (any GatewayLocalLLMProvider)?
    private let urlSession: URLSession

    public init(
        config: GatewayLocalMethodRouterConfig,
        sessionStore: GatewaySessionStore = GatewaySessionStore(),
        llmProvider: (any GatewayLocalLLMProvider)? = nil,
        session: URLSession = URLSession(configuration: .ephemeral)) throws
    {
        self.config = config
        self.sessionStore = sessionStore
        self.memoryStore = try GatewaySQLiteMemoryStore(path: config.memoryStorePath)
        self.llmProvider = llmProvider ?? GatewayLocalLLMProviderFactory.make(config: config.llmConfig)
        self.urlSession = session
    }

    public func handle(_ request: GatewayRequestFrame, nowMs: Int64) async -> GatewayResponseFrame? {
        switch request.method {
        case "chat.send":
            return await self.handleChatSend(request, nowMs: nowMs)
        case "chat.history":
            return await self.handleChatHistory(request)
        case "sessions.list":
            return await self.handleSessionsList(request)
        case "memory.search":
            return await self.handleMemorySearch(request)
        case "memory.get":
            return await self.handleMemoryGet(request)
        case "node.invoke":
            return await self.handleNodeInvoke(request)
        case "tools.time.now", "time.now":
            return await self.handleDirectSafeTool(request, command: "time.now", params: request.params)
        case "tools.device.info", "device.info":
            return await self.handleDirectSafeTool(request, command: "device.info", params: request.params)
        case "tools.network.fetch", "network.fetch":
            return await self.handleDirectSafeTool(request, command: "network.fetch", params: request.params)
        case "capabilities.get", "gateway.capabilities", "capability.map":
            return self.handleCapabilitiesGet(request, nowMs: nowMs)
        default:
            if self.shouldRequireUpstreamForUnhandled(request.method), !self.config.upstreamConfigured {
                return Self.upstreamRequired(
                    id: request.id,
                    method: request.method,
                    hint: "configure upstream URL/token or enable a local implementation")
            }
            return nil
        }
    }

    private func handleChatSend(_ request: GatewayRequestFrame, nowMs: Int64) async -> GatewayResponseFrame? {
        guard let params = GatewayPayloadCodec.decode(request.params, as: ChatSendParams.self) else {
            return GatewayResponseFrame.failure(
                id: request.id,
                code: .invalidRequest,
                message: "invalid chat.send params")
        }

        let sessionKey = Self.normalizedSessionKey(params.sessionKey)
        let message = params.message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty else {
            return GatewayResponseFrame.failure(
                id: request.id,
                code: .invalidRequest,
                message: "invalid chat.send params: message required")
        }

        guard let provider = self.llmProvider else {
            if self.config.upstreamConfigured {
                return nil
            }
            return Self.upstreamRequired(
                id: request.id,
                method: request.method,
                hint: "local LLM is not configured")
        }

        let runID = Self.normalizedID(params.idempotencyKey, fallback: request.id)

        do {
            let queue = await self.sessionStore.queue(for: sessionKey)
            let completion = try await queue.enqueue {
                _ = try await self.memoryStore.appendTurn(
                    sessionKey: sessionKey,
                    role: "user",
                    text: message,
                    timestampMs: nowMs,
                    runID: runID)
                await self.sessionStore.recordTurn(sessionKey: sessionKey, nowMs: nowMs)

                let history = try await self.memoryStore.history(sessionKey: sessionKey, limit: 24)
                let llmMessages = history.map { turn in
                    GatewayLocalLLMMessage(role: turn.role, text: turn.text)
                }
                let llmResponse = try await provider.complete(
                    GatewayLocalLLMRequest(messages: llmMessages, thinkingLevel: params.thinking))

                _ = try await self.memoryStore.appendTurn(
                    sessionKey: sessionKey,
                    role: "assistant",
                    text: llmResponse.text,
                    timestampMs: GatewayCore.currentTimestampMs(),
                    runID: runID)
                await self.sessionStore.recordTurn(
                    sessionKey: sessionKey,
                    nowMs: GatewayCore.currentTimestampMs())
                return llmResponse
            }

            var usageObject: [String: GatewayJSONValue] = [:]
            if let inputTokens = completion.usageInputTokens {
                usageObject["input"] = .integer(Int64(inputTokens))
            }
            if let outputTokens = completion.usageOutputTokens {
                usageObject["output"] = .integer(Int64(outputTokens))
            }

            var payloadObject: [String: GatewayJSONValue] = [
                "runId": .string(runID),
                "status": .string("completed"),
                "source": .string("local"),
                "provider": .string(completion.provider.rawValue),
                "model": .string(completion.model),
            ]
            if !usageObject.isEmpty {
                payloadObject["usage"] = .object(usageObject)
            }
            return GatewayResponseFrame.success(id: request.id, payload: .object(payloadObject))
        } catch let error as GatewayLocalLLMProviderError {
            if self.config.upstreamConfigured {
                return nil
            }
            return GatewayResponseFrame.failure(
                id: request.id,
                code: .internalError,
                message: "local llm failed: \(error)")
        } catch {
            return GatewayResponseFrame.failure(
                id: request.id,
                code: .internalError,
                message: "local chat failed: \(error.localizedDescription)")
        }
    }

    private func handleChatHistory(_ request: GatewayRequestFrame) async -> GatewayResponseFrame? {
        guard let params = GatewayPayloadCodec.decode(request.params, as: ChatHistoryParams.self) else {
            return GatewayResponseFrame.failure(
                id: request.id,
                code: .invalidRequest,
                message: "invalid chat.history params")
        }
        let sessionKey = Self.normalizedSessionKey(params.sessionKey)
        let limit = max(1, min(params.limit ?? 200, 1_000))

        do {
            let turns = try await self.memoryStore.history(sessionKey: sessionKey, limit: limit)
            let messages = turns.map(Self.asChatHistoryMessage)
            let payload: GatewayJSONValue = .object([
                "sessionKey": .string(sessionKey),
                "sessionId": .string(sessionKey),
                "thinkingLevel": .string("low"),
                "messages": .array(messages),
            ])
            return GatewayResponseFrame.success(id: request.id, payload: payload)
        } catch {
            return GatewayResponseFrame.failure(
                id: request.id,
                code: .internalError,
                message: "local chat history failed: \(error.localizedDescription)")
        }
    }

    private func handleSessionsList(_ request: GatewayRequestFrame) async -> GatewayResponseFrame? {
        let params = GatewayPayloadCodec.decode(request.params, as: SessionsListParams.self)
        let limit = max(1, min(params?.limit ?? 50, 500))
        let snapshots = await self.sessionStore.snapshots()
        let sessions = snapshots.sorted { $0.lastActivityMs > $1.lastActivityMs }
            .prefix(limit)
            .map { snapshot -> GatewayJSONValue in
                var object: [String: GatewayJSONValue] = [
                    "key": .string(snapshot.sessionKey),
                    "displayName": .string(snapshot.sessionKey),
                    "updatedAt": .double(Double(snapshot.lastActivityMs)),
                    "sessionId": .string(snapshot.sessionKey),
                    "thinkingLevel": .string("low"),
                ]
                if let model = self.config.llmConfig.model?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !model.isEmpty
                {
                    object["model"] = .string(model)
                }
                return .object(object)
            }
        let payload: GatewayJSONValue = .object([
            "ts": .double(Double(GatewayCore.currentTimestampMs())),
            "count": .integer(Int64(sessions.count)),
            "sessions": .array(sessions),
        ])
        return GatewayResponseFrame.success(id: request.id, payload: payload)
    }

    private func handleMemorySearch(_ request: GatewayRequestFrame) async -> GatewayResponseFrame? {
        guard let params = GatewayPayloadCodec.decode(request.params, as: MemorySearchParams.self) else {
            return GatewayResponseFrame.failure(
                id: request.id,
                code: .invalidRequest,
                message: "invalid memory.search params")
        }

        let query = params.query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            return GatewayResponseFrame.failure(
                id: request.id,
                code: .invalidRequest,
                message: "invalid memory.search params: query required")
        }

        let limit = max(1, min(params.limit ?? 10, 100))
        do {
            let hits = try await self.memoryStore.search(
                query: query,
                sessionKey: params.sessionKey,
                limit: limit)
            let resultItems = hits.map { hit -> GatewayJSONValue in
                var object: [String: GatewayJSONValue] = [
                    "id": .string("turn:\(hit.turn.id)"),
                    "sessionKey": .string(hit.turn.sessionKey),
                    "role": .string(hit.turn.role),
                    "text": .string(hit.turn.text),
                    "timestampMs": .integer(hit.turn.timestampMs),
                ]
                if let score = hit.score {
                    object["score"] = .double(score)
                } else {
                    object["score"] = .null
                }
                return .object(object)
            }
            let payload: GatewayJSONValue = .object([
                "query": .string(query),
                "results": .array(resultItems),
            ])
            return GatewayResponseFrame.success(id: request.id, payload: payload)
        } catch {
            return GatewayResponseFrame.failure(
                id: request.id,
                code: .internalError,
                message: "local memory.search failed: \(error.localizedDescription)")
        }
    }

    private func handleMemoryGet(_ request: GatewayRequestFrame) async -> GatewayResponseFrame? {
        guard let params = GatewayPayloadCodec.decode(request.params, as: MemoryGetParams.self) else {
            return GatewayResponseFrame.failure(
                id: request.id,
                code: .invalidRequest,
                message: "invalid memory.get params")
        }

        guard let turnID = Self.turnID(from: params.id) else {
            return GatewayResponseFrame.failure(
                id: request.id,
                code: .invalidRequest,
                message: "invalid memory.get params: id must be turn:<id> or integer")
        }

        do {
            guard let turn = try await self.memoryStore.getTurn(id: turnID) else {
                return GatewayResponseFrame.failure(
                    id: request.id,
                    code: .invalidRequest,
                    message: "memory turn not found: \(turnID)")
            }
            var payloadObject: [String: GatewayJSONValue] = [
                "id": .string("turn:\(turn.id)"),
                "sessionKey": .string(turn.sessionKey),
                "role": .string(turn.role),
                "text": .string(turn.text),
                "timestampMs": .integer(turn.timestampMs),
            ]
            if let runID = turn.runID {
                payloadObject["runId"] = .string(runID)
            } else {
                payloadObject["runId"] = .null
            }
            return GatewayResponseFrame.success(id: request.id, payload: .object(payloadObject))
        } catch {
            return GatewayResponseFrame.failure(
                id: request.id,
                code: .internalError,
                message: "local memory.get failed: \(error.localizedDescription)")
        }
    }

    private func handleNodeInvoke(_ request: GatewayRequestFrame) async -> GatewayResponseFrame? {
        guard let params = GatewayPayloadCodec.decode(request.params, as: NodeInvokeParams.self) else {
            return GatewayResponseFrame.failure(
                id: request.id,
                code: .invalidRequest,
                message: "invalid node.invoke params")
        }

        let command = params.command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !command.isEmpty else {
            return GatewayResponseFrame.failure(
                id: request.id,
                code: .invalidRequest,
                message: "invalid node.invoke params: command required")
        }

        if Self.safeLocalToolCommands.contains(command) {
            return await self.handleDirectSafeTool(
                request,
                command: command,
                params: params.params)
        }

        if self.config.upstreamConfigured {
            return nil
        }
        return Self.upstreamRequired(
            id: request.id,
            method: "node.invoke",
            hint: "command \(command) is upstream-only on tvOS")
    }

    private func handleDirectSafeTool(
        _ request: GatewayRequestFrame,
        command: String,
        params: GatewayJSONValue?) async -> GatewayResponseFrame
    {
        guard self.config.enableLocalSafeTools else {
            if self.config.upstreamConfigured {
                return GatewayResponseFrame.failure(
                    id: request.id,
                    code: .unsupportedOnHost,
                    message: "local safe tools are disabled")
            }
            return Self.upstreamRequired(
                id: request.id,
                method: request.method,
                hint: "local safe tools are disabled")
        }

        switch command {
        case "time.now":
            let ts = GatewayCore.currentTimestampMs()
            let payload: GatewayJSONValue = .object([
                "ok": .bool(true),
                "command": .string(command),
                "ts": .integer(ts),
                "iso8601": .string(
                    ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: Double(ts) / 1000.0))),
                "timezone": .string(TimeZone.current.identifier),
            ])
            return GatewayResponseFrame.success(id: request.id, payload: payload)

        case "device.info":
            let payload: GatewayJSONValue = .object([
                "ok": .bool(true),
                "command": .string(command),
                "hostLabel": .string(self.config.hostLabel),
                "operatingSystemVersion": .string(ProcessInfo.processInfo.operatingSystemVersionString),
                "isLowPowerModeEnabled": .bool(ProcessInfo.processInfo.isLowPowerModeEnabled),
                "activeProcessorCount": .integer(Int64(ProcessInfo.processInfo.activeProcessorCount)),
                "physicalMemory": .integer(Int64(ProcessInfo.processInfo.physicalMemory)),
            ])
            return GatewayResponseFrame.success(id: request.id, payload: payload)

        case "network.fetch":
            guard let fetchParams = GatewayPayloadCodec.decode(params, as: NetworkFetchParams.self) else {
                return GatewayResponseFrame.failure(
                    id: request.id,
                    code: .invalidRequest,
                    message: "invalid network.fetch params")
            }
            guard let url = URL(string: fetchParams.url) else {
                return GatewayResponseFrame.failure(
                    id: request.id,
                    code: .invalidRequest,
                    message: "invalid network.fetch params: malformed url")
            }
            do {
                var urlRequest = URLRequest(url: url)
                urlRequest.httpMethod = "GET"
                let timeoutSeconds = max(1.0, Double(fetchParams.timeoutMs ?? 5_000) / 1000.0)
                urlRequest.timeoutInterval = min(timeoutSeconds, 30.0)
                let (data, response) = try await self.urlSession.data(for: urlRequest)
                let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
                let text = String(data: data.prefix(16_384), encoding: .utf8)
                var payloadObject: [String: GatewayJSONValue] = [
                    "ok": .bool(true),
                    "command": .string(command),
                    "url": .string(url.absoluteString),
                    "statusCode": .integer(Int64(statusCode)),
                    "bytes": .integer(Int64(data.count)),
                ]
                if let text, !text.isEmpty {
                    payloadObject["text"] = .string(text)
                } else {
                    payloadObject["text"] = .null
                }
                return GatewayResponseFrame.success(id: request.id, payload: .object(payloadObject))
            } catch {
                return GatewayResponseFrame.failure(
                    id: request.id,
                    code: .internalError,
                    message: "network.fetch failed: \(error.localizedDescription)")
            }

        default:
            if self.config.upstreamConfigured {
                return GatewayResponseFrame.failure(
                    id: request.id,
                    code: .unsupportedOnHost,
                    message: "unknown local safe command: \(command)")
            }
            return Self.upstreamRequired(
                id: request.id,
                method: request.method,
                hint: "unknown local safe command: \(command)")
        }
    }

    private func handleCapabilitiesGet(_ request: GatewayRequestFrame, nowMs: Int64) -> GatewayResponseFrame {
        let payload = CapabilityMapPayload(
            host: self.config.hostLabel,
            ts: nowMs,
            upstreamConfigured: self.config.upstreamConfigured,
            llmConfigured: self.llmProvider != nil,
            llmProvider: self.config.llmConfig.provider.rawValue,
            memoryStorePath: self.config.memoryStorePath.path,
            methods: [
                MethodCapability(
                    method: "health",
                    route: "local",
                    details: "Always served by Swift gateway core"),
                MethodCapability(
                    method: "status",
                    route: "local",
                    details: "Served by Swift gateway core"),
                MethodCapability(
                    method: "chat.send",
                    route: self.llmProvider == nil ? "upstream" : "local",
                    details: self.llmProvider == nil
                        ? "Requires configured upstream or local LLM provider"
                        : "Served locally via URLSession LLM adapter"),
                MethodCapability(
                    method: "chat.history",
                    route: "local",
                    details: "Served locally from SQLite transcript store"),
                MethodCapability(
                    method: "memory.search",
                    route: "local",
                    details: "Served locally from SQLite FTS index"),
                MethodCapability(
                    method: "memory.get",
                    route: "local",
                    details: "Served locally from SQLite transcript store"),
                MethodCapability(
                    method: "node.invoke",
                    route: "policy",
                    details: "Safe commands local; unsafe commands upstream-only"),
            ],
            toolPolicy: ToolPolicy(
                localSafeCommands: Self.safeLocalToolCommands,
                upstreamOnlyPrefixRules: GatewayRoutingPolicy.upstreamOnlyMethodPrefixes))

        return GatewayResponseFrame.success(
            id: request.id,
            payload: GatewayPayloadCodec.encode(payload))
    }

    private func shouldRequireUpstreamForUnhandled(_ method: String) -> Bool {
        if method.hasPrefix("chat.") || method.hasPrefix("memory.") {
            return true
        }
        return GatewayRoutingPolicy.requiresUpstream(method)
    }

    private static func upstreamRequired(id: String, method: String, hint: String) -> GatewayResponseFrame {
        GatewayResponseFrame.failure(
            id: id,
            code: .upstreamRequired,
            message: "upstream required for \(method): \(hint)")
    }

    private static func normalizedSessionKey(_ raw: String?) -> String {
        let trimmed = (raw ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "main" : trimmed
    }

    private static func normalizedID(_ raw: String?, fallback: String) -> String {
        let trimmed = (raw ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? fallback : trimmed
    }

    private static func asChatHistoryMessage(_ turn: GatewayMemoryTurn) -> GatewayJSONValue {
        var object: [String: GatewayJSONValue] = [
            "role": .string(turn.role),
            "timestamp": .double(Double(turn.timestampMs)),
            "content": .array([
                .object([
                    "type": .string("text"),
                    "text": .string(turn.text),
                ]),
            ]),
        ]
        if let runID = turn.runID {
            object["runId"] = .string(runID)
        } else {
            object["runId"] = .null
        }
        return .object(object)
    }

    private static func turnID(from raw: GatewayJSONValue) -> Int64? {
        if let intValue = raw.int64Value {
            return intValue
        }
        guard let text = raw.stringValue else { return nil }
        if let direct = Int64(text) {
            return direct
        }
        if text.hasPrefix("turn:"), let suffix = Int64(text.dropFirst(5)) {
            return suffix
        }
        return nil
    }
}
