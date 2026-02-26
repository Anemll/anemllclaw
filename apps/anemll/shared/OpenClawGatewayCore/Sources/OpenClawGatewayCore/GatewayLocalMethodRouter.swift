import CoreGraphics
import Foundation
import ImageIO

public protocol GatewayLocalMethodRouterAdminBridge: Sendable {
    func configGet(nowMs: Int64) async throws -> GatewayJSONValue
    func configSet(params: GatewayJSONValue, nowMs: Int64) async throws -> GatewayJSONValue
    func runtimeRestart(nowMs: Int64) async throws -> GatewayJSONValue
    func pairingList(params: GatewayJSONValue, nowMs: Int64) async throws -> GatewayJSONValue
    func pairingApprove(params: GatewayJSONValue, nowMs: Int64) async throws -> GatewayJSONValue
    func backupExport(nowMs: Int64) async throws -> GatewayJSONValue
    func backupImport(params: GatewayJSONValue, nowMs: Int64) async throws -> GatewayJSONValue
    func dreamStatus() async throws -> GatewayJSONValue
    func dreamEnter() async throws -> GatewayJSONValue
    func dreamWake() async throws -> GatewayJSONValue
    func dreamIdle() async throws -> GatewayJSONValue
    func dreamReseedTemplates() async throws -> GatewayJSONValue
}

public enum GatewayLocalLLMToolCallingMode: String, Codable, Sendable, Equatable {
    case auto
    case on
    case off
}

public struct GatewayLocalMethodRouterConfig: Sendable {
    public let hostLabel: String
    public let upstreamConfigured: Bool
    public let upstreamForwarder: (any GatewayUpstreamForwarding)?
    public let llmConfig: GatewayLocalLLMConfig
    public let telegramConfig: GatewayLocalTelegramConfig
    public let memoryStorePath: URL
    public let bootstrapConfig: GatewayBootstrapConfig
    public let enableLocalSafeTools: Bool
    public let enableLocalFileTools: Bool
    public let enableLocalDeviceTools: Bool
    public let deviceToolBridge: (any GatewayDeviceToolBridge)?
    public let llmToolCallingMode: GatewayLocalLLMToolCallingMode
    public let enableAutoProfileRewrite: Bool
    public let adminBridge: (any GatewayLocalMethodRouterAdminBridge)?
    public let disabledToolNames: Set<String>

    public init(
        hostLabel: String = "tvos-local",
        upstreamConfigured: Bool,
        upstreamForwarder: (any GatewayUpstreamForwarding)? = nil,
        llmConfig: GatewayLocalLLMConfig,
        telegramConfig: GatewayLocalTelegramConfig = .disabled,
        memoryStorePath: URL,
        bootstrapConfig: GatewayBootstrapConfig = .default,
        enableLocalSafeTools: Bool = true,
        enableLocalFileTools: Bool = true,
        enableLocalDeviceTools: Bool = false,
        deviceToolBridge: (any GatewayDeviceToolBridge)? = nil,
        llmToolCallingMode: GatewayLocalLLMToolCallingMode = .auto,
        enableAutoProfileRewrite: Bool = false,
        adminBridge: (any GatewayLocalMethodRouterAdminBridge)? = nil,
        disabledToolNames: Set<String> = [])
    {
        self.hostLabel = hostLabel
        self.upstreamConfigured = upstreamConfigured
        self.upstreamForwarder = upstreamForwarder
        self.llmConfig = llmConfig
        self.telegramConfig = telegramConfig
        self.memoryStorePath = memoryStorePath
        self.bootstrapConfig = bootstrapConfig
        self.enableLocalSafeTools = enableLocalSafeTools
        self.enableLocalFileTools = enableLocalFileTools
        self.enableLocalDeviceTools = enableLocalDeviceTools
        self.deviceToolBridge = deviceToolBridge
        self.llmToolCallingMode = llmToolCallingMode
        self.enableAutoProfileRewrite = enableAutoProfileRewrite
        self.adminBridge = adminBridge
        self.disabledToolNames = disabledToolNames
    }
}

public struct GatewayBootstrapConfig: Sendable, Equatable {
    public let enabled: Bool
    public let workspacePath: String
    public let fileNames: [String]
    public let perFileMaxChars: Int
    public let totalMaxChars: Int
    public let includeMissingMarkers: Bool

    public init(
        enabled: Bool,
        workspacePath: String,
        fileNames: [String],
        perFileMaxChars: Int,
        totalMaxChars: Int,
        includeMissingMarkers: Bool)
    {
        self.enabled = enabled
        self.workspacePath = workspacePath
        self.fileNames = fileNames
        self.perFileMaxChars = perFileMaxChars
        self.totalMaxChars = totalMaxChars
        self.includeMissingMarkers = includeMissingMarkers
    }

    public static let `default` = GatewayBootstrapConfig(
        enabled: false,
        workspacePath: "",
        fileNames: [
            "AGENTS.md",
            "SOUL.md",
            "TOOLS.md",
            "IDENTITY.md",
            "USER.md",
            "HEARTBEAT.md",
            "BOOTSTRAP.md",
            "MEMORY.md",
            "memory.md",
            "DREAM.md",
        ],
        perFileMaxChars: 8000,
        totalMaxChars: 48000,
        includeMissingMarkers: false)
}

public actor GatewayLocalMethodRouter: GatewayLocalMethodHandling {
    private struct ChatSendParams: Codable {
        let sessionKey: String
        let message: String
        let thinking: String?
        let idempotencyKey: String?
        let historyLimit: Int?
        let skipPreamble: Bool?
        let disableTools: Bool?
        /// Maximum tool-calling loop iterations (default 6).
        /// Dream mode uses a higher value (e.g. 12) to allow the full
        /// consolidate → explore → critic → write cycle to complete.
        let maxToolRounds: Int?
    }

    private struct ParsedChatPrompt {
        let message: String
        let thinking: String?
    }

    private struct ChatToolExecutionAudit: Sendable {
        let name: String
        let ok: Bool
        let details: String
    }

    private struct ChatExecutionResult: Sendable {
        let response: GatewayLocalLLMResponse
        let toolAudits: [ChatToolExecutionAudit]
        /// Total HTTP body bytes sent across all LLM round-trips
        /// (accumulated over tool-calling loop iterations).
        let totalRequestBodyBytes: Int?
        /// Total tokens used across all LLM round-trips.
        let totalInputTokens: Int?
        let totalOutputTokens: Int?
        /// Number of LLM API calls made (1 for plain, 1+ for tool loops).
        let llmRoundTrips: Int
    }

    private enum ParsedChatDirective: Sendable {
        case reasoning(level: String)
        case unknown(raw: String)
    }

    private struct ChatHistoryParams: Codable {
        let sessionKey: String
        let limit: Int?
    }

    private struct SessionsListParams: Codable {
        let limit: Int?
    }

    private struct SessionsDeleteParams: Codable {
        let key: String
        let deleteTranscript: Bool?
    }

    private struct MemorySearchParams: Codable {
        let query: String
        let sessionKey: String?
        let limit: Int?
    }

    private struct MemoryGetParams: Codable {
        let id: GatewayJSONValue
    }

    private struct MemoryAppendParams: Codable {
        let path: String?
        let text: String
        let append: Bool?
    }

    private struct WorkspaceMemoryReference: Sendable {
        let relativePath: String
        let line: Int
    }

    private struct WorkspaceMemoryHit: Sendable {
        let id: String
        let file: String
        let lineStart: Int
        let lineEnd: Int
        let text: String
        let score: Double
    }

    private struct NodeInvokeParams: Codable {
        let nodeId: String?
        let command: String
        let params: GatewayJSONValue?
    }

    private struct AgentsRunParams: Codable {
        let runId: String?
        let sessionKey: String?
        let goal: String?
        let prompt: String?
        let maxSteps: Int?
        let steps: [GatewayAgentRunStep]?
    }

    private struct AgentsStatusParams: Codable {
        let runId: String?
    }

    private struct AgentsAbortParams: Codable {
        let runId: String?
    }

    private struct CronListParams: Codable {
        let includeDisabled: Bool?
    }

    private struct CronStatusParams: Codable {}

    private struct CronAddParams: Codable {
        let agentId: String?
        let name: String
        let description: String?
        let enabled: Bool?
        let deleteAfterRun: Bool?
        let schedule: LocalCronSchedule
        let sessionTarget: String?
        let wakeMode: String?
        let payload: LocalCronPayload
        let delivery: LocalCronDelivery?
    }

    private struct CronUpdateParams: Codable {
        let id: String?
        let jobId: String?
        let patch: LocalCronPatch
    }

    private struct CronRemoveParams: Codable {
        let id: String?
        let jobId: String?
    }

    private struct CronRunParams: Codable {
        let id: String?
        let jobId: String?
        let mode: String?
    }

    private struct CronRunsParams: Codable {
        let id: String?
        let jobId: String?
        let limit: Int?
    }

    private struct LocalCronStore: Codable {
        let version: Int
        var jobs: [LocalCronJob]
    }

    private struct LocalCronSchedule: Codable {
        enum Kind: String, Codable {
            case at
            case every
            case cron
        }

        let kind: Kind
        let at: String?
        let everyMs: Int64?
        let anchorMs: Int64?
        let expr: String?
        let tz: String?
    }

    private struct LocalCronPayload: Codable {
        enum Kind: String, Codable {
            case systemEvent
            case agentTurn
        }

        let kind: Kind
        let text: String?
        let message: String?
        let model: String?
        let thinking: String?
        let timeoutSeconds: Int?
    }

    private struct LocalCronDelivery: Codable {
        let mode: String?
        let channel: String?
        let to: String?
        let bestEffort: Bool?
    }

    private struct LocalCronState: Codable {
        var nextRunAtMs: Int64?
        var runningAtMs: Int64?
        var lastRunAtMs: Int64?
        var lastStatus: String?
        var lastError: String?
        var lastDurationMs: Int64?
        var consecutiveErrors: Int?
        var scheduleErrorCount: Int?
    }

    private struct LocalCronJob: Codable {
        let id: String
        var agentId: String?
        var name: String
        var description: String?
        var enabled: Bool
        var deleteAfterRun: Bool?
        let createdAtMs: Int64
        var updatedAtMs: Int64
        var schedule: LocalCronSchedule
        var sessionTarget: String
        var wakeMode: String
        var payload: LocalCronPayload
        var delivery: LocalCronDelivery?
        var state: LocalCronState
    }

    private struct LocalCronPatch: Codable {
        let agentId: String?
        let name: String?
        let description: String?
        let enabled: Bool?
        let deleteAfterRun: Bool?
        let schedule: LocalCronSchedule?
        let sessionTarget: String?
        let wakeMode: String?
        let payload: LocalCronPayload?
        let delivery: LocalCronDelivery?
        let state: LocalCronState?
    }

    private struct LocalCronRunLogEntry: Codable {
        let ts: Int64
        let status: String
        let mode: String
        let durationMs: Int64?
        let error: String?
        let sessionKey: String?
        let runId: String?
    }

    private enum LocalCronExecutionResult {
        case success(GatewayJSONValue?)
        case failure(String)
    }

    private struct MethodCapability: Codable {
        let method: String
        let route: String
        let details: String
    }

    private struct ToolPolicy: Codable {
        let localSafeCommands: [String]
        let localFileCommands: [String]
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

    private struct BootstrapProfileFields: Sendable {
        var assistantName: String?
        var assistantCreature: String?
        var assistantVibe: String?
        var assistantEmoji: String?
        var userName: String?
        var userCallName: String?
        var userTimezone: String?

        var isEmpty: Bool {
            self.assistantName == nil
                && self.assistantCreature == nil
                && self.assistantVibe == nil
                && self.assistantEmoji == nil
                && self.userName == nil
                && self.userCallName == nil
                && self.userTimezone == nil
        }
    }

    private let config: GatewayLocalMethodRouterConfig
    /// Files dropped from the bootstrap prompt due to budget exhaustion.
    /// Updated on each `chat.send` call.
    public private(set) var lastBootstrapDroppedFiles: [String] = []
    private let sessionStore: GatewaySessionStore
    private let memoryStore: GatewaySQLiteMemoryStore
    private let llmProvider: (any GatewayLocalLLMProvider)?
    private let urlSession: URLSession
    private let agentRuntime: GatewayAgentRuntime
    private var cronJobsByID: [String: LocalCronJob]
    private let cronStorePath: URL
    private let cronRunsDirectoryPath: URL
    private var cronTickTask: Task<Void, Never>?
    private var cronRunTaskByJobID: [String: Task<GatewayResponseFrame?, Never>] = [:]

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
        self.agentRuntime = GatewayAgentRuntime(
            sessionStore: sessionStore,
            memoryStore: self.memoryStore,
            llmProvider: self.llmProvider,
            hostLabel: config.hostLabel,
            enableLocalSafeTools: config.enableLocalSafeTools,
            enableLocalFileTools: config.enableLocalFileTools,
            enableLocalDeviceTools: config.enableLocalDeviceTools,
            deviceToolBridge: config.deviceToolBridge,
            telegramConfig: config.telegramConfig,
            workspaceRoot: Self.resolveWorkspaceRootURL(config.bootstrapConfig),
            session: session)

        self.cronStorePath = Self.defaultCronStorePath(memoryStorePath: config.memoryStorePath)
        self.cronRunsDirectoryPath = self.cronStorePath.deletingLastPathComponent().appendingPathComponent(
            "runs",
            isDirectory: true)
        self.cronJobsByID = Self.loadCronJobs(storePath: self.cronStorePath)
        Task { [weak self] in
            await self?.startCronSchedulerIfNeeded()
        }
    }

    deinit {
        self.cronTickTask?.cancel()
        self.cronRunTaskByJobID.values.forEach { $0.cancel() }
    }

    public func handle(_ request: GatewayRequestFrame, nowMs: Int64) async -> GatewayResponseFrame? {
        switch request.method {
        case "chat.send":
            return await self.handleChatSend(request, nowMs: nowMs)
        case "chat.history":
            return await self.handleChatHistory(request)
        case "sessions.list":
            return await self.handleSessionsList(request)
        case "sessions.delete":
            return await self.handleSessionsDelete(request)
        case "memory.search":
            return await self.handleMemorySearch(request)
        case "memory.get":
            return await self.handleMemoryGet(request)
        case "memory.append", "memory.write":
            return await self.handleMemoryAppend(request, nowMs: nowMs)
        case "node.invoke":
            return await self.handleNodeInvoke(request)
        case "agents.run":
            return await self.handleAgentsRun(request, nowMs: nowMs)
        case "agents.status":
            return await self.handleAgentsStatus(request)
        case "agents.abort":
            return await self.handleAgentsAbort(request, nowMs: nowMs)
        case "cron.list":
            return await self.handleCronList(request)
        case "cron.status":
            return await self.handleCronStatus(request, nowMs: nowMs)
        case "cron.add":
            return await self.handleCronAdd(request, nowMs: nowMs)
        case "cron.update":
            return await self.handleCronUpdate(request, nowMs: nowMs)
        case "cron.remove":
            return await self.handleCronRemove(request)
        case "cron.run":
            return await self.handleCronRun(request, nowMs: nowMs)
        case "cron.runs":
            return await self.handleCronRuns(request)
        case "config.get":
            return await self.handleConfigGet(request, nowMs: nowMs)
        case "config.set":
            return await self.handleConfigSet(request, nowMs: nowMs)
        case "runtime.restart":
            return await self.handleRuntimeRestart(request, nowMs: nowMs)
        case "pairing.list":
            return await self.handlePairingList(request, nowMs: nowMs)
        case "pairing.approve":
            return await self.handlePairingApprove(request, nowMs: nowMs)
        case "backup.export":
            return await self.handleBackupExport(request, nowMs: nowMs)
        case "backup.import":
            return await self.handleBackupImport(request, nowMs: nowMs)
        case "dream.status":
            return await self.handleDreamStatus(request)
        case "dream.enter":
            return await self.handleDreamEnter(request)
        case "dream.wake":
            return await self.handleDreamWake(request)
        case "dream.idle":
            return await self.handleDreamIdle(request)
        case "dream.reseedTemplates":
            return await self.handleDreamReseedTemplates(request)
        case "tools.time.now", "time.now":
            return await self.handleDirectSafeTool(request, command: "time.now", params: request.params)
        case "tools.device.info", "device.info":
            return await self.handleDirectSafeTool(request, command: "device.info", params: request.params)
        case "tools.network.fetch", "network.fetch":
            return await self.handleDirectSafeTool(request, command: "network.fetch", params: request.params)
        case "tools.web.fetch", "web.fetch":
            return await self.handleDirectSafeTool(request, command: "web.fetch", params: request.params)
        case "tools.web.render", "web.render":
            return await self.handleDirectSafeTool(request, command: "web.render", params: request.params)
        case "tools.web.extract", "web.extract":
            return await self.handleDirectSafeTool(request, command: "web.extract", params: request.params)
        case "tools.telegram.send", "telegram.send":
            return await self.handleDirectSafeTool(request, command: "telegram.send", params: request.params)
        case "tools.read", "read":
            return await self.handleDirectSafeTool(request, command: "read", params: request.params)
        case "tools.write", "write":
            return await self.handleDirectSafeTool(request, command: "write", params: request.params)
        case "tools.edit", "edit":
            return await self.handleDirectSafeTool(request, command: "edit", params: request.params)
        case "tools.apply_patch", "apply_patch":
            return await self.handleDirectSafeTool(request, command: "apply_patch", params: request.params)
        case "tools.ls", "ls":
            return await self.handleDirectSafeTool(request, command: "ls", params: request.params)
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
        let parsedPrompt = Self.parseChatPrompt(
            params.message,
            requestedThinking: params.thinking)
        let message = parsedPrompt.message.trimmingCharacters(in: .whitespacesAndNewlines)
        if message.isEmpty {
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

        let bootstrapResult = params.skipPreamble == true
            ? BootstrapPromptResult(prompt: nil, droppedFiles: [])
            : self.composeBootstrapPrompt()
        let systemPrompt = bootstrapResult.prompt
        if !bootstrapResult.droppedFiles.isEmpty {
            self.lastBootstrapDroppedFiles = bootstrapResult.droppedFiles
        }
        let disableTools = params.disableTools == true
        let runID = Self.normalizedID(params.idempotencyKey, fallback: request.id)
        let historyLimit = max(12, min(params.historyLimit ?? 64, 200))
        let workspaceRoot = self.workspaceRootURL()
        let bootstrapFields = self.config.enableAutoProfileRewrite
            ? Self.extractBootstrapProfileFields(from: message)
            : nil
        // Respect the configured tool mode even when websocket transport is selected.
        // Provider-specific implementations can still choose their own fallback path.
        let toolCallingMode = self.config.llmToolCallingMode

        do {
            let queue = await self.sessionStore.queue(for: sessionKey)
            let completion = try await queue.enqueue {
                _ = try await self.memoryStore.appendTurn(
                    sessionKey: sessionKey,
                    role: "user",
                    text: message,
                    timestampMs: nowMs,
                    runID: runID)
                await self.sessionStore.recordTurn(
                    sessionKey: sessionKey,
                    nowMs: nowMs,
                    thinkingLevel: parsedPrompt.thinking)

                if let bootstrapNote = Self.maybeApplyBootstrapProfileUpdate(
                    fields: bootstrapFields,
                    workspaceRoot: workspaceRoot)
                {
                    let bootstrapNoteTimestamp = GatewayCore.currentTimestampMs()
                    _ = try await self.memoryStore.appendTurn(
                        sessionKey: sessionKey,
                        role: "system",
                        text: bootstrapNote,
                        timestampMs: bootstrapNoteTimestamp,
                        runID: runID)
                    await self.sessionStore.recordTurn(
                        sessionKey: sessionKey,
                        nowMs: bootstrapNoteTimestamp)
                }

                let history = try await self.memoryStore.history(sessionKey: sessionKey, limit: historyLimit)
                let llmMessages = history.map { turn in GatewayLocalLLMMessage(role: turn.role, text: turn.text) }
                let chatResult: ChatExecutionResult
                let shouldAttemptToolCalling = !disableTools && toolCallingMode != .off
                if shouldAttemptToolCalling {
                    if let toolProvider = provider as? any GatewayLocalLLMToolCallableProvider {
                        do {
                            chatResult = try await self.runToolAwareChat(
                                provider: toolProvider,
                                llmMessages: llmMessages,
                                thinkingLevel: parsedPrompt.thinking,
                                systemPrompt: systemPrompt,
                                sessionKey: sessionKey,
                                runID: runID,
                                userMessage: message,
                                workspaceRoot: workspaceRoot,
                                maxToolRounds: params.maxToolRounds ?? Self.defaultMaxToolRounds)
                        } catch let error as GatewayLocalLLMProviderError
                            where toolCallingMode == .auto && Self.shouldFallbackToPlainCompletion(error)
                        {
                            let llmResponse = try await provider.complete(
                                GatewayLocalLLMRequest(
                                    messages: llmMessages,
                                    thinkingLevel: parsedPrompt.thinking,
                                    systemPrompt: systemPrompt))
                            chatResult = ChatExecutionResult(
                                response: llmResponse,
                                toolAudits: [],
                                totalRequestBodyBytes: llmResponse.requestBodyBytes,
                                totalInputTokens: llmResponse.usageInputTokens,
                                totalOutputTokens: llmResponse.usageOutputTokens,
                                llmRoundTrips: 1)
                            _ = try await self.memoryStore.appendTurn(
                                sessionKey: sessionKey,
                                role: "system",
                                text: "[tool-mode] auto fallback: tool-calling API rejected by provider",
                                timestampMs: GatewayCore.currentTimestampMs(),
                                runID: runID)
                            await self.sessionStore.recordTurn(
                                sessionKey: sessionKey,
                                nowMs: GatewayCore.currentTimestampMs())
                        }
                    } else {
                        if toolCallingMode == .on {
                            throw GatewayLocalLLMProviderError.invalidRequest(
                                "tool calls are forced on, but provider does not support tool-calling")
                        }
                        let llmResponse = try await provider.complete(
                            GatewayLocalLLMRequest(
                                messages: llmMessages,
                                thinkingLevel: parsedPrompt.thinking,
                                systemPrompt: systemPrompt))
                        chatResult = ChatExecutionResult(
                                response: llmResponse,
                                toolAudits: [],
                                totalRequestBodyBytes: llmResponse.requestBodyBytes,
                                totalInputTokens: llmResponse.usageInputTokens,
                                totalOutputTokens: llmResponse.usageOutputTokens,
                                llmRoundTrips: 1)
                        _ = try await self.memoryStore.appendTurn(
                            sessionKey: sessionKey,
                            role: "system",
                            text: "[tool-mode] auto fallback: provider does not expose tool-calling",
                            timestampMs: GatewayCore.currentTimestampMs(),
                            runID: runID)
                        await self.sessionStore.recordTurn(
                            sessionKey: sessionKey,
                            nowMs: GatewayCore.currentTimestampMs())
                    }
                } else {
                    let llmResponse = try await provider.complete(
                        GatewayLocalLLMRequest(
                            messages: llmMessages,
                            thinkingLevel: parsedPrompt.thinking,
                            systemPrompt: systemPrompt))
                    chatResult = ChatExecutionResult(
                                response: llmResponse,
                                toolAudits: [],
                                totalRequestBodyBytes: llmResponse.requestBodyBytes,
                                totalInputTokens: llmResponse.usageInputTokens,
                                totalOutputTokens: llmResponse.usageOutputTokens,
                                llmRoundTrips: 1)
                }

                _ = try await self.memoryStore.appendTurn(
                    sessionKey: sessionKey,
                    role: "assistant",
                    text: chatResult.response.text,
                    timestampMs: GatewayCore.currentTimestampMs(),
                    runID: runID)
                await self.sessionStore.recordTurn(
                    sessionKey: sessionKey,
                    nowMs: GatewayCore.currentTimestampMs())
                return chatResult
            }

            var usageObject: [String: GatewayJSONValue] = [:]
            if let inputTokens = completion.totalInputTokens {
                usageObject["input"] = .integer(Int64(inputTokens))
            }
            if let outputTokens = completion.totalOutputTokens {
                usageObject["output"] = .integer(Int64(outputTokens))
            }
            if let bodyBytes = completion.totalRequestBodyBytes, bodyBytes > 0 {
                usageObject["requestBodyBytes"] = .integer(Int64(bodyBytes))
            }
            usageObject["llmRoundTrips"] = .integer(Int64(completion.llmRoundTrips))

            var payloadObject: [String: GatewayJSONValue] = [
                "runId": .string(runID),
                "status": .string("completed"),
                "source": .string("local"),
                "provider": .string(completion.response.provider.rawValue),
                "model": .string(completion.response.model),
            ]
            if let transport = completion.response.transport {
                payloadObject["transport"] = .string(transport.rawValue)
            }
            if !usageObject.isEmpty {
                payloadObject["usage"] = .object(usageObject)
            }
            if !completion.toolAudits.isEmpty {
                payloadObject["toolCalls"] = .integer(Int64(completion.toolAudits.count))
                payloadObject["toolExecutions"] = .array(completion.toolAudits.map { audit in
                    .object([
                        "name": .string(audit.name),
                        "ok": .bool(audit.ok),
                        "details": .string(audit.details),
                    ])
                })
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

    private static let defaultMaxToolRounds = 6

    private func runToolAwareChat(
        provider: any GatewayLocalLLMToolCallableProvider,
        llmMessages: [GatewayLocalLLMMessage],
        thinkingLevel: String?,
        systemPrompt: String?,
        sessionKey: String,
        runID: String,
        userMessage: String,
        workspaceRoot: URL?,
        maxToolRounds: Int = defaultMaxToolRounds) async throws -> ChatExecutionResult
    {
        let toolDefinitions = self.chatToolDefinitions(workspaceRoot: workspaceRoot)
        if toolDefinitions.isEmpty {
            let llmResponse = try await provider.complete(
                GatewayLocalLLMRequest(
                    messages: llmMessages,
                    thinkingLevel: thinkingLevel,
                    systemPrompt: systemPrompt))
            return ChatExecutionResult(
                response: llmResponse,
                toolAudits: [],
                totalRequestBodyBytes: llmResponse.requestBodyBytes,
                totalInputTokens: llmResponse.usageInputTokens,
                totalOutputTokens: llmResponse.usageOutputTokens,
                llmRoundTrips: 1)
        }

        var conversation = llmMessages.map { message in
            Self.asToolConversationMessage(historyRole: message.role, text: message.text)
        }
        if let newsRoutingNudge = Self.newsWebRoutingNudge(for: userMessage, tools: toolDefinitions) {
            conversation.append(
                GatewayLocalLLMToolMessage(
                    role: .system,
                    text: newsRoutingNudge))
        }
        var toolAudits: [ChatToolExecutionAudit] = []
        var deferredToolNudgesRemaining = 1
        var accumulatedBodyBytes = 0
        var accumulatedInputTokens = 0
        var accumulatedOutputTokens = 0
        var llmRoundTrips = 0

        let resolvedMaxRounds = max(1, min(maxToolRounds, 20))
        for _ in 0..<resolvedMaxRounds {
            let completion = try await provider.completeWithTools(
                GatewayLocalLLMToolRequest(
                    messages: conversation,
                    tools: toolDefinitions,
                    thinkingLevel: thinkingLevel,
                    systemPrompt: systemPrompt))

            llmRoundTrips += 1
            accumulatedBodyBytes += completion.requestBodyBytes ?? 0
            accumulatedInputTokens += completion.usageInputTokens ?? 0
            accumulatedOutputTokens += completion.usageOutputTokens ?? 0

            let assistantText = completion.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if completion.toolCalls.isEmpty {
                guard !assistantText.isEmpty else {
                    throw GatewayLocalLLMProviderError.invalidResponse(
                        "tool loop ended without assistant text")
                }
                if deferredToolNudgesRemaining > 0,
                   toolAudits.isEmpty,
                   !toolDefinitions.isEmpty,
                   Self.looksLikeDeferredToolPlan(assistantText)
                {
                    deferredToolNudgesRemaining -= 1
                    conversation.append(
                        GatewayLocalLLMToolMessage(
                            role: .assistant,
                            text: assistantText))
                    _ = try await self.memoryStore.appendTurn(
                        sessionKey: sessionKey,
                        role: "assistant",
                        text: "[tool-plan] \(assistantText)",
                        timestampMs: GatewayCore.currentTimestampMs(),
                        runID: runID)
                    await self.sessionStore.recordTurn(sessionKey: sessionKey, nowMs: GatewayCore.currentTimestampMs())
                    conversation.append(
                        GatewayLocalLLMToolMessage(
                            role: .system,
                            text: Self.deferredToolExecutionNudge))
                    continue
                }
                let response = GatewayLocalLLMResponse(
                    text: assistantText,
                    model: completion.model,
                    provider: completion.provider,
                    transport: completion.transport,
                    usageInputTokens: completion.usageInputTokens,
                    usageOutputTokens: completion.usageOutputTokens)
                return ChatExecutionResult(
                    response: response,
                    toolAudits: toolAudits,
                    totalRequestBodyBytes: accumulatedBodyBytes,
                    totalInputTokens: accumulatedInputTokens > 0 ? accumulatedInputTokens : nil,
                    totalOutputTokens: accumulatedOutputTokens > 0 ? accumulatedOutputTokens : nil,
                    llmRoundTrips: llmRoundTrips)
            }

            conversation.append(
                GatewayLocalLLMToolMessage(
                    role: .assistant,
                    text: assistantText.isEmpty ? nil : assistantText,
                    toolCalls: completion.toolCalls))

            if !assistantText.isEmpty {
                _ = try await self.memoryStore.appendTurn(
                    sessionKey: sessionKey,
                    role: "assistant",
                    text: "[tool-plan] \(assistantText)",
                    timestampMs: GatewayCore.currentTimestampMs(),
                    runID: runID)
                await self.sessionStore.recordTurn(sessionKey: sessionKey, nowMs: GatewayCore.currentTimestampMs())
            }

            for toolCall in completion.toolCalls {
                _ = try await self.memoryStore.appendTurn(
                    sessionKey: sessionKey,
                    role: "tool",
                    text: "tool.call \(toolCall.name) args=\(Self.clampUTF16(toolCall.argumentsJSON, to: 2000))",
                    timestampMs: GatewayCore.currentTimestampMs(),
                    runID: runID)
                await self.sessionStore.recordTurn(sessionKey: sessionKey, nowMs: GatewayCore.currentTimestampMs())

                let toolParams = Self.decodeToolArguments(toolCall.argumentsJSON)
                let result = await GatewayLocalTooling.execute(
                    command: toolCall.name,
                    params: toolParams,
                    hostLabel: self.config.hostLabel,
                    workspaceRoot: workspaceRoot,
                    urlSession: self.urlSession,
                    upstreamForwarder: self.config.upstreamForwarder,
                    telegramConfig: self.config.telegramConfig,
                    enableLocalSafeTools: self.config.enableLocalSafeTools,
                    enableLocalFileTools: self.config.enableLocalFileTools,
                    enableLocalDeviceTools: self.config.enableLocalDeviceTools,
                    deviceToolBridge: self.config.deviceToolBridge)

                let resultText: String
                let ok: Bool
                var imageBase64: String?
                var imageMimeType: String?
                if let error = result.error {
                    ok = false
                    resultText = "error: \(error)"
                } else {
                    ok = true
                    // For image-producing tools, extract the base64 image
                    // data so it can be sent as a vision content block
                    // instead of a truncated text blob.
                    let extracted = Self.extractImageFromPayload(
                        command: toolCall.name,
                        payload: result.payload)
                    resultText = (try? extracted.strippedPayload.jsonString()) ?? "ok"
                    imageBase64 = extracted.base64
                    imageMimeType = extracted.mimeType
                    if let b64 = imageBase64 {
                        print("[OpenClawGatewayCore][ToolRouter] tool=\(toolCall.name)"
                            + " imageExtracted=true"
                            + " imageBase64Len=\(b64.count)"
                            + " mimeType=\(imageMimeType ?? "nil")"
                            + " resultTextLen=\(resultText.count)")
                    }
                }
                let normalizedResultText = Self.clampUTF16(resultText, to: 8000)
                toolAudits.append(
                    ChatToolExecutionAudit(
                        name: toolCall.name,
                        ok: ok,
                        details: normalizedResultText))

                _ = try await self.memoryStore.appendTurn(
                    sessionKey: sessionKey,
                    role: "tool",
                    text: "tool.result \(toolCall.name) \(normalizedResultText)",
                    timestampMs: GatewayCore.currentTimestampMs(),
                    runID: runID)
                await self.sessionStore.recordTurn(sessionKey: sessionKey, nowMs: GatewayCore.currentTimestampMs())

                conversation.append(
                    GatewayLocalLLMToolMessage(
                        role: .tool,
                        text: normalizedResultText,
                        toolCallID: toolCall.id,
                        name: toolCall.name,
                        imageDataBase64: imageBase64,
                        imageMimeType: imageMimeType))
            }
        }

        throw GatewayLocalLLMProviderError.invalidResponse("tool loop exceeded max iterations")
    }

    private static let imageToolCommands: Set<String> = [
        "camera.snap", "photos.latest",
    ]

    private struct ImageExtraction {
        var strippedPayload: GatewayJSONValue
        var base64: String?
        var mimeType: String?
    }

    /// Maximum width (px) for images sent to the LLM as vision content.
    /// Keeps base64 payloads under ~100 KB.
    private static let llmImageMaxWidth = 512

    /// For image-producing tools (`camera.snap`, `photos.latest`), pull
    /// the base64 image data out of the payload and return a stripped
    /// payload (with `"base64"` replaced by `"[image attached]"`) plus
    /// the raw base64 and MIME type for multimodal content blocks.
    /// The image is down-scaled to `llmImageMaxWidth` to keep payload
    /// sizes manageable.
    private static func extractImageFromPayload(
        command: String,
        payload: GatewayJSONValue) -> ImageExtraction
    {
        guard imageToolCommands.contains(command) else {
            return ImageExtraction(strippedPayload: payload)
        }

        // camera.snap: top-level { "base64": "...", "format": "jpg", ... }
        if case .object(var dict) = payload,
           case let .string(b64) = dict["base64"],
           !b64.isEmpty
        {
            let resized = resizeBase64JPEG(b64, maxWidth: llmImageMaxWidth)
            dict["base64"] = .string("[image attached]")
            return ImageExtraction(
                strippedPayload: .object(dict),
                base64: resized,
                mimeType: "image/jpeg")
        }

        // photos.latest: { "photos": [ { "base64": "...", ... }, ... ] }
        // Attach only the first photo's image.
        if case .object(var dict) = payload,
           case .array(var photos) = dict["photos"],
           !photos.isEmpty,
           case .object(var firstPhoto) = photos[0],
           case let .string(b64) = firstPhoto["base64"],
           !b64.isEmpty
        {
            let resized = resizeBase64JPEG(b64, maxWidth: llmImageMaxWidth)
            firstPhoto["base64"] = .string("[image attached]")
            photos[0] = .object(firstPhoto)
            dict["photos"] = .array(photos)
            return ImageExtraction(
                strippedPayload: .object(dict),
                base64: resized,
                mimeType: "image/jpeg")
        }

        return ImageExtraction(strippedPayload: payload)
    }

    /// Decode a base64-encoded image, resize to `maxWidth` (preserving
    /// aspect ratio), and re-encode as JPEG at 0.7 quality.
    /// Returns the original base64 if decoding or resizing fails.
    private static func resizeBase64JPEG(_ base64: String, maxWidth: Int) -> String {
        guard let data = Data(base64Encoded: base64) else { return base64 }
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { return base64 }

        let srcW = cgImage.width
        let srcH = cgImage.height
        guard srcW > maxWidth else { return base64 }

        let scale = CGFloat(maxWidth) / CGFloat(srcW)
        let dstW = maxWidth
        let dstH = Int(CGFloat(srcH) * scale)

        guard let ctx = CGContext(
            data: nil,
            width: dstW,
            height: dstH,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return base64 }

        ctx.interpolationQuality = .high
        ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: dstW, height: dstH))
        guard let resized = ctx.makeImage() else { return base64 }

        let mutableData = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(
            mutableData as CFMutableData,
            "public.jpeg" as CFString,
            1, nil)
        else { return base64 }
        let options: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: 0.7,
        ]
        CGImageDestinationAddImage(dest, resized, options as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return base64 }

        return (mutableData as Data).base64EncodedString()
    }

    private static let deferredToolExecutionNudge =
        "When tools are available and you state an action like fetching/checking/searching, issue tool calls in this same turn. Do not wait for user confirmation like 'proceed' for safe local tool actions."

    private static let newsWebToolRoutingNudge =
        "For news or website tasks, prefer web.render first (especially JS-heavy sites). If cleanup/normalization is needed, run web.extract before answering. Avoid raw snippet-only outputs from network.fetch/web.fetch unless no better source is available."

    private static func newsWebRoutingNudge(
        for userMessage: String,
        tools: [GatewayLocalLLMToolDefinition]) -> String?
    {
        let lowered = userMessage.lowercased()
        let hasURL = lowered.contains("http://") || lowered.contains("https://")
        let newsSignals = [
            "news",
            "headline",
            "headlines",
            "article",
            "articles",
            "today",
            "latest",
            "breaking",
            "what's happening",
            "what is happening",
        ]
        let webSignals = [
            "website",
            "web site",
            "webpage",
            "web page",
            "site",
            "url",
            "link",
            "apple neural engine",
        ]
        let hasSignal = hasURL
            || newsSignals.contains(where: { lowered.contains($0) })
            || webSignals.contains(where: { lowered.contains($0) })
        guard hasSignal else {
            return nil
        }

        let availableTools = Set(tools.map(\.name))
        guard availableTools.contains("web.render") else {
            return nil
        }
        if availableTools.contains("web.extract") {
            return Self.newsWebToolRoutingNudge
        }
        return "For news or website tasks, prefer web.render over raw fetch tools."
    }

    private static func looksLikeDeferredToolPlan(_ text: String) -> Bool {
        let lowered = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !lowered.isEmpty else {
            return false
        }

        let progressivePrefixes = [
            "fetching ",
            "checking ",
            "gathering ",
            "searching ",
            "looking up ",
            "running ",
            "trying ",
        ]
        if progressivePrefixes.contains(where: { lowered.hasPrefix($0) }) {
            return true
        }

        let intentPhrases = [
            "let me ",
            "i'll ",
            "i will ",
            "i'm going to ",
        ]
        let actionWords = [
            "fetch",
            "check",
            "search",
            "gather",
            "look up",
            "analy",
            "scan",
            "test",
            "crawl",
            "scrape",
        ]
        let hasIntent = intentPhrases.contains(where: { lowered.contains($0) })
        let hasAction = actionWords.contains(where: { lowered.contains($0) })
        if hasIntent, hasAction {
            return true
        }

        return lowered.contains("now:") && hasAction
    }

    private static func shouldFallbackToPlainCompletion(_ error: GatewayLocalLLMProviderError) -> Bool {
        func looksToolUnsupported(_ text: String) -> Bool {
            let lowered = text.lowercased()
            let mentionsToolSurface =
                lowered.contains("tool")
                || lowered.contains("\"tools\"")
                || lowered.contains("'tools'")
                || lowered.contains("tool_choice")
                || lowered.contains("tool_use")
            guard mentionsToolSurface else {
                return false
            }
            return lowered.contains("unsupported")
                || lowered.contains("not support")
                || lowered.contains("not supported")
                || lowered.contains("unrecognized")
                || lowered.contains("unknown parameter")
                || lowered.contains("unknown field")
                || lowered.contains("invalid")
                || lowered.contains("does not support")
        }

        switch error {
        case let .httpError(status, message):
            guard [400, 404, 405, 415, 422, 501].contains(status) else {
                return false
            }
            return looksToolUnsupported(message)
        case let .invalidResponse(message):
            return looksToolUnsupported(message)
        case .invalidRequest, .notConfigured:
            return false
        }
    }

    private func chatToolDefinitions(workspaceRoot: URL?) -> [GatewayLocalLLMToolDefinition] {
        var tools: [GatewayLocalLLMToolDefinition] = []

        if self.config.enableLocalSafeTools {
            tools.append(
                GatewayLocalLLMToolDefinition(
                    name: "time.now",
                    description: "Return current time metadata for this device",
                    parameters: .object([:])))
            tools.append(
                GatewayLocalLLMToolDefinition(
                    name: "device.info",
                    description: "Return local device metadata",
                    parameters: .object([:])))
            tools.append(
                GatewayLocalLLMToolDefinition(
                    name: "network.fetch",
                    description: "Perform HTTP GET for APIs/plain endpoints (not ideal for JS-rendered news pages)",
                    parameters: .object([
                        "type": .string("object"),
                        "properties": .object([
                            "url": .object([
                                "type": .string("string"),
                                "description": .string("Absolute URL"),
                            ]),
                            "timeoutMs": .object([
                                "type": .string("integer"),
                            ]),
                            "headers": .object([
                                "type": .string("object"),
                            ]),
                        ]),
                        "required": .array([.string("url")]),
                    ])))
            tools.append(
                GatewayLocalLLMToolDefinition(
                    name: "web.fetch",
                    description: "Fetch plain web content (HTTP only, no JS rendering)",
                    parameters: .object([
                        "type": .string("object"),
                        "properties": .object([
                            "url": .object([
                                "type": .string("string"),
                                "description": .string("Absolute URL"),
                            ]),
                            "timeoutMs": .object([
                                "type": .string("integer"),
                            ]),
                            "headers": .object([
                                "type": .string("object"),
                            ]),
                            "maxChars": .object([
                                "type": .string("integer"),
                            ]),
                        ]),
                        "required": .array([.string("url")]),
                    ])))
            tools.append(
                GatewayLocalLLMToolDefinition(
                    name: "web.extract",
                    description: "Normalize page content into title/text/links/metadata (use after web.render/web.fetch when needed)",
                    parameters: .object([
                        "type": .string("object"),
                        "properties": .object([
                            "url": .object([
                                "type": .string("string"),
                                "description": .string("URL to fetch before extraction"),
                            ]),
                            "html": .object([
                                "type": .string("string"),
                                "description": .string("Raw HTML content to normalize"),
                            ]),
                            "text": .object([
                                "type": .string("string"),
                                "description": .string("Plain text content to normalize"),
                            ]),
                            "maxChars": .object([
                                "type": .string("integer"),
                            ]),
                            "includeLinks": .object([
                                "type": .string("boolean"),
                            ]),
                        ]),
                    ])))
            tools.append(
                GatewayLocalLLMToolDefinition(
                    name: "web.render",
                    description: "Primary web tool for JS-heavy pages/news: render + extract text/links; upstream browser when configured",
                    parameters: .object([
                        "type": .string("object"),
                        "properties": .object([
                            "url": .object([
                                "type": .string("string"),
                                "description": .string("Absolute URL (recommended for live pages)"),
                            ]),
                            "html": .object([
                                "type": .string("string"),
                                "description": .string("Optional inline HTML source for local rendering"),
                            ]),
                            "text": .object([
                                "type": .string("string"),
                                "description": .string("Optional plain text source for local normalization"),
                            ]),
                            "timeoutMs": .object([
                                "type": .string("integer"),
                            ]),
                            "waitUntil": .object([
                                "type": .string("string"),
                            ]),
                            "maxChars": .object([
                                "type": .string("integer"),
                            ]),
                            "includeLinks": .object([
                                "type": .string("boolean"),
                            ]),
                        ]),
                    ])))
            if self.config.telegramConfig.isConfigured {
                tools.append(
                    GatewayLocalLLMToolDefinition(
                        name: "telegram.send",
                        description: "Send Telegram message (external action). Use only when user/task explicitly requests alerts/notifications.",
                        parameters: .object([
                            "type": .string("object"),
                            "properties": .object([
                                "chatId": .object([
                                    "type": .string("string"),
                                    "description": .string("Optional chat ID. Uses configured default when omitted."),
                                ]),
                                "to": .object([
                                    "type": .string("string"),
                                    "description": .string("Alias for chatId."),
                                ]),
                                "text": .object([
                                    "type": .string("string"),
                                    "description": .string("Message text to send."),
                                ]),
                                "parseMode": .object([
                                    "type": .string("string"),
                                    "description": .string("Optional parse mode (HTML/MarkdownV2/Markdown)."),
                                ]),
                                "disableWebPagePreview": .object([
                                    "type": .string("boolean"),
                                ]),
                                "disableNotification": .object([
                                    "type": .string("boolean"),
                                ]),
                            ]),
                            "required": .array([.string("text")]),
                        ])))
            }
        }

        if self.config.enableLocalFileTools, workspaceRoot != nil {
            tools.append(
                GatewayLocalLLMToolDefinition(
                    name: "read",
                    description: "Read a UTF-8 text file from workspace",
                    parameters: .object([
                        "type": .string("object"),
                        "properties": .object([
                            "path": .object([
                                "type": .string("string"),
                                "description": .string("Workspace-relative path"),
                            ]),
                            "maxChars": .object([
                                "type": .string("integer"),
                            ]),
                        ]),
                        "required": .array([.string("path")]),
                    ])))
            tools.append(
                GatewayLocalLLMToolDefinition(
                    name: "write",
                    description: "Write full UTF-8 file content in workspace. "
                        + "Skill files MUST be written to skills/<name>/SKILL.md",
                    parameters: .object([
                        "type": .string("object"),
                        "properties": .object([
                            "path": .object([
                                "type": .string("string"),
                                "description": .string(
                                    "Relative path from workspace root. "
                                        + "Use skills/<name>/SKILL.md for skill files."),
                            ]),
                            "content": .object([
                                "type": .string("string"),
                            ]),
                        ]),
                        "required": .array([.string("path"), .string("content")]),
                    ])))
            tools.append(
                GatewayLocalLLMToolDefinition(
                    name: "edit",
                    description: "Replace oldText with newText in a workspace file",
                    parameters: .object([
                        "type": .string("object"),
                        "properties": .object([
                            "path": .object(["type": .string("string")]),
                            "oldText": .object(["type": .string("string")]),
                            "newText": .object(["type": .string("string")]),
                            "replaceAll": .object(["type": .string("boolean")]),
                        ]),
                        "required": .array([.string("path"), .string("oldText"), .string("newText")]),
                    ])))
            tools.append(
                GatewayLocalLLMToolDefinition(
                    name: "apply_patch",
                    description: "Apply unified patch format with Begin/End Patch markers",
                    parameters: .object([
                        "type": .string("object"),
                        "properties": .object([
                            "input": .object(["type": .string("string")]),
                        ]),
                        "required": .array([.string("input")]),
                    ])))
            tools.append(
                GatewayLocalLLMToolDefinition(
                    name: "ls",
                    description: "List files and directories in the workspace. Returns name, type (file/directory), and size.",
                    parameters: .object([
                        "type": .string("object"),
                        "properties": .object([
                            "path": .object([
                                "type": .string("string"),
                                "description": .string("Relative path inside workspace. Defaults to root (\".\")."),
                            ]),
                            "recursive": .object([
                                "type": .string("boolean"),
                                "description": .string("If true, list all files recursively. Default false."),
                            ]),
                        ]),
                    ])))
        }

        // -- Device tools (native iOS capabilities via bridge) --
        if self.config.enableLocalDeviceTools, let bridge = self.config.deviceToolBridge {
            let supported = bridge.supportedCommands()

            if supported.contains("reminders.list") {
                tools.append(GatewayLocalLLMToolDefinition(
                    name: "reminders.list",
                    description: "List iOS reminders. Returns title, due date, completion status.",
                    parameters: .object([
                        "type": .string("object"),
                        "properties": .object([
                            "status": .object([
                                "type": .string("string"),
                                "description": .string("Filter: incomplete, completed, or all"),
                            ]),
                            "limit": .object(["type": .string("integer")]),
                        ]),
                    ])))
            }
            if supported.contains("reminders.add") {
                tools.append(GatewayLocalLLMToolDefinition(
                    name: "reminders.add",
                    description: "Create a new iOS reminder",
                    parameters: .object([
                        "type": .string("object"),
                        "properties": .object([
                            "title": .object(["type": .string("string")]),
                            "dueISO": .object([
                                "type": .string("string"),
                                "description": .string("ISO-8601 due date"),
                            ]),
                            "notes": .object(["type": .string("string")]),
                            "listName": .object(["type": .string("string")]),
                        ]),
                        "required": .array([.string("title")]),
                    ])))
            }
            if supported.contains("calendar.events") {
                tools.append(GatewayLocalLLMToolDefinition(
                    name: "calendar.events",
                    description: "Query iOS calendar events in a date range",
                    parameters: .object([
                        "type": .string("object"),
                        "properties": .object([
                            "startISO": .object([
                                "type": .string("string"),
                                "description": .string("ISO-8601 start (default: now)"),
                            ]),
                            "endISO": .object([
                                "type": .string("string"),
                                "description": .string("ISO-8601 end (default: +7 days)"),
                            ]),
                            "limit": .object(["type": .string("integer")]),
                        ]),
                    ])))
            }
            if supported.contains("calendar.add") {
                tools.append(GatewayLocalLLMToolDefinition(
                    name: "calendar.add",
                    description: "Create a new iOS calendar event",
                    parameters: .object([
                        "type": .string("object"),
                        "properties": .object([
                            "title": .object(["type": .string("string")]),
                            "startISO": .object(["type": .string("string")]),
                            "endISO": .object(["type": .string("string")]),
                            "location": .object(["type": .string("string")]),
                            "notes": .object(["type": .string("string")]),
                            "isAllDay": .object(["type": .string("boolean")]),
                        ]),
                        "required": .array([.string("title"), .string("startISO"), .string("endISO")]),
                    ])))
            }
            if supported.contains("contacts.search") {
                tools.append(GatewayLocalLLMToolDefinition(
                    name: "contacts.search",
                    description: "Search iOS contacts by name",
                    parameters: .object([
                        "type": .string("object"),
                        "properties": .object([
                            "query": .object(["type": .string("string")]),
                            "limit": .object(["type": .string("integer")]),
                        ]),
                    ])))
            }
            if supported.contains("contacts.add") {
                tools.append(GatewayLocalLLMToolDefinition(
                    name: "contacts.add",
                    description: "Add a new iOS contact",
                    parameters: .object([
                        "type": .string("object"),
                        "properties": .object([
                            "givenName": .object(["type": .string("string")]),
                            "familyName": .object(["type": .string("string")]),
                            "phoneNumbers": .object([
                                "type": .string("array"),
                                "items": .object(["type": .string("string")]),
                            ]),
                            "emails": .object([
                                "type": .string("array"),
                                "items": .object(["type": .string("string")]),
                            ]),
                        ]),
                    ])))
            }
            if supported.contains("location.get") {
                tools.append(GatewayLocalLLMToolDefinition(
                    name: "location.get",
                    description: "Get current GPS coordinates of this device",
                    parameters: .object([
                        "type": .string("object"),
                        "properties": .object([
                            "desiredAccuracy": .object([
                                "type": .string("string"),
                                "description": .string("coarse, balanced, or precise"),
                            ]),
                        ]),
                    ])))
            }
            if supported.contains("photos.latest") {
                tools.append(GatewayLocalLLMToolDefinition(
                    name: "photos.latest",
                    description: "Get recent photos from the device photo library as base64 JPEG",
                    parameters: .object([
                        "type": .string("object"),
                        "properties": .object([
                            "limit": .object(["type": .string("integer")]),
                            "maxWidth": .object(["type": .string("integer")]),
                            "quality": .object(["type": .string("number")]),
                        ]),
                    ])))
            }
            if supported.contains("camera.snap") {
                tools.append(GatewayLocalLLMToolDefinition(
                    name: "camera.snap",
                    description: "Take a photo with the device camera (requires foreground)",
                    parameters: .object([
                        "type": .string("object"),
                        "properties": .object([
                            "facing": .object([
                                "type": .string("string"),
                                "description": .string("back or front"),
                            ]),
                            "maxWidth": .object(["type": .string("integer")]),
                            "quality": .object(["type": .string("number")]),
                        ]),
                    ])))
            }
            if supported.contains("motion.activity") {
                tools.append(GatewayLocalLLMToolDefinition(
                    name: "motion.activity",
                    description: "Query device motion activity history (walking, running, driving)",
                    parameters: .object([
                        "type": .string("object"),
                        "properties": .object([
                            "startISO": .object(["type": .string("string")]),
                            "endISO": .object(["type": .string("string")]),
                            "limit": .object(["type": .string("integer")]),
                        ]),
                    ])))
            }
            if supported.contains("motion.pedometer") {
                tools.append(GatewayLocalLLMToolDefinition(
                    name: "motion.pedometer",
                    description: "Query pedometer data (steps, distance, floors)",
                    parameters: .object([
                        "type": .string("object"),
                        "properties": .object([
                            "startISO": .object(["type": .string("string")]),
                            "endISO": .object(["type": .string("string")]),
                        ]),
                    ])))
            }

            // -- Credential tools (secure API key storage) --
            if supported.contains("credentials.get") {
                tools.append(GatewayLocalLLMToolDefinition(
                    name: "credentials.get",
                    description: "Retrieve a stored API key from the device keychain. Returns hasKey and key if found.",
                    parameters: .object([
                        "type": .string("object"),
                        "properties": .object([
                            "service": .object([
                                "type": .string("string"),
                                "description": .string("Service identifier (e.g. notion, trello.key, trello.token)"),
                            ]),
                        ]),
                        "required": .array([.string("service")]),
                    ])))
            }
            if supported.contains("credentials.set") {
                tools.append(GatewayLocalLLMToolDefinition(
                    name: "credentials.set",
                    description: "Store an API key securely in the device keychain. Persists across sessions.",
                    parameters: .object([
                        "type": .string("object"),
                        "properties": .object([
                            "service": .object([
                                "type": .string("string"),
                                "description": .string("Service identifier (e.g. notion, trello.key)"),
                            ]),
                            "key": .object([
                                "type": .string("string"),
                                "description": .string("The API key or token to store"),
                            ]),
                        ]),
                        "required": .array([.string("service"), .string("key")]),
                    ])))
            }
            if supported.contains("credentials.delete") {
                tools.append(GatewayLocalLLMToolDefinition(
                    name: "credentials.delete",
                    description: "Remove a stored API key from the device keychain.",
                    parameters: .object([
                        "type": .string("object"),
                        "properties": .object([
                            "service": .object([
                                "type": .string("string"),
                                "description": .string("Service identifier to remove"),
                            ]),
                        ]),
                        "required": .array([.string("service")]),
                    ])))
            }

            // -- Dream mode tools --
            if supported.contains("get_idle_time") {
                tools.append(GatewayLocalLLMToolDefinition(
                    name: "get_idle_time",
                    description: "Get seconds since last user interaction (tap, typing, message). Returns idle duration and dream mode state.",
                    parameters: .object([
                        "type": .string("object"),
                        "properties": .object([:]),
                    ])))
            }
            if supported.contains("dream_mode") {
                tools.append(GatewayLocalLLMToolDefinition(
                    name: "dream_mode",
                    description: "Enter or exit dream mode. Dream mode shows ambient animation while background tasks run. Returns runId, outputRoot, and writeMode for artifact management.",
                    parameters: .object([
                        "type": .string("object"),
                        "properties": .object([
                            "action": .object([
                                "type": .string("string"),
                                "description": .string("enter, exit, or status"),
                            ]),
                            "outputRoot": .object([
                                "type": .string("string"),
                                "description": .string("Directory for dream artifacts, default 'dream'"),
                            ]),
                            "writeMode": .object([
                                "type": .string("string"),
                                "description": .string("'patches' (default) or 'apply_safe'"),
                            ]),
                        ]),
                        "required": .array([.string("action")]),
                    ])))
            }
        }

        if !self.config.disabledToolNames.isEmpty {
            tools.removeAll { self.config.disabledToolNames.contains($0.name) }
        }
        return tools
    }

    private static func asToolConversationMessage(
        historyRole rawRole: String,
        text: String) -> GatewayLocalLLMToolMessage
    {
        let role = rawRole.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch role {
        case "assistant":
            return GatewayLocalLLMToolMessage(role: .assistant, text: text)
        case "system":
            return GatewayLocalLLMToolMessage(role: .system, text: text)
        case "tool":
            return GatewayLocalLLMToolMessage(role: .user, text: "Tool audit: \(text)")
        default:
            return GatewayLocalLLMToolMessage(role: .user, text: text)
        }
    }

    private static func decodeToolArguments(_ raw: String) -> GatewayJSONValue? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return .object([:])
        }
        guard let data = trimmed.data(using: .utf8) else {
            return nil
        }
        return try? JSONDecoder().decode(GatewayJSONValue.self, from: data)
    }

    private func handleChatHistory(_ request: GatewayRequestFrame) async -> GatewayResponseFrame? {
        guard let params = GatewayPayloadCodec.decode(request.params, as: ChatHistoryParams.self) else {
            return GatewayResponseFrame.failure(
                id: request.id,
                code: .invalidRequest,
                message: "invalid chat.history params")
        }
        let sessionKey = Self.normalizedSessionKey(params.sessionKey)
        let limit = max(1, min(params.limit ?? 200, 1000))

        do {
            let turns = try await self.memoryStore.history(sessionKey: sessionKey, limit: limit)
            let messages = turns.map(Self.asChatHistoryMessage)
            let snapshot = await self.sessionStore.snapshot(sessionKey: sessionKey)
            let thinkingLevel = snapshot.thinkingLevel ?? "low"
            let payload: GatewayJSONValue = .object([
                "sessionKey": .string(sessionKey),
                "sessionId": .string(sessionKey),
                "thinkingLevel": .string(thinkingLevel),
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
        struct SessionEntryAggregate {
            var sessionKey: String
            var lastActivityMs: Int64
            var turnCount: Int
            var thinkingLevel: String?
        }

        var bySessionKey: [String: SessionEntryAggregate] = [:]
        let snapshots = await self.sessionStore.snapshots()
        for snapshot in snapshots {
            bySessionKey[snapshot.sessionKey] = SessionEntryAggregate(
                sessionKey: snapshot.sessionKey,
                lastActivityMs: snapshot.lastActivityMs,
                turnCount: snapshot.turnCount,
                thinkingLevel: snapshot.thinkingLevel)
        }

        do {
            let persistedSummaries = try await self.memoryStore.sessionSummaries(limit: max(limit * 4, 200))
            for summary in persistedSummaries {
                if var existing = bySessionKey[summary.sessionKey] {
                    existing.lastActivityMs = max(existing.lastActivityMs, summary.lastActivityMs)
                    existing.turnCount = max(existing.turnCount, summary.turnCount)
                    bySessionKey[summary.sessionKey] = existing
                } else {
                    bySessionKey[summary.sessionKey] = SessionEntryAggregate(
                        sessionKey: summary.sessionKey,
                        lastActivityMs: summary.lastActivityMs,
                        turnCount: summary.turnCount,
                        thinkingLevel: nil)
                }
            }
        } catch {
            // Keep sessions.list resilient even if sqlite lookup fails.
        }

        let sessions = bySessionKey.values
            .sorted { $0.lastActivityMs > $1.lastActivityMs }
            .prefix(limit)
            .map { aggregate -> GatewayJSONValue in
                let thinkingLevel = aggregate.thinkingLevel ?? "low"
                var object: [String: GatewayJSONValue] = [
                    "key": .string(aggregate.sessionKey),
                    "displayName": .string(aggregate.sessionKey),
                    "updatedAt": .double(Double(aggregate.lastActivityMs)),
                    "sessionId": .string(aggregate.sessionKey),
                    "thinkingLevel": .string(thinkingLevel),
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

    private func handleSessionsDelete(_ request: GatewayRequestFrame) async -> GatewayResponseFrame? {
        guard let params = GatewayPayloadCodec.decode(request.params, as: SessionsDeleteParams.self) else {
            return GatewayResponseFrame.failure(
                id: request.id,
                code: .invalidRequest,
                message: "invalid sessions.delete params: key required")
        }

        let key = params.key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else {
            return GatewayResponseFrame.failure(
                id: request.id,
                code: .invalidRequest,
                message: "sessions.delete: key must not be empty")
        }

        let deleteTranscript = params.deleteTranscript ?? true

        // For "main", clear transcripts but keep the session entry.
        if key == "main" {
            if deleteTranscript {
                do {
                    _ = try await self.memoryStore.deleteTranscripts(sessionKey: key)
                } catch {
                    // Best-effort
                }
            }
            // Reset the in-memory session context (clears history).
            await self.sessionStore.removeSession(sessionKey: key)
            return GatewayResponseFrame.success(
                id: request.id,
                payload: .object([
                    "ok": .bool(true),
                    "key": .string(key),
                    "cleared": .bool(true),
                ]))
        }

        // Remove from in-memory session store.
        await self.sessionStore.removeSession(sessionKey: key)

        // Delete persisted transcripts if requested.
        if deleteTranscript {
            do {
                _ = try await self.memoryStore.deleteTranscripts(sessionKey: key)
            } catch {
                // Best-effort: session is removed from store even if transcript cleanup fails.
            }
        }

        let payload: GatewayJSONValue = .object([
            "ok": .bool(true),
            "key": .string(key),
            "deleted": .bool(true),
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
            let transcriptHits = try await self.memoryStore.search(
                query: query,
                sessionKey: params.sessionKey,
                limit: limit)
            var resultItems = transcriptHits.map { hit -> GatewayJSONValue in
                var object: [String: GatewayJSONValue] = [
                    "id": .string("turn:\(hit.turn.id)"),
                    "sessionKey": .string(hit.turn.sessionKey),
                    "role": .string(hit.turn.role),
                    "text": .string(hit.turn.text),
                    "timestampMs": .integer(hit.turn.timestampMs),
                    "source": .string("transcript"),
                ]
                if let score = hit.score {
                    object["score"] = .double(score)
                } else {
                    object["score"] = .null
                }
                return .object(object)
            }

            let remaining = max(0, limit - resultItems.count)
            if remaining > 0 {
                let workspaceHits = self.searchWorkspaceMemory(query: query, limit: remaining)
                resultItems.append(contentsOf: workspaceHits.map { hit in
                    .object([
                        "id": .string(hit.id),
                        "sessionKey": .string("workspace-memory"),
                        "role": .string("memory"),
                        "text": .string(hit.text),
                        "timestampMs": .integer(0),
                        "score": .double(hit.score),
                        "source": .string("workspace-memory"),
                        "file": .string(hit.file),
                        "lineStart": .integer(Int64(hit.lineStart)),
                        "lineEnd": .integer(Int64(hit.lineEnd)),
                    ])
                })
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

        if let rawID = params.id.stringValue,
           let workspaceReference = Self.parseWorkspaceMemoryID(rawID)
        {
            guard let workspaceTurn = self.loadWorkspaceMemory(reference: workspaceReference) else {
                return GatewayResponseFrame.failure(
                    id: request.id,
                    code: .invalidRequest,
                    message: "workspace memory not found: \(rawID)")
            }
            let payload: GatewayJSONValue = .object([
                "id": .string(rawID),
                "sessionKey": .string("workspace-memory"),
                "role": .string("memory"),
                "text": .string(workspaceTurn.text),
                "timestampMs": .integer(Int64(GatewayCore.currentTimestampMs())),
                "runId": .null,
                "source": .string("workspace-memory"),
                "file": .string(workspaceTurn.file),
                "lineStart": .integer(Int64(workspaceTurn.lineStart)),
                "lineEnd": .integer(Int64(workspaceTurn.lineEnd)),
            ])
            return GatewayResponseFrame.success(id: request.id, payload: payload)
        }

        guard let turnID = Self.turnID(from: params.id) else {
            return GatewayResponseFrame.failure(
                id: request.id,
                code: .invalidRequest,
                message: "invalid memory.get params: id must be turn:<id>, filemem:<id>, or integer")
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
                "source": .string("transcript"),
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

    private func handleMemoryAppend(_ request: GatewayRequestFrame, nowMs: Int64) async -> GatewayResponseFrame? {
        guard let params = GatewayPayloadCodec.decode(request.params, as: MemoryAppendParams.self) else {
            return GatewayResponseFrame.failure(
                id: request.id,
                code: .invalidRequest,
                message: "invalid memory.append params")
        }

        let rawText = params.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rawText.isEmpty else {
            return GatewayResponseFrame.failure(
                id: request.id,
                code: .invalidRequest,
                message: "invalid memory.append params: text required")
        }

        guard let workspaceRoot = self.workspaceRootURL() else {
            if self.config.upstreamConfigured {
                return nil
            }
            return Self.upstreamRequired(
                id: request.id,
                method: request.method,
                hint: "workspace memory path unavailable")
        }

        let relativePath = Self.defaultMemoryWritePath(nowMs: nowMs)
        let requestedPath = params.path?.trimmingCharacters(in: .whitespacesAndNewlines)
        let targetPath = (requestedPath?.isEmpty == false ? requestedPath! : relativePath)

        guard Self.isAllowedMemoryWritePath(targetPath) else {
            return GatewayResponseFrame.failure(
                id: request.id,
                code: .invalidRequest,
                message: "memory.append path must be MEMORY.md, memory.md, or memory/*.md")
        }

        let targetURL = workspaceRoot.appendingPathComponent(targetPath)
        let rootPath = workspaceRoot.standardizedFileURL.path
        let filePath = targetURL.standardizedFileURL.path
        let rootPrefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        guard filePath == rootPath || filePath.hasPrefix(rootPrefix) else {
            return GatewayResponseFrame.failure(
                id: request.id,
                code: .invalidRequest,
                message: "memory.append path escapes workspace root")
        }

        do {
            let fileManager = FileManager.default
            let parent = targetURL.deletingLastPathComponent()
            try fileManager.createDirectory(at: parent, withIntermediateDirectories: true)

            let shouldAppend = params.append ?? true
            let normalizedText = rawText.replacingOccurrences(of: "\r\n", with: "\n")
            let finalText: String

            if shouldAppend, let existing = try? String(contentsOf: targetURL, encoding: .utf8) {
                var next = existing
                if !next.isEmpty, !next.hasSuffix("\n") {
                    next += "\n"
                }
                if !next.isEmpty {
                    next += "\n"
                }
                next += normalizedText
                finalText = Self.ensureTrailingNewline(next)
            } else if shouldAppend {
                finalText = Self.ensureTrailingNewline(normalizedText)
            } else {
                finalText = Self.ensureTrailingNewline(normalizedText)
            }

            try finalText.write(to: targetURL, atomically: true, encoding: .utf8)
            let byteCount = (try? Data(contentsOf: targetURL).count) ?? finalText.utf8.count

            return GatewayResponseFrame.success(
                id: request.id,
                payload: .object([
                    "path": .string(targetPath),
                    "writtenBytes": .integer(Int64(byteCount)),
                    "append": .bool(shouldAppend),
                    "source": .string("workspace-memory"),
                ]))
        } catch {
            return GatewayResponseFrame.failure(
                id: request.id,
                code: .internalError,
                message: "local memory.append failed: \(error.localizedDescription)")
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

        if GatewayLocalTooling.supports(command) {
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
        let result = await GatewayLocalTooling.execute(
            command: command,
            params: params,
            hostLabel: self.config.hostLabel,
            workspaceRoot: self.workspaceRootURL(),
            urlSession: self.urlSession,
            upstreamForwarder: self.config.upstreamForwarder,
            telegramConfig: self.config.telegramConfig,
            enableLocalSafeTools: self.config.enableLocalSafeTools,
            enableLocalFileTools: self.config.enableLocalFileTools)
        guard let error = result.error else {
            return GatewayResponseFrame.success(id: request.id, payload: result.payload)
        }

        if self.config.upstreamConfigured {
            return GatewayResponseFrame.failure(
                id: request.id,
                code: .unsupportedOnHost,
                message: error)
        }
        return Self.upstreamRequired(
            id: request.id,
            method: request.method,
            hint: error)
    }

    private func handleConfigGet(
        _ request: GatewayRequestFrame,
        nowMs: Int64) async -> GatewayResponseFrame
    {
        guard let adminBridge = self.config.adminBridge else {
            if self.config.upstreamConfigured {
                return GatewayResponseFrame.failure(
                    id: request.id,
                    code: .unsupportedOnHost,
                    message: "config.get is handled by upstream in this host mode")
            }
            return GatewayResponseFrame.failure(
                id: request.id,
                code: .unsupportedOnHost,
                message: "config.get is not available on this host")
        }

        do {
            let payload = try await adminBridge.configGet(nowMs: nowMs)
            return GatewayResponseFrame.success(id: request.id, payload: payload)
        } catch {
            return GatewayResponseFrame.failure(
                id: request.id,
                code: .internalError,
                message: "config.get failed: \(error.localizedDescription)")
        }
    }

    private func handleConfigSet(
        _ request: GatewayRequestFrame,
        nowMs: Int64) async -> GatewayResponseFrame
    {
        guard let adminBridge = self.config.adminBridge else {
            if self.config.upstreamConfigured {
                return GatewayResponseFrame.failure(
                    id: request.id,
                    code: .unsupportedOnHost,
                    message: "config.set is handled by upstream in this host mode")
            }
            return GatewayResponseFrame.failure(
                id: request.id,
                code: .unsupportedOnHost,
                message: "config.set is not available on this host")
        }

        do {
            let payload = try await adminBridge.configSet(
                params: request.params ?? .object([:]),
                nowMs: nowMs)
            return GatewayResponseFrame.success(id: request.id, payload: payload)
        } catch {
            return GatewayResponseFrame.failure(
                id: request.id,
                code: .internalError,
                message: "config.set failed: \(error.localizedDescription)")
        }
    }

    private func handleRuntimeRestart(
        _ request: GatewayRequestFrame,
        nowMs: Int64) async -> GatewayResponseFrame
    {
        guard let adminBridge = self.config.adminBridge else {
            if self.config.upstreamConfigured {
                return GatewayResponseFrame.failure(
                    id: request.id,
                    code: .unsupportedOnHost,
                    message: "runtime.restart is handled by upstream in this host mode")
            }
            return GatewayResponseFrame.failure(
                id: request.id,
                code: .unsupportedOnHost,
                message: "runtime.restart is not available on this host")
        }

        do {
            let payload = try await adminBridge.runtimeRestart(nowMs: nowMs)
            return GatewayResponseFrame.success(id: request.id, payload: payload)
        } catch {
            return GatewayResponseFrame.failure(
                id: request.id,
                code: .internalError,
                message: "runtime.restart failed: \(error.localizedDescription)")
        }
    }

    private func handlePairingList(
        _ request: GatewayRequestFrame,
        nowMs: Int64) async -> GatewayResponseFrame
    {
        guard let adminBridge = self.config.adminBridge else {
            if self.config.upstreamConfigured {
                return GatewayResponseFrame.failure(
                    id: request.id,
                    code: .unsupportedOnHost,
                    message: "pairing.list is handled by upstream in this host mode")
            }
            return GatewayResponseFrame.failure(
                id: request.id,
                code: .unsupportedOnHost,
                message: "pairing.list is not available on this host")
        }

        do {
            let payload = try await adminBridge.pairingList(
                params: request.params ?? .object([:]),
                nowMs: nowMs)
            return GatewayResponseFrame.success(id: request.id, payload: payload)
        } catch {
            return GatewayResponseFrame.failure(
                id: request.id,
                code: .internalError,
                message: "pairing.list failed: \(error.localizedDescription)")
        }
    }

    private func handlePairingApprove(
        _ request: GatewayRequestFrame,
        nowMs: Int64) async -> GatewayResponseFrame
    {
        guard let adminBridge = self.config.adminBridge else {
            if self.config.upstreamConfigured {
                return GatewayResponseFrame.failure(
                    id: request.id,
                    code: .unsupportedOnHost,
                    message: "pairing.approve is handled by upstream in this host mode")
            }
            return GatewayResponseFrame.failure(
                id: request.id,
                code: .unsupportedOnHost,
                message: "pairing.approve is not available on this host")
        }

        do {
            let payload = try await adminBridge.pairingApprove(
                params: request.params ?? .object([:]),
                nowMs: nowMs)
            return GatewayResponseFrame.success(id: request.id, payload: payload)
        } catch {
            return GatewayResponseFrame.failure(
                id: request.id,
                code: .internalError,
                message: "pairing.approve failed: \(error.localizedDescription)")
        }
    }

    private func handleBackupExport(
        _ request: GatewayRequestFrame,
        nowMs: Int64) async -> GatewayResponseFrame
    {
        guard let adminBridge = self.config.adminBridge else {
            return GatewayResponseFrame.failure(
                id: request.id,
                code: .unsupportedOnHost,
                message: "backup.export is not available on this host")
        }

        do {
            let payload = try await adminBridge.backupExport(nowMs: nowMs)
            return GatewayResponseFrame.success(id: request.id, payload: payload)
        } catch {
            return GatewayResponseFrame.failure(
                id: request.id,
                code: .internalError,
                message: "backup.export failed: \(error.localizedDescription)")
        }
    }

    private func handleBackupImport(
        _ request: GatewayRequestFrame,
        nowMs: Int64) async -> GatewayResponseFrame
    {
        guard let adminBridge = self.config.adminBridge else {
            return GatewayResponseFrame.failure(
                id: request.id,
                code: .unsupportedOnHost,
                message: "backup.import is not available on this host")
        }

        do {
            let payload = try await adminBridge.backupImport(
                params: request.params ?? .object([:]),
                nowMs: nowMs)
            return GatewayResponseFrame.success(id: request.id, payload: payload)
        } catch {
            return GatewayResponseFrame.failure(
                id: request.id,
                code: .internalError,
                message: "backup.import failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Dream Admin Handlers

    private func handleDreamStatus(_ request: GatewayRequestFrame) async -> GatewayResponseFrame {
        guard let adminBridge = self.config.adminBridge else {
            return GatewayResponseFrame.failure(
                id: request.id,
                code: .unsupportedOnHost,
                message: "dream.status is not available on this host")
        }
        do {
            let payload = try await adminBridge.dreamStatus()
            return GatewayResponseFrame.success(id: request.id, payload: payload)
        } catch {
            return GatewayResponseFrame.failure(
                id: request.id,
                code: .internalError,
                message: "dream.status failed: \(error.localizedDescription)")
        }
    }

    private func handleDreamEnter(_ request: GatewayRequestFrame) async -> GatewayResponseFrame {
        guard let adminBridge = self.config.adminBridge else {
            return GatewayResponseFrame.failure(
                id: request.id,
                code: .unsupportedOnHost,
                message: "dream.enter is not available on this host")
        }
        do {
            let payload = try await adminBridge.dreamEnter()
            return GatewayResponseFrame.success(id: request.id, payload: payload)
        } catch {
            return GatewayResponseFrame.failure(
                id: request.id,
                code: .internalError,
                message: "dream.enter failed: \(error.localizedDescription)")
        }
    }

    private func handleDreamWake(_ request: GatewayRequestFrame) async -> GatewayResponseFrame {
        guard let adminBridge = self.config.adminBridge else {
            return GatewayResponseFrame.failure(
                id: request.id,
                code: .unsupportedOnHost,
                message: "dream.wake is not available on this host")
        }
        do {
            let payload = try await adminBridge.dreamWake()
            return GatewayResponseFrame.success(id: request.id, payload: payload)
        } catch {
            return GatewayResponseFrame.failure(
                id: request.id,
                code: .internalError,
                message: "dream.wake failed: \(error.localizedDescription)")
        }
    }

    private func handleDreamIdle(_ request: GatewayRequestFrame) async -> GatewayResponseFrame {
        guard let adminBridge = self.config.adminBridge else {
            return GatewayResponseFrame.failure(
                id: request.id,
                code: .unsupportedOnHost,
                message: "dream.idle is not available on this host")
        }
        do {
            let payload = try await adminBridge.dreamIdle()
            return GatewayResponseFrame.success(id: request.id, payload: payload)
        } catch {
            return GatewayResponseFrame.failure(
                id: request.id,
                code: .internalError,
                message: "dream.idle failed: \(error.localizedDescription)")
        }
    }

    private func handleDreamReseedTemplates(_ request: GatewayRequestFrame) async -> GatewayResponseFrame {
        guard let adminBridge = self.config.adminBridge else {
            return GatewayResponseFrame.failure(
                id: request.id,
                code: .unsupportedOnHost,
                message: "dream.reseedTemplates is not available on this host")
        }
        do {
            let payload = try await adminBridge.dreamReseedTemplates()
            return GatewayResponseFrame.success(id: request.id, payload: payload)
        } catch {
            return GatewayResponseFrame.failure(
                id: request.id,
                code: .internalError,
                message: "dream.reseedTemplates failed: \(error.localizedDescription)")
        }
    }

    private func handleAgentsRun(_ request: GatewayRequestFrame, nowMs: Int64) async -> GatewayResponseFrame {
        guard let params = GatewayPayloadCodec.decode(request.params, as: AgentsRunParams.self) else {
            return GatewayResponseFrame.failure(
                id: request.id,
                code: .invalidRequest,
                message: "invalid agents.run params")
        }

        let goal = Self.trimmedFirstNonEmpty(params.goal, params.prompt)
        if goal.isEmpty {
            return GatewayResponseFrame.failure(
                id: request.id,
                code: .invalidRequest,
                message: "invalid agents.run params: goal required")
        }

        let snapshot = await self.agentRuntime.startRun(
            runID: Self.normalizedID(params.runId, fallback: UUID().uuidString),
            sessionKey: params.sessionKey,
            goal: goal,
            maxSteps: params.maxSteps,
            steps: params.steps,
            nowMs: nowMs)

        if let payload = GatewayPayloadCodec.encode(snapshot) {
            return GatewayResponseFrame.success(id: request.id, payload: payload)
        }
        return GatewayResponseFrame.failure(
            id: request.id,
            code: .internalError,
            message: "agents.run snapshot encoding failed")
    }

    private func handleAgentsStatus(_ request: GatewayRequestFrame) async -> GatewayResponseFrame {
        guard let params = GatewayPayloadCodec.decode(request.params, as: AgentsStatusParams.self),
              let runId = Self.normalizedIDOrNil(params.runId, fallback: nil)
        else {
            return GatewayResponseFrame.failure(
                id: request.id,
                code: .invalidRequest,
                message: "invalid agents.status params")
        }

        guard let snapshot = await self.agentRuntime.runStatus(runId) else {
            return GatewayResponseFrame.failure(
                id: request.id,
                code: .methodNotFound,
                message: "agent run not found: \(runId)")
        }
        guard let payload = GatewayPayloadCodec.encode(snapshot) else {
            return GatewayResponseFrame.failure(
                id: request.id,
                code: .internalError,
                message: "agents.status snapshot encoding failed")
        }
        return GatewayResponseFrame.success(id: request.id, payload: payload)
    }

    private func handleAgentsAbort(_ request: GatewayRequestFrame, nowMs: Int64) async -> GatewayResponseFrame {
        guard let params = GatewayPayloadCodec.decode(request.params, as: AgentsAbortParams.self),
              let runId = Self.normalizedIDOrNil(params.runId, fallback: nil)
        else {
            return GatewayResponseFrame.failure(
                id: request.id,
                code: .invalidRequest,
                message: "invalid agents.abort params")
        }
        let changed = await self.agentRuntime.abortRun(runId, nowMs: nowMs)
        if !changed {
            return GatewayResponseFrame.failure(
                id: request.id,
                code: .methodNotFound,
                message: "agent run not found or already finished: \(runId)")
        }
        guard let snapshot = await self.agentRuntime.runStatus(runId),
              let payload = GatewayPayloadCodec.encode(snapshot)
        else {
            return GatewayResponseFrame.failure(
                id: request.id,
                code: .internalError,
                message: "agents.abort snapshot encoding failed")
        }
        return GatewayResponseFrame.success(id: request.id, payload: payload)
    }

    private func handleCronList(_ request: GatewayRequestFrame) async -> GatewayResponseFrame {
        let params = GatewayPayloadCodec.decode(request.params, as: CronListParams.self)
        let includeDisabled = params?.includeDisabled ?? false
        let jobs = self.cronJobsByID.values
            .filter { includeDisabled || $0.enabled }
            .sorted { lhs, rhs in
                if lhs.createdAtMs == rhs.createdAtMs {
                    return lhs.id < rhs.id
                }
                return lhs.createdAtMs < rhs.createdAtMs
            }
        return GatewayResponseFrame.success(
            id: request.id,
            payload: .object([
                "jobs": GatewayPayloadCodec.encode(jobs) ?? .array([]),
            ]))
    }

    private func handleCronStatus(_ request: GatewayRequestFrame, nowMs: Int64) async -> GatewayResponseFrame {
        _ = GatewayPayloadCodec.decode(request.params, as: CronStatusParams.self)
        let jobs = self.cronJobsByID.values
        let enabledJobs = jobs.filter(\.enabled)
        let nextWake = enabledJobs
            .compactMap(\.state.nextRunAtMs)
            .filter { $0 > nowMs }
            .min()
        return GatewayResponseFrame.success(
            id: request.id,
            payload: .object([
                "enabled": .bool(true),
                "totalJobs": .integer(Int64(jobs.count)),
                "enabledJobs": .integer(Int64(enabledJobs.count)),
                "nextWakeAtMs": nextWake.map { .integer($0) } ?? .null,
            ]))
    }

    private func handleCronAdd(_ request: GatewayRequestFrame, nowMs: Int64) async -> GatewayResponseFrame {
        guard let params = GatewayPayloadCodec.decode(request.params, as: CronAddParams.self) else {
            return GatewayResponseFrame.failure(
                id: request.id,
                code: .invalidRequest,
                message: "invalid cron.add params")
        }

        let name = params.name.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty {
            return GatewayResponseFrame.failure(
                id: request.id,
                code: .invalidRequest,
                message: "invalid cron.add params: name required")
        }
        if let validationError = Self.validateCronSchedule(params.schedule) {
            return GatewayResponseFrame.failure(
                id: request.id,
                code: .invalidRequest,
                message: validationError)
        }

        let defaultSessionTarget: String = params.payload.kind == .systemEvent ? "main" : "isolated"
        let sessionTarget = (params.sessionTarget?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
            .flatMap { normalized in
                normalized == "main" || normalized == "isolated" ? normalized : nil
            } ?? defaultSessionTarget
        let wakeMode = (params.wakeMode?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
            .flatMap { normalized in
                normalized == "now" || normalized == "next-heartbeat" ? normalized : nil
            } ?? "now"

        let jobID = UUID().uuidString.lowercased()
        var job = LocalCronJob(
            id: jobID,
            agentId: Self.trimmedStringOrNil(params.agentId),
            name: name,
            description: Self.trimmedStringOrNil(params.description),
            enabled: params.enabled ?? true,
            deleteAfterRun: params.deleteAfterRun,
            createdAtMs: nowMs,
            updatedAtMs: nowMs,
            schedule: params.schedule,
            sessionTarget: sessionTarget,
            wakeMode: wakeMode,
            payload: params.payload,
            delivery: params.delivery,
            state: LocalCronState())
        let nextRun = Self.nextRunTime(for: job, nowMs: nowMs)
        job.state.nextRunAtMs = nextRun
        self.cronJobsByID[jobID] = job
        self.persistCronJobs()

        return GatewayResponseFrame.success(
            id: request.id,
            payload: GatewayPayloadCodec.encode(job))
    }

    private func handleCronUpdate(_ request: GatewayRequestFrame, nowMs: Int64) async -> GatewayResponseFrame {
        guard let params = GatewayPayloadCodec.decode(request.params, as: CronUpdateParams.self) else {
            return GatewayResponseFrame.failure(
                id: request.id,
                code: .invalidRequest,
                message: "invalid cron.update params")
        }

        let jobID = Self.normalizedIDOrNil(params.id, fallback: params.jobId)
        guard let jobID, var job = self.cronJobsByID[jobID] else {
            return GatewayResponseFrame.failure(
                id: request.id,
                code: .methodNotFound,
                message: "cron job not found: \(params.id ?? params.jobId ?? "(missing)")")
        }

        let patch = params.patch
        if let name = patch.name?.trimmingCharacters(in: .whitespacesAndNewlines) {
            if name.isEmpty {
                return GatewayResponseFrame.failure(
                    id: request.id,
                    code: .invalidRequest,
                    message: "invalid cron.update params: name cannot be empty")
            }
            job.name = name
        }
        if let description = patch.description {
            job.description = Self.trimmedStringOrNil(description)
        }
        if let enabled = patch.enabled {
            job.enabled = enabled
        }
        if let deleteAfterRun = patch.deleteAfterRun {
            job.deleteAfterRun = deleteAfterRun
        }
        if let schedule = patch.schedule {
            if let validationError = Self.validateCronSchedule(schedule) {
                return GatewayResponseFrame.failure(
                    id: request.id,
                    code: .invalidRequest,
                    message: validationError)
            }
            job.schedule = schedule
        }
        if let sessionTarget = patch.sessionTarget?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
           sessionTarget == "main" || sessionTarget == "isolated"
        {
            job.sessionTarget = sessionTarget
        }
        if let wakeMode = patch.wakeMode?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
           wakeMode == "now" || wakeMode == "next-heartbeat"
        {
            job.wakeMode = wakeMode
        }
        if let payload = patch.payload {
            job.payload = payload
        }
        if let delivery = patch.delivery {
            job.delivery = delivery
        }
        if let statePatch = patch.state {
            job.state = statePatch
        }
        if let agentId = patch.agentId {
            job.agentId = Self.trimmedStringOrNil(agentId)
        }

        job.updatedAtMs = nowMs
        if !job.enabled {
            job.state.nextRunAtMs = nil
            if let runningTask = self.cronRunTaskByJobID[jobID] {
                runningTask.cancel()
                self.cronRunTaskByJobID[jobID] = nil
                job.state.runningAtMs = nil
            }
        } else if job.state.runningAtMs == nil {
            job.state.nextRunAtMs = Self.nextRunTime(for: job, nowMs: nowMs)
        }

        self.cronJobsByID[jobID] = job
        self.persistCronJobs()
        return GatewayResponseFrame.success(
            id: request.id,
            payload: GatewayPayloadCodec.encode(job))
    }

    private func handleCronRemove(_ request: GatewayRequestFrame) async -> GatewayResponseFrame {
        guard let params = GatewayPayloadCodec.decode(request.params, as: CronRemoveParams.self) else {
            return GatewayResponseFrame.failure(
                id: request.id,
                code: .invalidRequest,
                message: "invalid cron.remove params")
        }
        guard let jobID = Self.normalizedIDOrNil(params.id, fallback: params.jobId) else {
            return GatewayResponseFrame.failure(
                id: request.id,
                code: .invalidRequest,
                message: "invalid cron.remove params: missing id")
        }

        if let task = self.cronRunTaskByJobID[jobID] {
            task.cancel()
            self.cronRunTaskByJobID[jobID] = nil
        }
        let removed = self.cronJobsByID.removeValue(forKey: jobID) != nil
        self.persistCronJobs()
        return GatewayResponseFrame.success(
            id: request.id,
            payload: .object([
                "ok": .bool(true),
                "removed": .bool(removed),
            ]))
    }

    private func handleCronRun(_ request: GatewayRequestFrame, nowMs: Int64) async -> GatewayResponseFrame {
        guard let params = GatewayPayloadCodec.decode(request.params, as: CronRunParams.self) else {
            return GatewayResponseFrame.failure(
                id: request.id,
                code: .invalidRequest,
                message: "invalid cron.run params")
        }
        guard let jobID = Self.normalizedIDOrNil(params.id, fallback: params.jobId) else {
            return GatewayResponseFrame.failure(
                id: request.id,
                code: .invalidRequest,
                message: "invalid cron.run params: missing id")
        }
        guard self.cronJobsByID[jobID] != nil else {
            return GatewayResponseFrame.failure(
                id: request.id,
                code: .methodNotFound,
                message: "cron job not found: \(jobID)")
        }

        let mode = (params.mode?.lowercased() == "due") ? "due" : "force"
        let result = await self.executeCronJob(jobID: jobID, mode: mode, nowMs: nowMs)
        switch result {
        case let .success(payload):
            return GatewayResponseFrame.success(id: request.id, payload: payload)
        case let .failure(message):
            return GatewayResponseFrame.failure(
                id: request.id,
                code: .internalError,
                message: message)
        }
    }

    private func handleCronRuns(_ request: GatewayRequestFrame) async -> GatewayResponseFrame {
        guard let params = GatewayPayloadCodec.decode(request.params, as: CronRunsParams.self) else {
            return GatewayResponseFrame.failure(
                id: request.id,
                code: .invalidRequest,
                message: "invalid cron.runs params")
        }
        guard let jobID = Self.normalizedIDOrNil(params.id, fallback: params.jobId) else {
            return GatewayResponseFrame.failure(
                id: request.id,
                code: .invalidRequest,
                message: "invalid cron.runs params: missing id")
        }

        let limit = max(1, min(params.limit ?? 50, 500))
        let entries = self.readCronRunLogEntries(jobID: jobID, limit: limit)
        return GatewayResponseFrame.success(
            id: request.id,
            payload: .object([
                "id": .string(jobID),
                "entries": GatewayPayloadCodec.encode(entries) ?? .array([]),
            ]))
    }

    private func handleCapabilitiesGet(_ request: GatewayRequestFrame, nowMs: Int64) -> GatewayResponseFrame {
        let adminConfigRoute = self.config.adminBridge == nil
            ? (self.config.upstreamConfigured ? "upstream" : "unsupported")
            : "local"
        let adminConfigDetails = self.config.adminBridge == nil
            ? (self.config.upstreamConfigured
                ? "Handled by upstream control plane"
                : "No local admin bridge configured")
            : "Get runtime control-plane settings"
        let adminSetDetails = self.config.adminBridge == nil
            ? (self.config.upstreamConfigured
                ? "Handled by upstream control plane"
                : "No local admin bridge configured")
            : "Apply runtime control-plane settings"
        let adminRestartDetails = self.config.adminBridge == nil
            ? (self.config.upstreamConfigured
                ? "Handled by upstream control plane"
                : "No local admin bridge configured")
            : "Restart local runtime listeners and apply config"

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
                    method: "memory.append",
                    route: "local",
                    details: "Write-only local memory sink for MEMORY.md and memory/*.md"),
                MethodCapability(
                    method: "node.invoke",
                    route: "policy",
                    details: "Safe and workspace file commands local; unsafe commands upstream-only"),
                MethodCapability(
                    method: "telegram.send",
                    route: self.config.telegramConfig.isConfigured ? "local" : "disabled",
                    details: self.config.telegramConfig.isConfigured
                        ? "Send Telegram messages via local bot token"
                        : "Requires local Telegram bot token configuration"),
                MethodCapability(
                    method: "agents.run",
                    route: "local",
                    details: "Run an agentic workflow with deterministic per-session queuing"),
                MethodCapability(
                    method: "agents.status",
                    route: "local",
                    details: "Query local agent run status."),
                MethodCapability(
                    method: "agents.abort",
                    route: "local",
                    details: "Abort a running local agent run."),
                MethodCapability(
                    method: "cron.list",
                    route: "local",
                    details: "List local scheduled jobs."),
                MethodCapability(
                    method: "cron.status",
                    route: "local",
                    details: "Summarize local scheduler status."),
                MethodCapability(
                    method: "cron.add",
                    route: "local",
                    details: "Create a local scheduled job."),
                MethodCapability(
                    method: "cron.update",
                    route: "local",
                    details: "Update an existing local scheduled job."),
                MethodCapability(
                    method: "cron.remove",
                    route: "local",
                    details: "Remove a local scheduled job."),
                MethodCapability(
                    method: "cron.run",
                    route: "local",
                    details: "Force-run a local scheduled job immediately."),
                MethodCapability(
                    method: "cron.runs",
                    route: "local",
                    details: "Read recent run log entries for a local scheduled job."),
                MethodCapability(
                    method: "config.get",
                    route: adminConfigRoute,
                    details: adminConfigDetails),
                MethodCapability(
                    method: "config.set",
                    route: adminConfigRoute,
                    details: adminSetDetails),
                MethodCapability(
                    method: "runtime.restart",
                    route: adminConfigRoute,
                    details: adminRestartDetails),
                MethodCapability(
                    method: "pairing.list",
                    route: adminConfigRoute,
                    details: self.config.adminBridge == nil
                        ? (self.config.upstreamConfigured
                            ? "Handled by upstream pairing store"
                            : "No local pairing bridge configured")
                        : "List local pending pairing requests"),
                MethodCapability(
                    method: "pairing.approve",
                    route: adminConfigRoute,
                    details: self.config.adminBridge == nil
                        ? (self.config.upstreamConfigured
                            ? "Handled by upstream pairing store"
                            : "No local pairing bridge configured")
                        : "Approve local pending pairing request by code"),
                MethodCapability(
                    method: "backup.export",
                    route: adminConfigRoute,
                    details: self.config.adminBridge == nil
                        ? "No local admin bridge configured"
                        : "Export backup as base64-encoded archive"),
                MethodCapability(
                    method: "backup.import",
                    route: adminConfigRoute,
                    details: self.config.adminBridge == nil
                        ? "No local admin bridge configured"
                        : "Import backup from base64-encoded archive data"),
            ],
            toolPolicy: ToolPolicy(
                localSafeCommands: self.config.enableLocalSafeTools
                    ? GatewayLocalTooling.availableSafeCommands(
                        upstreamConfigured: self.config.upstreamForwarder != nil)
                    : [],
                localFileCommands: self.config.enableLocalFileTools ? GatewayLocalTooling.fileCommands : [],
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

    private func startCronSchedulerIfNeeded() {
        guard self.cronTickTask == nil else { return }
        self.reconcileCronSchedule(nowMs: GatewayCore.currentTimestampMs())
        self.cronTickTask = Task { [self] in
            await self.runCronSchedulerLoop()
        }
    }

    private func runCronSchedulerLoop() async {
        while !Task.isCancelled {
            let nowMs = GatewayCore.currentTimestampMs()
            await self.processDueCronJobs(nowMs: nowMs)
            do {
                try await Task.sleep(nanoseconds: 5_000_000_000)
            } catch {
                return
            }
        }
    }

    private func processDueCronJobs(nowMs: Int64) async {
        let dueJobIDs = self.cronJobsByID.values
            .filter { job in
                guard job.enabled, job.state.runningAtMs == nil else {
                    return false
                }
                guard let nextRunAtMs = job.state.nextRunAtMs else {
                    return false
                }
                return nextRunAtMs <= nowMs
            }
            .sorted { lhs, rhs in
                let lhsNext = lhs.state.nextRunAtMs ?? Int64.max
                let rhsNext = rhs.state.nextRunAtMs ?? Int64.max
                if lhsNext == rhsNext {
                    return lhs.id < rhs.id
                }
                return lhsNext < rhsNext
            }
            .map(\.id)

        for jobID in dueJobIDs {
            _ = await self.executeCronJob(jobID: jobID, mode: "due", nowMs: nowMs)
        }
    }

    private func executeCronJob(jobID: String, mode: String, nowMs: Int64) async -> LocalCronExecutionResult {
        guard var job = self.cronJobsByID[jobID] else {
            return .failure("cron job not found: \(jobID)")
        }
        if job.state.runningAtMs != nil {
            return .failure("cron job is already running: \(jobID)")
        }
        if mode == "due", !job.enabled {
            return .failure("cron job is disabled: \(jobID)")
        }

        let promptText: String
        switch job.payload.kind {
        case .systemEvent:
            let text = (job.payload.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else {
                return .failure("cron payload text is required for systemEvent")
            }
            promptText = text
        case .agentTurn:
            let message = (job.payload.message ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !message.isEmpty else {
                return .failure("cron payload message is required for agentTurn")
            }
            promptText = message
        }

        let sessionKey = job.sessionTarget == "main" ? "main" : "cron:\(job.id)"
        let thinkingLevel = Self.trimmedStringOrNil(job.payload.thinking)
        let runRequest = GatewayRequestFrame(
            id: "cron-run-\(UUID().uuidString.lowercased())",
            method: "chat.send",
            params: .object([
                "sessionKey": .string(sessionKey),
                "message": .string("[cron:\(job.id) \(job.name)] \(promptText)"),
                "thinking": thinkingLevel.map { .string($0) } ?? .null,
                "idempotencyKey": .string("cron-\(job.id)-\(UUID().uuidString.lowercased())"),
            ]))

        job.state.runningAtMs = nowMs
        job.state.lastError = nil
        job.updatedAtMs = nowMs
        self.cronJobsByID[jobID] = job
        self.persistCronJobs()

        let runTask = Task { [self] in
            await self.handleChatSend(runRequest, nowMs: GatewayCore.currentTimestampMs())
        }
        self.cronRunTaskByJobID[jobID] = runTask
        let runStartedAtMs = nowMs
        let response = await runTask.value
        let finishedAtMs = GatewayCore.currentTimestampMs()
        self.cronRunTaskByJobID[jobID] = nil

        guard var updatedJob = self.cronJobsByID[jobID] else {
            return .failure("cron job disappeared during run: \(jobID)")
        }
        updatedJob.state.runningAtMs = nil
        updatedJob.state.lastRunAtMs = finishedAtMs
        updatedJob.state.lastDurationMs = max(0, finishedAtMs - runStartedAtMs)
        updatedJob.updatedAtMs = finishedAtMs

        let baseStatus: String
        let baseErrorText: String?
        let runID: String?
        if let response, response.ok {
            baseStatus = "ok"
            baseErrorText = nil
            runID = response.payload?.objectValue?["runId"]?.stringValue
        } else {
            baseStatus = "error"
            baseErrorText = response?.error?.message ?? "cron run failed"
            runID = nil
        }

        let deliveryErrorText = await self.deliverCronResultIfConfigured(
            job: updatedJob,
            sessionKey: sessionKey,
            runID: runID,
            runStatus: baseStatus,
            runError: baseErrorText)
        let bestEffortDelivery = updatedJob.delivery?.bestEffort == true

        let status: String
        let errorText: String?
        if let deliveryErrorText, !bestEffortDelivery, baseStatus == "ok" {
            status = "error"
            errorText = "cron delivery failed: \(deliveryErrorText)"
        } else {
            status = baseStatus
            errorText = baseErrorText
        }

        if status == "ok" {
            updatedJob.state.consecutiveErrors = 0
        } else {
            let nextErrorCount = (updatedJob.state.consecutiveErrors ?? 0) + 1
            updatedJob.state.consecutiveErrors = nextErrorCount
        }
        updatedJob.state.lastStatus = status
        updatedJob.state.lastError = errorText

        if updatedJob.deleteAfterRun == true,
           updatedJob.schedule.kind == .at
        {
            self.cronJobsByID.removeValue(forKey: jobID)
        } else {
            if updatedJob.enabled {
                updatedJob.state.nextRunAtMs = Self.nextRunTime(for: updatedJob, nowMs: finishedAtMs)
            } else {
                updatedJob.state.nextRunAtMs = nil
            }
            self.cronJobsByID[jobID] = updatedJob
        }
        self.persistCronJobs()

        let logErrorText: String? = if let errorText {
            errorText
        } else if let deliveryErrorText {
            bestEffortDelivery
                ? "delivery warning (best-effort): \(deliveryErrorText)"
                : "delivery error: \(deliveryErrorText)"
        } else {
            nil
        }

        self.appendCronRunLogEntry(
            jobID: jobID,
            entry: LocalCronRunLogEntry(
                ts: finishedAtMs,
                status: status,
                mode: mode,
                durationMs: max(0, finishedAtMs - runStartedAtMs),
                error: logErrorText,
                sessionKey: sessionKey,
                runId: runID))

        return .success(.object([
            "ok": .bool(status == "ok"),
            "id": .string(jobID),
            "status": .string(status),
            "mode": .string(mode),
            "durationMs": .integer(max(0, finishedAtMs - runStartedAtMs)),
            "error": errorText.map { .string($0) } ?? .null,
            "runId": runID.map { .string($0) } ?? .null,
            "deliveryError": deliveryErrorText.map { .string($0) } ?? .null,
        ]))
    }

    private func deliverCronResultIfConfigured(
        job: LocalCronJob,
        sessionKey: String,
        runID: String?,
        runStatus: String,
        runError: String?) async -> String?
    {
        guard let delivery = job.delivery else {
            return nil
        }
        let channel = (
            Self.trimmedStringOrNil(delivery.channel)
                ?? Self.trimmedStringOrNil(delivery.mode)
                ?? "").lowercased()
        guard !channel.isEmpty else {
            return nil
        }
        guard channel == "telegram" || channel == "tg" else {
            return "unsupported cron delivery channel: \(channel)"
        }

        var messageLines: [String] = [
            "[OpenClaw cron] \(job.name) | \(runStatus.uppercased())",
            "job=\(job.id)",
        ]
        if let runID {
            messageLines.append("runId=\(runID)")
        }

        if runStatus == "ok" {
            if let output = await self.latestAssistantOutputForCronSession(sessionKey: sessionKey, runID: runID) {
                messageLines.append(Self.clampUTF16(output, to: 3200))
            } else {
                messageLines.append("(no assistant output captured)")
            }
        } else if let runError {
            messageLines.append("error: \(runError)")
        }

        var toolParams: [String: GatewayJSONValue] = [
            "text": .string(messageLines.joined(separator: "\n")),
        ]
        if let targetChat = Self.trimmedStringOrNil(delivery.to) {
            toolParams["chatId"] = .string(targetChat)
        }

        let result = await GatewayLocalTooling.execute(
            command: "telegram.send",
            params: .object(toolParams),
            hostLabel: self.config.hostLabel,
            workspaceRoot: self.workspaceRootURL(),
            urlSession: self.urlSession,
            upstreamForwarder: self.config.upstreamForwarder,
            telegramConfig: self.config.telegramConfig,
            enableLocalSafeTools: self.config.enableLocalSafeTools,
            enableLocalFileTools: self.config.enableLocalFileTools)
        return result.error
    }

    private func latestAssistantOutputForCronSession(sessionKey: String, runID: String?) async -> String? {
        guard let turns = try? await self.memoryStore.history(sessionKey: sessionKey, limit: 48),
              !turns.isEmpty
        else {
            return nil
        }

        if let runID {
            for turn in turns.reversed() where turn.role == "assistant" && turn.runID == runID {
                let text = turn.text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty {
                    return text
                }
            }
        }

        for turn in turns.reversed() where turn.role == "assistant" {
            let text = turn.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty {
                return text
            }
        }
        return nil
    }

    private func reconcileCronSchedule(nowMs: Int64) {
        var changed = false
        var nextJobs: [String: LocalCronJob] = self.cronJobsByID
        for (jobID, var job) in nextJobs {
            if job.state.runningAtMs != nil {
                job.state.runningAtMs = nil
                changed = true
            }
            let nextRunAtMs = job.enabled ? Self.nextRunTime(for: job, nowMs: nowMs) : nil
            if job.state.nextRunAtMs != nextRunAtMs {
                job.state.nextRunAtMs = nextRunAtMs
                changed = true
            }
            nextJobs[jobID] = job
        }
        if changed {
            self.cronJobsByID = nextJobs
            self.persistCronJobs()
        }
    }

    private static func defaultCronStorePath(memoryStorePath: URL) -> URL {
        memoryStorePath
            .deletingLastPathComponent()
            .appendingPathComponent("cron", isDirectory: true)
            .appendingPathComponent("jobs.json", isDirectory: false)
    }

    private static func loadCronJobs(storePath: URL) -> [String: LocalCronJob] {
        guard let data = try? Data(contentsOf: storePath) else {
            return [:]
        }
        guard let store = try? JSONDecoder().decode(LocalCronStore.self, from: data),
              store.version == 1
        else {
            return [:]
        }
        var jobMap: [String: LocalCronJob] = [:]
        for job in store.jobs {
            jobMap[job.id] = job
        }
        return jobMap
    }

    private func persistCronJobs() {
        let storeDirectory = self.cronStorePath.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(at: storeDirectory, withIntermediateDirectories: true)
            let jobs = self.cronJobsByID.values.sorted { lhs, rhs in
                if lhs.createdAtMs == rhs.createdAtMs {
                    return lhs.id < rhs.id
                }
                return lhs.createdAtMs < rhs.createdAtMs
            }
            let store = LocalCronStore(version: 1, jobs: jobs)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(store)
            try data.write(to: self.cronStorePath, options: .atomic)
        } catch {
            // Best-effort persistence; scheduler continues in-memory.
        }
    }

    private func appendCronRunLogEntry(jobID: String, entry: LocalCronRunLogEntry) {
        let logPath = self.cronRunsDirectoryPath.appendingPathComponent("\(jobID).jsonl", isDirectory: false)
        do {
            try FileManager.default.createDirectory(
                at: self.cronRunsDirectoryPath,
                withIntermediateDirectories: true)
            let lineData = try JSONEncoder().encode(entry)
            if FileManager.default.fileExists(atPath: logPath.path) {
                let handle = try FileHandle(forWritingTo: logPath)
                defer { try? handle.close() }
                try handle.seekToEnd()
                try handle.write(contentsOf: lineData)
                try handle.write(contentsOf: Data("\n".utf8))
            } else {
                var payload = Data()
                payload.append(lineData)
                payload.append(Data("\n".utf8))
                try payload.write(to: logPath, options: .atomic)
            }
        } catch {
            // Best-effort log write.
        }
    }

    private func readCronRunLogEntries(jobID: String, limit: Int) -> [LocalCronRunLogEntry] {
        let logPath = self.cronRunsDirectoryPath.appendingPathComponent("\(jobID).jsonl", isDirectory: false)
        guard let data = try? Data(contentsOf: logPath),
              let text = String(data: data, encoding: .utf8)
        else {
            return []
        }
        let decoder = JSONDecoder()
        var entries: [LocalCronRunLogEntry] = []
        entries.reserveCapacity(min(limit, 128))
        for line in text.split(whereSeparator: \.isNewline) {
            guard let lineData = String(line).data(using: .utf8),
                  let entry = try? decoder.decode(LocalCronRunLogEntry.self, from: lineData)
            else {
                continue
            }
            entries.append(entry)
        }
        if entries.count <= limit {
            return entries
        }
        return Array(entries.suffix(limit))
    }

    private static func validateCronSchedule(_ schedule: LocalCronSchedule) -> String? {
        switch schedule.kind {
        case .at:
            guard let atText = trimmedStringOrNil(schedule.at),
                  parseISO8601Millis(atText) != nil
            else {
                return "invalid cron schedule: at timestamp required"
            }
            return nil
        case .every:
            guard let everyMs = schedule.everyMs, everyMs > 0 else {
                return "invalid cron schedule: everyMs must be > 0"
            }
            return nil
        case .cron:
            guard let expression = trimmedStringOrNil(schedule.expr),
                  parseCronExpression(expression) != nil
            else {
                return "invalid cron schedule: unsupported cron expression"
            }
            return nil
        }
    }

    private static func nextRunTime(for job: LocalCronJob, nowMs: Int64) -> Int64? {
        let schedule = job.schedule
        switch schedule.kind {
        case .at:
            guard let atText = Self.trimmedStringOrNil(schedule.at),
                  let atMs = Self.parseISO8601Millis(atText)
            else {
                return nil
            }
            return atMs > nowMs ? atMs : nil
        case .every:
            guard let everyMs = schedule.everyMs, everyMs > 0 else {
                return nil
            }
            let anchor = schedule.anchorMs ?? job.createdAtMs
            if nowMs < anchor {
                return anchor
            }
            let elapsed = nowMs - anchor
            let steps = elapsed / everyMs + 1
            return anchor + steps * everyMs
        case .cron:
            guard let expression = Self.trimmedStringOrNil(schedule.expr) else {
                return nil
            }
            return Self.nextCronRunTime(afterMs: nowMs, expression: expression, timeZoneID: schedule.tz)
        }
    }

    private static func parseISO8601Millis(_ text: String) -> Int64? {
        if let date = ISO8601DateFormatter().date(from: text) {
            return Int64(date.timeIntervalSince1970 * 1000)
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ssXXXXX"
        if let date = formatter.date(from: text) {
            return Int64(date.timeIntervalSince1970 * 1000)
        }
        return nil
    }

    private static func nextCronRunTime(afterMs: Int64, expression: String, timeZoneID: String?) -> Int64? {
        guard let parsed = parseCronExpression(expression) else {
            return nil
        }

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: Self.trimmedStringOrNil(timeZoneID) ?? "")
            ?? TimeZone.current

        var candidate = Date(timeIntervalSince1970: Double(afterMs) / 1000.0)
        candidate = Date(timeIntervalSince1970: floor(candidate.timeIntervalSince1970 / 60.0) * 60.0 + 60.0)
        for _ in 0..<527_040 {
            let components = calendar.dateComponents([.minute, .hour, .day, .month, .weekday], from: candidate)
            guard let minute = components.minute,
                  let hour = components.hour,
                  let day = components.day,
                  let month = components.month,
                  let weekdayRaw = components.weekday
            else {
                candidate.addTimeInterval(60)
                continue
            }
            let weekday = (weekdayRaw + 6) % 7
            if parsed.minute.contains(minute),
               parsed.hour.contains(hour),
               parsed.day.contains(day),
               parsed.month.contains(month),
               parsed.weekday.contains(weekday)
            {
                return Int64(candidate.timeIntervalSince1970 * 1000)
            }
            candidate.addTimeInterval(60)
        }
        return nil
    }

    private static func parseCronExpression(_ expression: String) -> (
        minute: Set<Int>,
        hour: Set<Int>,
        day: Set<Int>,
        month: Set<Int>,
        weekday: Set<Int>)?
    {
        let parts = expression
            .split(whereSeparator: { $0 == " " || $0 == "\t" })
            .map(String.init)
        guard parts.count == 5 else {
            return nil
        }
        guard let minute = Self.parseCronField(parts[0], range: 0...59, mapWeekday: false),
              let hour = Self.parseCronField(parts[1], range: 0...23, mapWeekday: false),
              let day = Self.parseCronField(parts[2], range: 1...31, mapWeekday: false),
              let month = Self.parseCronField(parts[3], range: 1...12, mapWeekday: false),
              let weekday = Self.parseCronField(parts[4], range: 0...7, mapWeekday: true)
        else {
            return nil
        }
        return (minute: minute, hour: hour, day: day, month: month, weekday: weekday)
    }

    private static func parseCronField(
        _ raw: String,
        range: ClosedRange<Int>,
        mapWeekday: Bool) -> Set<Int>?
    {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text == "*" || text == "?" {
            return Set(range)
        }
        var values = Set<Int>()
        for token in text.split(separator: ",") {
            let part = token.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !part.isEmpty,
                  let partValues = Self.parseCronFieldPart(
                      part,
                      range: range,
                      mapWeekday: mapWeekday)
            else {
                return nil
            }
            values.formUnion(partValues)
        }
        return values.isEmpty ? nil : values
    }

    private static func parseCronFieldPart(
        _ part: String,
        range: ClosedRange<Int>,
        mapWeekday: Bool) -> Set<Int>?
    {
        if let slashIndex = part.firstIndex(of: "/") {
            let baseText = String(part[..<slashIndex])
            let stepText = String(part[part.index(after: slashIndex)...])
            guard let step = Int(stepText), step > 0 else {
                return nil
            }
            let baseRange: ClosedRange<Int>
            if baseText.isEmpty || baseText == "*" {
                baseRange = range
            } else if let dashIndex = baseText.firstIndex(of: "-") {
                guard let lower = Int(baseText[..<dashIndex]),
                      let upper = Int(baseText[baseText.index(after: dashIndex)...]),
                      lower <= upper
                else {
                    return nil
                }
                baseRange = lower...upper
            } else if let single = Int(baseText) {
                baseRange = single...range.upperBound
            } else {
                return nil
            }

            var values = Set<Int>()
            var current = baseRange.lowerBound
            while current <= baseRange.upperBound {
                if range.contains(current) {
                    values.insert(mapWeekday && current == 7 ? 0 : current)
                }
                current += step
            }
            return values.isEmpty ? nil : values
        }

        if let dashIndex = part.firstIndex(of: "-") {
            guard let lower = Int(part[..<dashIndex]),
                  let upper = Int(part[part.index(after: dashIndex)...]),
                  lower <= upper
            else {
                return nil
            }
            var values = Set<Int>()
            for value in lower...upper where range.contains(value) {
                values.insert(mapWeekday && value == 7 ? 0 : value)
            }
            return values.isEmpty ? nil : values
        }

        guard let value = Int(part), range.contains(value) else {
            return nil
        }
        return [mapWeekday && value == 7 ? 0 : value]
    }

    private static func trimmedStringOrNil(_ raw: String?) -> String? {
        let trimmed = (raw ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func normalizedSessionKey(_ raw: String?) -> String {
        let trimmed = (raw ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "main" : trimmed
    }

    private static func normalizedID(_ raw: String?, fallback: String) -> String {
        let trimmed = (raw ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? fallback : trimmed
    }

    private static func normalizedIDOrNil(_ raw: String?, fallback: String?) -> String? {
        let trimmed = (raw ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? fallback : trimmed
    }

    private static func trimmedFirstNonEmpty(_ first: String?, _ second: String?) -> String {
        let firstValue = first?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !firstValue.isEmpty { return firstValue }
        return second?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    private static func defaultMemoryWritePath(nowMs: Int64) -> String {
        let date = Date(timeIntervalSince1970: TimeInterval(nowMs) / 1000.0)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current
        formatter.dateFormat = "yyyy-MM-dd"
        return "memory/\(formatter.string(from: date)).md"
    }

    private static func prioritizedBootstrapFileNames(_ fileNames: [String]) -> [String] {
        let priority = ["IDENTITY.md", "USER.md", "SOUL.md", "AGENTS.md", "MEMORY.md", "memory.md"]
        var seen = Set<String>()
        var ordered: [String] = []

        for name in priority where fileNames.contains(name) {
            if seen.insert(name).inserted {
                ordered.append(name)
            }
        }
        for name in fileNames where seen.insert(name).inserted {
            ordered.append(name)
        }
        return ordered
    }

    private static func isAllowedMemoryWritePath(_ rawPath: String) -> Bool {
        let path = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty else { return false }
        if path.hasPrefix("/") || path.contains("..") { return false }
        if path == "MEMORY.md" || path == "memory.md" {
            return true
        }
        guard path.hasPrefix("memory/"), path.hasSuffix(".md") else {
            return false
        }
        return true
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

    private static func parseChatPrompt(
        _ rawMessage: String,
        requestedThinking: String?) -> ParsedChatPrompt
    {
        var messageLines = rawMessage.split(whereSeparator: \.isNewline).map(String.init)
        var resolvedThinking = Self.normalizedThinkingLevel(requestedThinking)

        while let first = messageLines.first {
            let trimmed = first.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.hasPrefix("/") else {
                break
            }
            guard let directive = Self.parseChatDirective(from: trimmed) else {
                break
            }
            messageLines.removeFirst()

            if case let .reasoning(level) = directive {
                resolvedThinking = Self.normalizedThinkingLevel(level)
            }
        }

        let message = messageLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        let finalThinking = resolvedThinking
        return ParsedChatPrompt(message: message, thinking: finalThinking)
    }

    private static func parseChatDirective(from trimmedLine: String) -> ParsedChatDirective? {
        let content = trimmedLine.dropFirst().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !content.isEmpty else {
            return .unknown(raw: trimmedLine)
        }

        let parts = content.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
        guard parts.count >= 1 else {
            return .unknown(raw: trimmedLine)
        }
        let command = parts[0].lowercased()
        guard command == "reasoning" || command == "think" || command == "thinking" else {
            return .unknown(raw: trimmedLine)
        }
        guard parts.count >= 2 else {
            return .unknown(raw: trimmedLine)
        }
        return .reasoning(level: parts[1])
    }

    private static func maybeApplyBootstrapProfileUpdate(
        fields: BootstrapProfileFields?,
        workspaceRoot: URL?) -> String?
    {
        guard let workspaceRoot, let fields, !fields.isEmpty else {
            return nil
        }

        do {
            let summary = try Self.applyBootstrapProfileFields(fields, workspaceRoot: workspaceRoot)
            guard !summary.isEmpty else {
                return nil
            }
            return "workspace profile updated: " + summary.joined(separator: "; ")
        } catch {
            return "workspace profile update failed: \(error.localizedDescription)"
        }
    }

    private static func extractBootstrapProfileFields(from message: String) -> BootstrapProfileFields? {
        let normalizedMessage = message.replacingOccurrences(of: "\r\n", with: "\n")
        var fields = BootstrapProfileFields()
        var section: BootstrapProfileSection = .unknown

        for rawLine in normalizedMessage.split(whereSeparator: \.isNewline) {
            var line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if let hintedSection = Self.profileSectionHint(from: line) {
                section = hintedSection
            }
            while line.hasPrefix("-") || line.hasPrefix("*") {
                line.removeFirst()
                line = line.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            guard let separator = line.firstIndex(of: ":") else {
                continue
            }
            let key = line[..<separator].trimmingCharacters(in: .whitespacesAndNewlines)
            let value = line[line.index(after: separator)...].trimmingCharacters(in: .whitespacesAndNewlines)
            guard let normalizedValue = Self.normalizedProfileValue(String(value), maxLength: 120) else {
                continue
            }
            _ = Self.assignLabeledProfileField(
                key: String(key),
                value: normalizedValue,
                section: section,
                fields: &fields)
        }

        if fields.userName == nil,
           let userName = Self.firstCapture(
               in: normalizedMessage,
               pattern: #"(?i)\bmy name(?:\s+is)?\s*[:\-]?\s*([^\n,.;]+)"#)
        {
            fields.userName = userName
        }
        if fields.userCallName == nil,
           let callName = Self.firstCapture(
               in: normalizedMessage,
               pattern: #"(?i)\bcall me\s+([^\n,.;]+)"#)
        {
            fields.userCallName = callName
        }
        if fields.assistantName == nil,
           let assistantName = Self.firstCapture(
               in: normalizedMessage,
               pattern: #"(?i)\byour name(?:\s+is)?\s*[:\-]?\s*([^\n,.;]+)"#)
        {
            fields.assistantName = assistantName
        }
        if fields.userTimezone == nil,
           let timezone = Self.firstCapture(
               in: normalizedMessage,
               pattern: #"(?i)\btime\s*zone(?:\s+is)?\s*[:\-]?\s*([A-Za-z0-9_+/\- ]{2,40})"#)
           ?? Self.firstCapture(
               in: normalizedMessage,
               pattern: #"(?i)\btimezone(?:\s+is)?\s*[:\-]?\s*([A-Za-z0-9_+/\- ]{2,40})"#)
        {
            fields.userTimezone = timezone
        }

        if fields.userCallName == nil, let userName = fields.userName {
            fields.userCallName = userName
        }
        return fields.isEmpty ? nil : fields
    }

    private static func assignLabeledProfileField(
        key: String,
        value: String,
        section: BootstrapProfileSection,
        fields: inout BootstrapProfileFields) -> Bool
    {
        let normalizedKey = key
            .lowercased()
            .replacingOccurrences(of: "*", with: "")
            .replacingOccurrences(of: "`", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if normalizedKey.contains("your name")
            || normalizedKey.contains("assistant name")
            || normalizedKey.contains("agent name")
            || normalizedKey.contains("ai name")
        {
            fields.assistantName = value
            return true
        }
        if normalizedKey.contains("my name")
            || normalizedKey.contains("user name")
            || normalizedKey.contains("human name")
        {
            fields.userName = value
            if fields.userCallName == nil {
                fields.userCallName = value
            }
            return true
        }
        if normalizedKey.contains("what to call")
            || normalizedKey.contains("call me")
            || normalizedKey.contains("nickname")
        {
            fields.userCallName = value
            return true
        }
        if normalizedKey.contains("time zone") || normalizedKey.contains("timezone") {
            fields.userTimezone = value
            return true
        }
        if normalizedKey.contains("creature") {
            fields.assistantCreature = value
            return true
        }
        if normalizedKey == "name" {
            switch section {
            case .identity:
                fields.assistantName = value
                return true
            case .user:
                fields.userName = value
                if fields.userCallName == nil {
                    fields.userCallName = value
                }
                return true
            case .unknown:
                return false
            }
        }
        if normalizedKey.contains("vibe")
            || normalizedKey.contains("tone")
            || normalizedKey.contains("style")
        {
            fields.assistantVibe = value
            return true
        }
        if normalizedKey.contains("emoji") {
            fields.assistantEmoji = value
            return true
        }
        return false
    }

    private enum BootstrapProfileSection {
        case unknown
        case identity
        case user
    }

    private static func profileSectionHint(from line: String) -> BootstrapProfileSection? {
        let normalized = line
            .lowercased()
            .replacingOccurrences(of: "*", with: "")
            .replacingOccurrences(of: "`", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if normalized.contains("identity.md") || normalized.contains("who am i") {
            return .identity
        }
        if normalized.contains("user.md") || normalized.contains("about your human") {
            return .user
        }
        return nil
    }

    private static func firstCapture(in text: String, pattern: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else {
            return nil
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, options: [], range: range) else {
            return nil
        }
        guard match.numberOfRanges >= 2,
              let captureRange = Range(match.range(at: 1), in: text)
        else {
            return nil
        }
        return Self.normalizedProfileValue(String(text[captureRange]), maxLength: 120)
    }

    private static func normalizedProfileValue(_ raw: String, maxLength: Int) -> String? {
        var value = raw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "**", with: "")
            .replacingOccurrences(of: "`", with: "")
        if value.hasPrefix("\""), value.hasSuffix("\""), value.count >= 2 {
            value = String(value.dropFirst().dropLast())
        }
        value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        value = value.trimmingCharacters(in: CharacterSet(charactersIn: ".,;"))
        guard !value.isEmpty else {
            return nil
        }
        if value.lowercased().hasPrefix("_("), value.hasSuffix(")_") {
            return nil
        }
        if value.count > maxLength {
            value = String(value.prefix(maxLength)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return value.isEmpty ? nil : value
    }

    private static func applyBootstrapProfileFields(
        _ fields: BootstrapProfileFields,
        workspaceRoot: URL) throws -> [String]
    {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: workspaceRoot, withIntermediateDirectories: true)

        let identityURL = workspaceRoot.appendingPathComponent("IDENTITY.md", isDirectory: false)
        let userURL = workspaceRoot.appendingPathComponent("USER.md", isDirectory: false)

        var summary: [String] = []

        var identityContent = (try? String(contentsOf: identityURL, encoding: .utf8))
            ?? Self.defaultIdentityMarkdown
        var identityChanged = false
        if let value = fields.assistantName {
            let update = Self.upsertMarkdownField(in: identityContent, label: "Name", value: value)
            identityContent = update.content
            identityChanged = identityChanged || update.changed
            if update.changed {
                summary.append("IDENTITY.md Name=\"\(value)\"")
            }
        }
        if let value = fields.assistantCreature {
            let update = Self.upsertMarkdownField(in: identityContent, label: "Creature", value: value)
            identityContent = update.content
            identityChanged = identityChanged || update.changed
            if update.changed {
                summary.append("IDENTITY.md Creature=\"\(value)\"")
            }
        }
        if let value = fields.assistantVibe {
            let update = Self.upsertMarkdownField(in: identityContent, label: "Vibe", value: value)
            identityContent = update.content
            identityChanged = identityChanged || update.changed
            if update.changed {
                summary.append("IDENTITY.md Vibe=\"\(value)\"")
            }
        }
        if let value = fields.assistantEmoji {
            let update = Self.upsertMarkdownField(in: identityContent, label: "Emoji", value: value)
            identityContent = update.content
            identityChanged = identityChanged || update.changed
            if update.changed {
                summary.append("IDENTITY.md Emoji=\"\(value)\"")
            }
        }
        if identityChanged {
            try Self.ensureTrailingNewline(identityContent).write(to: identityURL, atomically: true, encoding: .utf8)
        }

        var userContent = (try? String(contentsOf: userURL, encoding: .utf8))
            ?? Self.defaultUserMarkdown
        var userChanged = false
        if let value = fields.userName {
            let update = Self.upsertMarkdownField(in: userContent, label: "Name", value: value)
            userContent = update.content
            userChanged = userChanged || update.changed
            if update.changed {
                summary.append("USER.md Name=\"\(value)\"")
            }
        }
        if let value = fields.userCallName ?? fields.userName {
            let update = Self.upsertMarkdownField(
                in: userContent,
                label: "What to call them",
                value: value)
            userContent = update.content
            userChanged = userChanged || update.changed
            if update.changed {
                summary.append("USER.md What to call them=\"\(value)\"")
            }
        }
        if let value = fields.userTimezone {
            let update = Self.upsertMarkdownField(in: userContent, label: "Timezone", value: value)
            userContent = update.content
            userChanged = userChanged || update.changed
            if update.changed {
                summary.append("USER.md Timezone=\"\(value)\"")
            }
        }
        if userChanged {
            try Self.ensureTrailingNewline(userContent).write(to: userURL, atomically: true, encoding: .utf8)
        }

        return summary
    }

    private static func upsertMarkdownField(
        in content: String,
        label: String,
        value: String) -> (content: String, changed: Bool)
    {
        let fieldPrefix = "- **\(label):**"
        let replacementLine = "\(fieldPrefix) \(value)"
        var lines = content.replacingOccurrences(of: "\r\n", with: "\n").split(
            separator: "\n",
            omittingEmptySubsequences: false).map(String.init)

        for index in lines.indices {
            let trimmed = lines[index].trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.hasPrefix(fieldPrefix) else {
                continue
            }
            var changed = lines[index] != replacementLine
            lines[index] = replacementLine
            if index + 1 < lines.count,
               Self.looksLikePlaceholderLine(lines[index + 1])
            {
                lines.remove(at: index + 1)
                changed = true
            }
            return (lines.joined(separator: "\n"), changed)
        }

        let insertionIndex: Int = if let firstHeading = lines.firstIndex(where: { $0.hasPrefix("#") }) {
            min(lines.count, firstHeading + 2)
        } else {
            min(lines.count, 1)
        }
        lines.insert(replacementLine, at: insertionIndex)
        return (lines.joined(separator: "\n"), true)
    }

    private static func looksLikePlaceholderLine(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.hasPrefix("_(") && trimmed.hasSuffix(")_")
    }

    private static func ensureTrailingNewline(_ text: String) -> String {
        text.hasSuffix("\n") ? text : text + "\n"
    }

    private static let defaultIdentityMarkdown = """
    # IDENTITY.md - Who Am I?

    - **Name:**
    - **Creature:**
    - **Vibe:**
    - **Emoji:**
    - **Avatar:**
    """

    private static let defaultUserMarkdown = """
    # USER.md - About Your Human

    - **Name:**
    - **What to call them:**
    - **Pronouns:** (optional)
    - **Timezone:**
    - **Notes:**
    """

    struct BootstrapPromptResult {
        let prompt: String?
        /// Files that existed on disk but were dropped because the budget ran out.
        let droppedFiles: [String]
    }

    private func composeBootstrapPrompt() -> BootstrapPromptResult {
        guard self.config.bootstrapConfig.enabled else {
            return BootstrapPromptResult(prompt: nil, droppedFiles: [])
        }

        let workspacePath = self.config.bootstrapConfig.workspacePath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !workspacePath.isEmpty else {
            return BootstrapPromptResult(prompt: nil, droppedFiles: [])
        }

        let workspaceURL = URL(fileURLWithPath: workspacePath)
        let prioritizedFileNames = Self.prioritizedBootstrapFileNames(self.config.bootstrapConfig.fileNames)
        let manifestFileNames = Array(prioritizedFileNames.prefix(24))
        var manifestLines: [String] = []
        var bootstrapIsPresent = false
        var bootstrapHasContent = false
        manifestLines.reserveCapacity(manifestFileNames.count + 1)

        for fileName in manifestFileNames {
            let fileURL = workspaceURL.appendingPathComponent(fileName)
            let exists = FileManager.default.fileExists(atPath: fileURL.path)
            manifestLines.append("- \(fileName): \(exists ? "present" : "missing")")

            if fileName == "BOOTSTRAP.md", exists {
                bootstrapIsPresent = true
                if let rawBootstrap = try? String(contentsOf: fileURL, encoding: .utf8),
                   !rawBootstrap.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                {
                    bootstrapHasContent = true
                }
            }
        }
        if prioritizedFileNames.count > manifestFileNames.count {
            manifestLines.append(
                "- ... \(prioritizedFileNames.count - manifestFileNames.count) additional file(s) omitted")
        }

        let onboardingState = bootstrapIsPresent && bootstrapHasContent ? "pending" : "completed"
        var remainingBudget = max(0, self.config.bootstrapConfig.totalMaxChars)
        if remainingBudget <= 0 {
            return BootstrapPromptResult(prompt: nil, droppedFiles: [])
        }

        var sections: [String] = [
            "Gateway Runtime Constraints",
            "- Local chat cannot perform arbitrary file writes.",
            "- IDENTITY.md/USER.md auto-updates happen only when explicit profile fields are provided.",
            "- Never claim files were updated unless a system message in chat confirms it.",
            "- Do not claim you inspected directories/files directly; use only injected context.",
            "- When tools are available and needed, execute tool calls in the same turn; do not wait for user to say proceed.",
            "- The injected file manifest below is authoritative for this turn.",
            "- Never say BOOTSTRAP.md is missing if the manifest marks it present.",
            "- Do not claim file updates unless tool.result for that update exists in this same run.",
            "- If BOOTSTRAP.md is present and non-empty, onboarding is pending and should be completed explicitly.",
            "",
            "Injected File Manifest",
            "- onboardingState: \(onboardingState)",
            manifestLines.joined(separator: "\n"),
            "",
            "Onboarding Contract",
            "1. If onboardingState is pending, read BOOTSTRAP.md plus IDENTITY.md and USER.md before answering.",
            "2. Collect missing identity/profile fields from user.",
            "3. Use file tools (read/write/edit/apply_patch) to update IDENTITY.md and USER.md.",
            "4. Remove or empty BOOTSTRAP.md only after identity bootstrap is complete.",
            "5. Report completion only with explicit tool.result evidence.",
            "",
            "Project Context",
        ]
        var droppedFiles: [String] = []
        for filename in prioritizedFileNames {
            if remainingBudget <= 0 {
                // All remaining files are dropped.
                let filePath = workspaceURL.appendingPathComponent(filename).path
                if FileManager.default.fileExists(atPath: filePath) {
                    droppedFiles.append(filename)
                }
                continue
            }

            let filePath = workspaceURL.appendingPathComponent(filename).path
            if FileManager.default.fileExists(atPath: filePath) {
                guard let rawContent = try? String(contentsOfFile: filePath, encoding: .utf8) else {
                    continue
                }
                let perFileBudget = min(self.config.bootstrapConfig.perFileMaxChars, remainingBudget)
                let injected = self.clampBootstrapText(
                    Self.truncateBootstrapContent(
                        rawContent,
                        fileName: filename,
                        maxChars: perFileBudget),
                    budget: remainingBudget)

                if injected.isEmpty {
                    droppedFiles.append(filename)
                    continue
                }
                let section = [
                    "-- \(filename)",
                    injected,
                ].joined(separator: "\n\n")
                let sectionBudget = section.utf16.count
                if sectionBudget > remainingBudget {
                    droppedFiles.append(filename)
                    continue
                }
                sections.append(section)
                remainingBudget -= sectionBudget
            } else if self.config.bootstrapConfig.includeMissingMarkers {
                let marker = "[MISSING] expected at: \(filePath)"
                let injected = self.clampBootstrapText(marker, budget: remainingBudget)
                if injected.isEmpty {
                    break
                }
                let section = "-- \(filename)\n\(injected)"
                let sectionBudget = section.utf16.count
                if sectionBudget > remainingBudget {
                    continue
                }
                sections.append(section)
                remainingBudget -= sectionBudget
            }
        }

        if sections.count <= 1 {
            return BootstrapPromptResult(prompt: nil, droppedFiles: droppedFiles)
        }
        return BootstrapPromptResult(
            prompt: sections.joined(separator: "\n\n"),
            droppedFiles: droppedFiles)
    }

    private func searchWorkspaceMemory(query: String, limit: Int) -> [WorkspaceMemoryHit] {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuery.isEmpty, limit > 0 else {
            return []
        }
        guard let workspaceRoot = self.workspaceRootURL() else {
            return []
        }

        let loweredQuery = trimmedQuery.lowercased()
        let candidateFiles = self.workspaceMemoryFileURLs(workspaceRoot: workspaceRoot)
        if candidateFiles.isEmpty {
            return []
        }

        var hits: [WorkspaceMemoryHit] = []
        let hardLimit = max(limit * 4, limit)

        for fileURL in candidateFiles {
            guard let raw = try? String(contentsOf: fileURL, encoding: .utf8) else {
                continue
            }
            let lines = raw.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).map(String.init)
            if lines.isEmpty {
                continue
            }
            let relativePath = self.relativeWorkspacePath(fileURL: fileURL, workspaceRoot: workspaceRoot)

            for (index, rawLine) in lines.enumerated() {
                let loweredLine = rawLine.lowercased()
                guard loweredLine.contains(loweredQuery) else {
                    continue
                }

                let lineNumber = index + 1
                let lineStart = max(1, lineNumber - 1)
                let lineEnd = min(lines.count, lineNumber + 1)
                let context = lines[(lineStart - 1)...(lineEnd - 1)].joined(separator: "\n")
                let snippet = Self.clampUTF16(
                    context.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines),
                    to: 900)
                let score: Double = loweredLine == loweredQuery ? 2.0 : 1.0

                hits.append(
                    WorkspaceMemoryHit(
                        id: Self.workspaceMemoryID(relativePath: relativePath, line: lineNumber),
                        file: relativePath,
                        lineStart: lineStart,
                        lineEnd: lineEnd,
                        text: snippet,
                        score: score))

                if hits.count >= hardLimit {
                    break
                }
            }

            if hits.count >= hardLimit {
                break
            }
        }

        if hits.isEmpty {
            return []
        }
        return hits.sorted {
            if $0.score == $1.score {
                if $0.file == $1.file {
                    return $0.lineStart < $1.lineStart
                }
                return $0.file < $1.file
            }
            return $0.score > $1.score
        }.prefix(limit).map(\.self)
    }

    private func loadWorkspaceMemory(reference: WorkspaceMemoryReference) -> WorkspaceMemoryHit? {
        guard let workspaceRoot = self.workspaceRootURL() else {
            return nil
        }
        let relativePath = reference.relativePath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !relativePath.isEmpty else {
            return nil
        }

        let fileURL = workspaceRoot.appendingPathComponent(relativePath)
        let standardizedRoot = workspaceRoot.standardizedFileURL.path
        let standardizedFile = fileURL.standardizedFileURL.path
        let expectedPrefix = standardizedRoot.hasSuffix("/") ? standardizedRoot : standardizedRoot + "/"
        guard standardizedFile == standardizedRoot || standardizedFile.hasPrefix(expectedPrefix) else {
            return nil
        }

        guard let raw = try? String(contentsOf: fileURL, encoding: .utf8) else {
            return nil
        }
        let lines = raw.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).map(String.init)
        guard !lines.isEmpty else {
            return WorkspaceMemoryHit(
                id: Self.workspaceMemoryID(relativePath: relativePath, line: 1),
                file: relativePath,
                lineStart: 1,
                lineEnd: 1,
                text: "",
                score: 1.0)
        }

        let lineNumber = min(max(reference.line, 1), lines.count)
        let lineStart = max(1, lineNumber - 1)
        let lineEnd = min(lines.count, lineNumber + 1)
        let snippet = lines[(lineStart - 1)...(lineEnd - 1)].joined(separator: "\n")
            .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
        return WorkspaceMemoryHit(
            id: Self.workspaceMemoryID(relativePath: relativePath, line: lineNumber),
            file: relativePath,
            lineStart: lineStart,
            lineEnd: lineEnd,
            text: Self.clampUTF16(snippet, to: 900),
            score: 1.0)
    }

    private static func resolveWorkspaceRootURL(_ bootstrapConfig: GatewayBootstrapConfig) -> URL? {
        let workspacePath = bootstrapConfig.workspacePath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !workspacePath.isEmpty else {
            return nil
        }
        return URL(fileURLWithPath: workspacePath, isDirectory: true)
    }

    private func workspaceRootURL() -> URL? {
        Self.resolveWorkspaceRootURL(self.config.bootstrapConfig)
    }

    /// Scans workspace for memory files (MEMORY.md, memory.md, memory/**/*.md).
    /// NOTE: Only the `memory/` directory is scanned. The `dream/` directory
    /// (dream artifacts, journals, patches) is intentionally excluded to keep
    /// grounded memory separate from speculative dream content.
    private func workspaceMemoryFileURLs(workspaceRoot: URL) -> [URL] {
        let fileManager = FileManager.default
        var files: [URL] = []

        for filename in ["MEMORY.md", "memory.md"] {
            let fileURL = workspaceRoot.appendingPathComponent(filename)
            var isDirectory: ObjCBool = false
            if fileManager.fileExists(atPath: fileURL.path, isDirectory: &isDirectory), !isDirectory.boolValue {
                files.append(fileURL)
            }
        }

        let memoryDirectory = workspaceRoot.appendingPathComponent("memory", isDirectory: true)
        var isDirectory: ObjCBool = false
        if fileManager.fileExists(atPath: memoryDirectory.path, isDirectory: &isDirectory), isDirectory.boolValue,
           let enumerator = fileManager.enumerator(
               at: memoryDirectory,
               includingPropertiesForKeys: [.isRegularFileKey],
               options: [.skipsHiddenFiles])
        {
            for case let fileURL as URL in enumerator {
                guard fileURL.pathExtension.lowercased() == "md" else {
                    continue
                }
                if (try? fileURL.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true {
                    files.append(fileURL)
                }
            }
        }

        return files.sorted { $0.path < $1.path }
    }

    private func relativeWorkspacePath(fileURL: URL, workspaceRoot: URL) -> String {
        let rootPath = workspaceRoot.standardizedFileURL.path
        let filePath = fileURL.standardizedFileURL.path
        let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        if filePath.hasPrefix(prefix) {
            return String(filePath.dropFirst(prefix.count))
        }
        return fileURL.lastPathComponent
    }

    private static func workspaceMemoryID(relativePath: String, line: Int) -> String {
        let encodedPath = self.base64URLEncode(relativePath)
        return "filemem:\(encodedPath):\(max(1, line))"
    }

    private static func parseWorkspaceMemoryID(_ raw: String) -> WorkspaceMemoryReference? {
        guard raw.hasPrefix("filemem:") else {
            return nil
        }
        let tail = String(raw.dropFirst("filemem:".count))
        guard let splitIndex = tail.lastIndex(of: ":") else {
            return nil
        }
        let encodedPath = String(tail[..<splitIndex])
        let lineText = String(tail[tail.index(after: splitIndex)...])
        guard let line = Int(lineText), line > 0 else {
            return nil
        }
        let decodedPath =
            self.base64URLDecode(encodedPath)
            ?? encodedPath.removingPercentEncoding
            ?? encodedPath
        guard !decodedPath.isEmpty else {
            return nil
        }
        return WorkspaceMemoryReference(relativePath: decodedPath, line: line)
    }

    private static func base64URLEncode(_ value: String) -> String {
        Data(value.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func base64URLDecode(_ value: String) -> String? {
        var base64 = value
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let padding = base64.count % 4
        if padding != 0 {
            base64 += String(repeating: "=", count: 4 - padding)
        }
        guard let data = Data(base64Encoded: base64),
              let decoded = String(data: data, encoding: .utf8)
        else {
            return nil
        }
        return decoded
    }

    private static func normalizedThinkingLevel(_ raw: String?) -> String? {
        let normalized = raw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard let value = normalized, !value.isEmpty else {
            return nil
        }
        switch value {
        case "off", "disable", "disabled", "none":
            return "off"
        case "low", "minimal", "default":
            return "low"
        case "medium", "mid":
            return "medium"
        case "high", "on", "true":
            return "high"
        case "xhigh", "x-high", "extra-high", "extra_high":
            return "xhigh"
        default:
            return value
        }
    }

    private static func truncateBootstrapContent(
        _ raw: String,
        fileName: String,
        maxChars: Int) -> String
    {
        let content = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if content.utf16.count <= maxChars {
            return content
        }

        let safeMax = max(1, maxChars)
        let headChars = Int(Double(safeMax) * 0.7)
        let tailChars = Int(Double(safeMax) * 0.2)

        if safeMax <= headChars + tailChars + 20 {
            return Self.clampUTF16(content, to: safeMax)
        }

        let head = Self.prefixByUTF16(content, headChars)
        let tail = Self.suffixByUTF16(content, tailChars)
        let marker = "[...truncated, read \(fileName) for full content...]"
        let body = [head, "", marker, "", tail].joined(separator: "\n")
        return Self.clampUTF16(body, to: safeMax)
    }

    private func clampBootstrapText(_ text: String, budget: Int) -> String {
        Self.clampUTF16(text, to: max(0, budget))
    }

    private static func clampUTF16(_ text: String, to maxChars: Int) -> String {
        guard maxChars > 0 else {
            return ""
        }
        let safeLimit = max(0, maxChars)
        let utf16Count = text.utf16.count
        if utf16Count <= safeLimit {
            return text
        }
        if safeLimit <= 1 {
            return String(decoding: text.utf16.prefix(safeLimit), as: UTF16.self)
        }
        return String(decoding: text.utf16.prefix(safeLimit - 1), as: UTF16.self) + "…"
    }

    private static func prefixByUTF16(_ text: String, _ maxChars: Int) -> String {
        let limited = max(0, maxChars)
        return String(decoding: text.utf16.prefix(limited), as: UTF16.self)
    }

    private static func suffixByUTF16(_ text: String, _ maxChars: Int) -> String {
        let limited = max(0, maxChars)
        let value = text.utf16
        if limited == 0 || value.count == 0 {
            return ""
        }
        if value.count <= limited {
            return text
        }
        let suffixStart = value.index(value.endIndex, offsetBy: -limited)
        let suffixSlice = value[suffixStart..<value.endIndex]
        return String(decoding: suffixSlice, as: UTF16.self)
    }
}
