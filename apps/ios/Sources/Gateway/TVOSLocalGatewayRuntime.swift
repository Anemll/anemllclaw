#if os(tvOS)
import Darwin
import Foundation
import Network
import Observation
import OpenClawGatewayCore
import os

struct TVOSGatewayRuntimeLogEntry: Identifiable, Sendable {
    enum Level: String, Sendable {
        case info
        case warning
        case error
    }

    let id: UUID
    let timestamp: Date
    let level: Level
    let message: String

    init(id: UUID = UUID(), timestamp: Date = Date(), level: Level = .info, message: String) {
        self.id = id
        self.timestamp = timestamp
        self.level = level
        self.message = message
    }
}

struct TVOSGatewayChatTurn: Identifiable, Sendable, Equatable {
    let id: String
    let role: String
    let text: String
    let timestamp: Date?
    let runID: String?

    init(
        id: String,
        role: String,
        text: String,
        timestamp: Date?,
        runID: String?)
    {
        self.id = id
        self.role = role
        self.text = text
        self.timestamp = timestamp
        self.runID = runID
    }
}

private struct TVOSGatewayUpstreamConfigLoadResult: Sendable {
    let config: GatewayUpstreamWebSocketConfig?
    let urlText: String?
    let errorText: String?
}

struct TVOSGatewayControlPlaneSettings: Sendable, Equatable {
    var authMode: GatewayCoreAuthMode
    var authToken: String
    var authPassword: String

    var upstreamURL: String
    var upstreamToken: String
    var upstreamPassword: String
    var upstreamRole: String
    var upstreamScopesCSV: String

    var localLLMProvider: GatewayLocalLLMProviderKind
    var localLLMBaseURL: String
    var localLLMAPIKey: String
    var localLLMModel: String

    static let `default` = TVOSGatewayControlPlaneSettings(
        authMode: .none,
        authToken: "",
        authPassword: "",
        upstreamURL: "",
        upstreamToken: "",
        upstreamPassword: "",
        upstreamRole: "node",
        upstreamScopesCSV: "",
        localLLMProvider: .disabled,
        localLLMBaseURL: "",
        localLLMAPIKey: "",
        localLLMModel: "")
}

private enum TVOSRuntimeAdminBridgeError: LocalizedError {
    case runtimeUnavailable
    case invalidRequest(String)

    var errorDescription: String? {
        switch self {
        case .runtimeUnavailable:
            return "runtime unavailable"
        case let .invalidRequest(message):
            return message
        }
    }
}

private actor TVOSRuntimeAdminBridge: GatewayLocalMethodRouterAdminBridge {
    private weak var runtime: TVOSLocalGatewayRuntime?

    init(runtime: TVOSLocalGatewayRuntime) {
        self.runtime = runtime
    }

    func configGet(nowMs: Int64) async throws -> GatewayJSONValue {
        guard let runtime = self.runtime else {
            throw TVOSRuntimeAdminBridgeError.runtimeUnavailable
        }
        return await runtime.adminConfigSnapshot(nowMs: nowMs)
    }

    func configSet(params: GatewayJSONValue, nowMs: Int64) async throws -> GatewayJSONValue {
        guard let runtime = self.runtime else {
            throw TVOSRuntimeAdminBridgeError.runtimeUnavailable
        }
        return try await runtime.adminConfigSet(params: params, nowMs: nowMs)
    }

    func runtimeRestart(nowMs: Int64) async throws -> GatewayJSONValue {
        guard let runtime = self.runtime else {
            throw TVOSRuntimeAdminBridgeError.runtimeUnavailable
        }
        return await runtime.adminRuntimeRestart(nowMs: nowMs)
    }
}

@MainActor
@Observable
final class TVOSLocalGatewayRuntime {
    private static let runtimeLogger = Logger(subsystem: "ai.openclaw.ios", category: "OpenClawTV.Runtime")

    enum State: String, Sendable {
        case stopped
        case running
    }

    enum ListenerState: String, Sendable {
        case stopped
        case listening
        case failed
    }

    private(set) var state: State = .stopped

    // Primary WebSocket listener used by OpenClaw clients.
    private(set) var listenerState: ListenerState = .stopped
    private(set) var listenerPort: UInt16?
    private(set) var listenerErrorText: String?

    // Optional debug TCP listener for raw JSON-line testing.
    private(set) var tcpListenerState: ListenerState = .stopped
    private(set) var tcpListenerPort: UInt16?
    private(set) var tcpListenerErrorText: String?

    // Optional upstream full gateway used for delegated Node-only methods.
    private(set) var upstreamConfigured: Bool = false
    private(set) var upstreamURLText: String?
    private(set) var upstreamConfigErrorText: String?
    private(set) var lastUpstreamProbeSucceeded: Bool?
    private(set) var lastUpstreamProbeErrorText: String?

    private(set) var listenerAuthMode: GatewayCoreAuthMode
    private(set) var listenerAuthHint: String?
    private(set) var controlPlaneSettings: TVOSGatewayControlPlaneSettings
    private(set) var localLLMConfigured: Bool
    private(set) var localLLMProviderLabel: String
    private(set) var localLLMConfigErrorText: String?

    private(set) var webSocketRetryAttempt: Int = 0
    private(set) var webSocketRetryDelaySeconds: Int?
    private(set) var tcpRetryAttempt: Int = 0
    private(set) var tcpRetryDelaySeconds: Int?

    private(set) var localIPv4Address: String?
    private(set) var localIPv4Addresses: [String]

    private(set) var lastProbeSucceeded: Bool?
    private(set) var lastWebSocketProbeSucceeded: Bool?
    private(set) var lastWebSocketProbeErrorText: String?
    private(set) var lastTCPProbeSucceeded: Bool?
    private(set) var lastTCPProbeErrorText: String?
    private(set) var lastLocalLLMProbeSucceeded: Bool?
    private(set) var lastLocalLLMProbeErrorText: String?
    private(set) var lastLocalLLMProbeResponseText: String?
    private(set) var lastAgentRunProbeSucceeded: Bool?
    private(set) var lastAgentRunProbeErrorText: String?
    private(set) var lastAgentRunProbeResponseText: String?
    private(set) var lastAgentStatusProbeSucceeded: Bool?
    private(set) var lastAgentStatusProbeErrorText: String?
    private(set) var lastAgentStatusProbeResponseText: String?
    private(set) var lastAgentAbortProbeSucceeded: Bool?
    private(set) var lastAgentAbortProbeErrorText: String?
    private(set) var lastAgentAbortProbeResponseText: String?
    private(set) var lastAgentRunID: String?
    private(set) var chatSessionKey: String
    private(set) var chatTurns: [TVOSGatewayChatTurn]
    private(set) var chatSendInProgress: Bool
    private(set) var chatProgressText: String?
    private(set) var chatLastErrorText: String?
    private(set) var diagnosticsLog: [TVOSGatewayRuntimeLogEntry]

    private let webSocketListenPortPreference: UInt16
    private let tcpListenPortPreference: UInt16
    private let exposeTCPListener: Bool
    private var gatewayAuthConfig: GatewayCoreAuthConfig
    private let transportOverride: GatewayLoopbackTransport?

    private var host: GatewayLoopbackHost?
    private var webSocketServer: GatewayWebSocketServer?
    private var tcpServer: GatewayTCPJSONServer?
    private var upstreamClient: GatewayUpstreamWebSocketClient?

    private var webSocketRetryTask: Task<Void, Never>?
    private var tcpRetryTask: Task<Void, Never>?
    private var chatHistoryPollTask: Task<Void, Never>?
    private var chatSendStartedAt: Date?
    private var runtimeTransitionTask: Task<Void, Never> = Task {}
    private var runtimeTransitionInProgress = false

    private static let maxDiagnosticsLogEntries = 150
    private static let listenerRestartQuiesceDurationNanoseconds: UInt64 = 120_000_000
    private static let defaultChatSessionKey = "main"
    private static let defaultChatHistoryLimit = 240
    private static let chatProgressPollIntervalNanoseconds: UInt64 = 700_000_000

    init(
        exposeTCPListener: Bool = true,
        listenPort: UInt16 = 18_789,
        tcpDebugPort: UInt16 = 18_790,
        transport: GatewayLoopbackTransport? = nil,
        upstreamConfig: GatewayUpstreamWebSocketConfig? = nil,
        tcpAuthConfig: GatewayCoreAuthConfig = .none)
    {
        self.exposeTCPListener = exposeTCPListener
        self.webSocketListenPortPreference = listenPort
        self.tcpListenPortPreference = tcpDebugPort
        self.transportOverride = transport

        var settings = Self.loadControlPlaneSettings()
        if tcpAuthConfig.mode != .none {
            settings.authMode = tcpAuthConfig.mode
            settings.authToken = tcpAuthConfig.token ?? ""
            settings.authPassword = tcpAuthConfig.password ?? ""
        }
        if let upstreamConfig {
            settings.upstreamURL = upstreamConfig.url.absoluteString
            settings.upstreamToken = upstreamConfig.token ?? ""
            settings.upstreamPassword = upstreamConfig.password ?? ""
            settings.upstreamRole = upstreamConfig.role ?? "node"
            settings.upstreamScopesCSV = upstreamConfig.scopes?.joined(separator: ",") ?? ""
        }

        let normalizedSettings = Self.normalizedSettings(settings)
        let needsInitAuthNormalization = normalizedSettings != settings
        let initialAuthConfig = Self.makeAuthConfig(from: normalizedSettings)
        self.controlPlaneSettings = normalizedSettings
        self.gatewayAuthConfig = initialAuthConfig
        self.listenerAuthMode = initialAuthConfig.mode
        self.listenerAuthHint = Self.authHint(for: initialAuthConfig)
        self.localLLMConfigured = false
        self.localLLMProviderLabel = normalizedSettings.localLLMProvider.rawValue
        self.localLLMConfigErrorText = nil

        self.diagnosticsLog = []
        self.localIPv4Address = nil
        self.localIPv4Addresses = []
        self.lastUpstreamProbeSucceeded = nil
        self.lastUpstreamProbeErrorText = nil
        self.lastLocalLLMProbeSucceeded = nil
        self.lastLocalLLMProbeErrorText = nil
        self.lastLocalLLMProbeResponseText = nil
        self.lastAgentRunProbeSucceeded = nil
        self.lastAgentRunProbeErrorText = nil
        self.lastAgentRunProbeResponseText = nil
        self.lastAgentStatusProbeSucceeded = nil
        self.lastAgentStatusProbeErrorText = nil
        self.lastAgentStatusProbeResponseText = nil
        self.lastAgentAbortProbeSucceeded = nil
        self.lastAgentAbortProbeErrorText = nil
        self.lastAgentAbortProbeResponseText = nil
        self.lastAgentRunID = nil
        self.chatSessionKey = Self.defaultChatSessionKey
        self.chatTurns = []
        self.chatSendInProgress = false
        self.chatProgressText = nil
        self.chatLastErrorText = nil

        self.host = nil
        self.webSocketServer = nil
        self.tcpServer = nil
        self.upstreamClient = nil
        self.webSocketRetryTask = nil
        self.tcpRetryTask = nil
        self.chatHistoryPollTask = nil
        self.chatSendStartedAt = nil

        self.rebuildGatewayStack()
        self.refreshLocalNetworkAddresses()
        if needsInitAuthNormalization {
            self.appendLog("auth settings normalized during runtime init", level: .warning)
            self.logAuthNormalization(
                from: settings,
                to: normalizedSettings,
                context: "runtime init")
            Self.persistControlPlaneSettings(normalizedSettings)
            self.verifyPersistedControlPlaneSettings(normalizedSettings)
        }
        self.logControlPlaneConfigDump(context: "runtime initialized")

        self.appendLog(
            "runtime initialized wsPort=\(listenPort)"
                + " tcpDebug=\(exposeTCPListener ? "enabled" : "disabled")"
                + " auth=\(self.gatewayAuthConfig.mode.rawValue)")
        if self.upstreamConfigured {
            self.appendLog("upstream configured url=\(self.upstreamURLText ?? "(unknown)")")
        } else if let errorText = self.upstreamConfigErrorText {
            self.appendLog("upstream config error: \(errorText)", level: .error)
        } else {
            self.appendLog("upstream not configured", level: .warning)
        }
    }

    func start() async {
        guard !self.runtimeTransitionInProgress else {
            self.appendLog("runtime start skipped: transition in progress")
            return
        }
        guard self.state == .stopped else {
            self.appendLog("runtime start skipped: already running")
            return
        }
        await self.withRuntimeTransition("start") {
            await self.startLocked()
        }
    }

    private func withRuntimeTransition(
        _ label: String,
        operation: @escaping @MainActor () async -> Void
    ) async {
        if self.runtimeTransitionInProgress {
            self.appendLog("runtime transition skipped: another transition in progress [\(label)]")
            return
        }

        self.runtimeTransitionInProgress = true
        let previousTransition = self.runtimeTransitionTask
        let nextTransition = Task { @MainActor in
            await previousTransition.value
            self.appendLog("runtime transition start [\(label)]")
            defer {
                self.runtimeTransitionInProgress = false
                self.appendLog("runtime transition end [\(label)]")
            }
            await operation()
        }

        self.runtimeTransitionTask = nextTransition
        await nextTransition.value
    }

    private func startLocked() async {
        guard self.state == .stopped else {
            self.appendLog("runtime start skipped: already running")
            return
        }

        self.refreshLocalNetworkAddresses()
        await self.host?.start()
        await self.startWebSocketListenerIfNeeded()
        guard self.listenerState == .listening else {
            self.state = .stopped
            self.appendLog("runtime start aborted: websocket listener failed")
            return
        }
        if self.exposeTCPListener {
            await self.startTCPListenerIfNeeded()
        }
        self.state = .running
        await self.refreshChatHistory(limit: Self.defaultChatHistoryLimit, quiet: true)
        self.appendLog(
            "runtime running ws=\(self.listenerState.rawValue) tcp=\(self.tcpListenerState.rawValue)")
    }

    func restart(with settings: TVOSGatewayControlPlaneSettings) async {
        await self.withRuntimeTransition("restart") {
            self.appendLog("runtime restart requested")

            let normalized = Self.normalizedSettings(settings)
            if normalized != settings {
                self.logAuthNormalization(from: settings, to: normalized, context: "runtime restart")
            }

            let hadRunning = self.state == .running
            if hadRunning {
                await self.stopLocked()
                try? await Task.sleep(nanoseconds: Self.listenerRestartQuiesceDurationNanoseconds)
            }

            self.controlPlaneSettings = normalized
            Self.persistControlPlaneSettings(normalized)
            self.verifyPersistedControlPlaneSettings(normalized)
            self.logControlPlaneConfigDump(context: "settings applied via restart")
            self.rebuildGatewayStack()
            self.clearErrorStates()

            if hadRunning {
                await self.startLocked()
                await self.probeHealth()
                await self.probeHealthOverWebSocket()
                await self.probeUpstreamHealth()
            }
        }
    }

    func stop() async {
        await self.withRuntimeTransition("stop") {
            await self.stopLocked()
        }
    }

    private func stopLocked() async {
        guard self.state != .stopped else { return }

        self.appendLog("runtime stop requested")
        self.stopChatProgressPolling()

        self.webSocketRetryTask?.cancel()
        self.webSocketRetryTask = nil
        self.webSocketRetryAttempt = 0
        self.webSocketRetryDelaySeconds = nil

        self.tcpRetryTask?.cancel()
        self.tcpRetryTask = nil
        self.tcpRetryAttempt = 0
        self.tcpRetryDelaySeconds = nil

        if self.exposeTCPListener {
            await self.stopTCPListener()
        }
        await self.stopWebSocketListener()

        if let upstreamClient = self.upstreamClient {
            await upstreamClient.disconnect()
            self.appendLog("upstream disconnected")
        }

        await self.host?.stop()

        self.state = .stopped
        self.lastProbeSucceeded = nil
        self.lastWebSocketProbeSucceeded = nil
        self.lastWebSocketProbeErrorText = nil
        self.lastTCPProbeSucceeded = nil
        self.lastTCPProbeErrorText = nil
        self.lastUpstreamProbeSucceeded = nil
        self.lastUpstreamProbeErrorText = nil
        self.lastLocalLLMProbeSucceeded = nil
        self.lastLocalLLMProbeErrorText = nil
        self.lastLocalLLMProbeResponseText = nil
        self.lastAgentRunProbeSucceeded = nil
        self.lastAgentRunProbeErrorText = nil
        self.lastAgentRunProbeResponseText = nil
        self.lastAgentStatusProbeSucceeded = nil
        self.lastAgentStatusProbeErrorText = nil
        self.lastAgentStatusProbeResponseText = nil
        self.lastAgentAbortProbeSucceeded = nil
        self.lastAgentAbortProbeErrorText = nil
        self.lastAgentAbortProbeResponseText = nil
        self.lastAgentRunID = nil
        self.chatSendInProgress = false
        self.chatProgressText = nil
        self.chatLastErrorText = nil
        self.chatSendStartedAt = nil
        self.appendLog("runtime stopped")
    }

    func clearDiagnosticsLog() {
        self.diagnosticsLog.removeAll(keepingCapacity: true)
        self.appendLog("diagnostics log cleared")
    }

    func clearErrorStates() {
        self.listenerErrorText = nil
        self.tcpListenerErrorText = nil
        self.lastWebSocketProbeErrorText = nil
        self.lastTCPProbeErrorText = nil
        self.lastUpstreamProbeErrorText = nil
        self.upstreamConfigErrorText = nil
        self.localLLMConfigErrorText = nil
        self.lastLocalLLMProbeErrorText = nil
        self.lastAgentRunProbeErrorText = nil
        self.lastAgentRunProbeResponseText = nil
        self.lastAgentStatusProbeErrorText = nil
        self.lastAgentStatusProbeResponseText = nil
        self.lastAgentAbortProbeErrorText = nil
        self.lastAgentAbortProbeResponseText = nil
        self.chatLastErrorText = nil
        self.webSocketRetryAttempt = 0
        self.webSocketRetryDelaySeconds = nil
        self.tcpRetryAttempt = 0
        self.tcpRetryDelaySeconds = nil
        self.appendLog("error states cleared")
    }

    func applyControlPlaneSettings(_ next: TVOSGatewayControlPlaneSettings) async {
        let normalized = Self.normalizedSettings(next)
        await self.withRuntimeTransition("apply settings") {
            if normalized != next {
                self.logAuthNormalization(from: next, to: normalized, context: "apply settings")
            }

            guard normalized != self.controlPlaneSettings else {
                self.appendLog("control plane settings unchanged")
                return
            }

            let wasRunning = self.state == .running
            if wasRunning {
                await self.stopLocked()
            }

            self.controlPlaneSettings = normalized
            Self.persistControlPlaneSettings(normalized)
            self.verifyPersistedControlPlaneSettings(normalized)
            self.logControlPlaneConfigDump(context: "settings applied")
            self.rebuildGatewayStack()
            self.clearErrorStates()
            self.appendLog(
                "control plane settings applied auth=\(normalized.authMode.rawValue)"
                    + " upstream=\(Self.trimmed(normalized.upstreamURL) ?? "(none)")"
                    + " llm=\(normalized.localLLMProvider.rawValue)")

            if wasRunning {
                if self.exposeTCPListener {
                    try? await Task.sleep(nanoseconds: Self.listenerRestartQuiesceDurationNanoseconds)
                }
                await self.startLocked()
                await self.probeHealth()
                await self.probeHealthOverWebSocket()
                await self.probeUpstreamHealth()
            }
        }
    }

    func refreshLocalNetworkAddresses() {
        let addresses = Self.collectLocalIPv4Interfaces()
        self.localIPv4Address = addresses.first?.address
        self.localIPv4Addresses = addresses.map(\.address)
    }

    func setChatSessionKey(_ rawValue: String) async {
        let normalized = Self.normalizedSessionKey(rawValue)
        guard normalized != self.chatSessionKey else { return }
        self.chatSessionKey = normalized
        self.chatTurns = []
        self.chatLastErrorText = nil
        self.appendLog("chat session switched to \(normalized)")
        await self.refreshChatHistory(limit: Self.defaultChatHistoryLimit, quiet: true)
    }

    func refreshChatHistory(limit: Int = 240, quiet: Bool = false) async {
        guard self.state == .running else {
            if !quiet {
                self.chatLastErrorText = "runtime not running"
            }
            return
        }
        guard let host = self.host else {
            if !quiet {
                self.chatLastErrorText = "runtime host unavailable"
                self.appendLog("chat history refresh failed: runtime host unavailable", level: .error)
            }
            return
        }

        let boundedLimit = max(1, min(limit, 1_000))
        let request = GatewayRequestFrame(
            id: UUID().uuidString,
            method: "chat.history",
            params: .object([
                "sessionKey": .string(self.chatSessionKey),
                "limit": .integer(Int64(boundedLimit)),
            ]))

        do {
            let response = try await host.invoke(request)
            guard response.ok else {
                let message = response.error?.message ?? "chat.history failed"
                if !quiet {
                    self.chatLastErrorText = message
                    self.appendLog("chat.history failed: \(message)", level: .warning)
                }
                return
            }

            self.chatTurns = Self.decodeChatTurns(from: response.payload)
            if !quiet {
                self.chatLastErrorText = nil
            }
        } catch {
            if !quiet {
                self.chatLastErrorText = error.localizedDescription
                self.appendLog("chat.history threw: \(error.localizedDescription)", level: .error)
            }
        }
    }

    func sendChatMessage(_ rawMessage: String) async {
        let message = rawMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty else { return }

        guard self.state == .running else {
            self.chatLastErrorText = "runtime not running"
            self.appendLog("chat.send skipped: runtime not running", level: .warning)
            return
        }
        guard let host = self.host else {
            self.chatLastErrorText = "runtime host unavailable"
            self.appendLog("chat.send failed: runtime host unavailable", level: .error)
            return
        }
        guard !self.chatSendInProgress else {
            self.appendLog("chat.send skipped: another chat send is already in progress", level: .warning)
            return
        }

        self.chatSendInProgress = true
        self.chatSendStartedAt = Date()
        self.chatProgressText = "Sending user message…"
        self.chatLastErrorText = nil
        await self.refreshChatHistory(limit: Self.defaultChatHistoryLimit, quiet: true)
        self.startChatProgressPolling()
        defer {
            self.stopChatProgressPolling()
            self.chatSendInProgress = false
            self.chatSendStartedAt = nil
            self.chatProgressText = nil
        }

        self.appendLog("chat.send start session=\(self.chatSessionKey) chars=\(message.count)")
        let request = GatewayRequestFrame(
            id: UUID().uuidString,
            method: "chat.send",
            params: .object([
                "sessionKey": .string(self.chatSessionKey),
                "message": .string(message),
                "thinking": .string("low"),
                "idempotencyKey": .string(UUID().uuidString),
            ]))

        do {
            let response = try await host.invoke(request)
            guard response.ok else {
                let code = response.error?.code ?? "UNKNOWN"
                let message = response.error?.message ?? "chat.send failed"
                self.chatLastErrorText = message
                self.appendLog("chat.send failed code=\(code) message=\(message)", level: .error)
                return
            }

            self.chatProgressText = "Refreshing conversation…"
            await self.refreshChatHistory(limit: Self.defaultChatHistoryLimit, quiet: true)
            let runID = Self.extractChatRunID(from: response.payload) ?? "(unknown)"
            self.appendLog("chat.send ok runId=\(runID)")
        } catch {
            self.chatLastErrorText = error.localizedDescription
            self.appendLog("chat.send threw: \(error.localizedDescription)", level: .error)
            return
        }
    }

    private func startChatProgressPolling() {
        self.stopChatProgressPolling()
        self.chatHistoryPollTask = Task { @MainActor in
            while !Task.isCancelled && self.chatSendInProgress {
                try? await Task.sleep(nanoseconds: Self.chatProgressPollIntervalNanoseconds)
                guard !Task.isCancelled, self.chatSendInProgress else { break }

                await self.refreshChatHistory(limit: Self.defaultChatHistoryLimit, quiet: true)
                if let startedAt = self.chatSendStartedAt {
                    let elapsed = max(0, Int(Date().timeIntervalSince(startedAt)))
                    self.chatProgressText = "Assistant is thinking… \(elapsed)s"
                } else {
                    self.chatProgressText = "Assistant is thinking…"
                }
            }
        }
    }

    private func stopChatProgressPolling() {
        self.chatHistoryPollTask?.cancel()
        self.chatHistoryPollTask = nil
    }

    func probeHealth(nowMs: Int64 = GatewayCore.currentTimestampMs()) async {
        guard self.state == .running else {
            self.lastProbeSucceeded = nil
            return
        }
        guard let host = self.host else {
            self.lastProbeSucceeded = false
            self.appendLog("in-process probe failed: runtime host unavailable", level: .error)
            return
        }
        do {
            let response = try await host.invoke(
                GatewayRequestFrame(id: UUID().uuidString, method: "health"),
                nowMs: nowMs)
            self.lastProbeSucceeded = response.ok
            if response.ok {
                self.appendLog("in-process probe ok")
            } else {
                self.appendLog(
                    "in-process probe failed: \(response.error?.message ?? "unknown error")",
                    level: .warning)
            }
        } catch {
            self.lastProbeSucceeded = false
            self.appendLog("in-process probe threw: \(error.localizedDescription)", level: .error)
        }
    }

    func probeLocalLLM(prompt: String = "Who are you?") async {
        guard self.state == .running else {
            self.appendLog("local llm probe skipped: runtime not running", level: .warning)
            self.lastLocalLLMProbeSucceeded = nil
            self.lastLocalLLMProbeErrorText = nil
            self.lastLocalLLMProbeResponseText = nil
            return
        }
        guard self.localLLMConfigured else {
            let message = if self.controlPlaneSettings.localLLMProvider == .disabled {
                "local llm provider is disabled"
            } else {
                "local llm config is incomplete"
            }
            self.lastLocalLLMProbeSucceeded = false
            self.lastLocalLLMProbeErrorText = message
            self.lastLocalLLMProbeResponseText = nil
            self.appendLog("local llm probe skipped: \(message)", level: .warning)
            return
        }
        guard let host = self.host else {
            self.lastLocalLLMProbeSucceeded = false
            self.lastLocalLLMProbeErrorText = "runtime host unavailable"
            self.lastLocalLLMProbeResponseText = nil
            self.appendLog("local llm probe failed: runtime host unavailable", level: .error)
            return
        }

        let sessionKey = "tvos-agentic-llm-probe"
        let normalizedPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "Who are you?"
            : prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let baseURLText = Self.trimmed(self.controlPlaneSettings.localLLMBaseURL) ?? "(none)"
        let modelText = Self.trimmed(self.controlPlaneSettings.localLLMModel) ?? "(none)"
        self.appendLog(
            "local llm probe start provider=\(self.controlPlaneSettings.localLLMProvider.rawValue)"
                + " baseURL=\(baseURLText) model=\(modelText) session=\(sessionKey)")

        do {
            let sendRequest = GatewayRequestFrame(
                id: UUID().uuidString,
                method: "chat.send",
                params: .object([
                    "sessionKey": .string(sessionKey),
                    "message": .string(normalizedPrompt),
                    "thinking": .string("low"),
                    "idempotencyKey": .string(UUID().uuidString),
                ]))
            let sendResponse = try await host.invoke(sendRequest)
            guard sendResponse.ok else {
                let message = sendResponse.error?.message ?? "local llm chat.send failed"
                self.lastLocalLLMProbeSucceeded = false
                self.lastLocalLLMProbeErrorText = message
                self.lastLocalLLMProbeResponseText = nil
                self.appendLog(
                    "local llm probe chat.send failed code=\(sendResponse.error?.code ?? "UNKNOWN") message=\(message)",
                    level: .error)
                return
            }

            let historyRequest = GatewayRequestFrame(
                id: UUID().uuidString,
                method: "chat.history",
                params: .object([
                    "sessionKey": .string(sessionKey),
                    "limit": .integer(12),
                ]))
            let historyResponse = try await host.invoke(historyRequest)
            guard historyResponse.ok else {
                let message = historyResponse.error?.message ?? "local llm chat.history failed"
                self.lastLocalLLMProbeSucceeded = false
                self.lastLocalLLMProbeErrorText = message
                self.lastLocalLLMProbeResponseText = nil
                self.appendLog(
                    "local llm probe chat.history failed"
                        + " code=\(historyResponse.error?.code ?? "UNKNOWN")"
                        + " message=\(message)",
                    level: .error)
                return
            }

            let replyText = Self.latestAssistantReplyText(from: historyResponse.payload)
            self.lastLocalLLMProbeSucceeded = true
            self.lastLocalLLMProbeErrorText = nil
            self.lastLocalLLMProbeResponseText = replyText
            if let replyText {
                self.appendLog("local llm probe ok prompt=\"\(normalizedPrompt)\"")
                self.appendLog("local llm probe reply: \(replyText)")
            } else {
                self.appendLog("local llm probe ok but no assistant reply found in history", level: .warning)
            }
        } catch {
            self.lastLocalLLMProbeSucceeded = false
            self.lastLocalLLMProbeErrorText = error.localizedDescription
            self.lastLocalLLMProbeResponseText = nil
            self.appendLog("local llm probe threw: \(error.localizedDescription)", level: .error)
        }
    }

    func probeAgentRun() async {
        let runID = "tvos-agent-run-\(UUID().uuidString)"
        let sessionKey = "tvos-agent-session"
        let goal = "Summarize this device readiness in one short sentence."

        guard self.state == .running else {
            self.appendLog("agent run probe skipped: runtime not running", level: .warning)
            self.lastAgentRunProbeSucceeded = nil
            self.lastAgentRunProbeErrorText = nil
            self.lastAgentRunProbeResponseText = nil
            return
        }
        guard let host = self.host else {
            self.lastAgentRunProbeSucceeded = false
            self.lastAgentRunProbeErrorText = "runtime host unavailable"
            self.lastAgentRunProbeResponseText = nil
            self.appendLog("agent run probe failed: runtime host unavailable", level: .error)
            return
        }

        self.appendLog("agent run probe start runId=\(runID)")
        let request = GatewayRequestFrame(
            id: UUID().uuidString,
            method: "agents.run",
            params: .object([
                "runId": .string(runID),
                "sessionKey": .string(sessionKey),
                "goal": .string(goal),
                "maxSteps": .integer(1),
            ]))

        do {
            let response = try await host.invoke(request)
            self.lastAgentRunID = Self.extractAgentRunID(from: response.payload) ?? runID
            self.lastAgentRunProbeSucceeded = response.ok
            self.lastAgentRunProbeErrorText = response.error?.message
            if response.ok {
                self.lastAgentRunProbeResponseText = Self.formatAgentSnapshot(from: response.payload)
                self.appendLog(
                    "agent run probe ok runId=\(self.lastAgentRunID ?? runID)")
                if let snapshot = self.lastAgentRunProbeResponseText, !snapshot.isEmpty {
                    self.appendLog("agent run probe snapshot: \(snapshot)")
                }
            } else {
                let codeText = response.error?.code ?? "UNKNOWN"
                self.lastAgentRunProbeResponseText = nil
                self.appendLog(
                    "agent run probe failed code=\(codeText) message=\(response.error?.message ?? "unknown error")",
                    level: .warning)
            }
        } catch {
            self.lastAgentRunProbeSucceeded = false
            self.lastAgentRunProbeErrorText = error.localizedDescription
            self.lastAgentRunProbeResponseText = nil
            self.appendLog("agent run probe threw: \(error.localizedDescription)", level: .error)
        }
    }

    func probeAgentStatus() async {
        guard self.state == .running else {
            self.appendLog("agent status probe skipped: runtime not running", level: .warning)
            self.lastAgentStatusProbeSucceeded = nil
            self.lastAgentStatusProbeErrorText = nil
            self.lastAgentStatusProbeResponseText = nil
            return
        }
        guard let runID = self.lastAgentRunID else {
            self.lastAgentStatusProbeSucceeded = false
            self.lastAgentStatusProbeErrorText = "no active agent run id"
            self.lastAgentStatusProbeResponseText = nil
            self.appendLog("agent status probe skipped: no known run id", level: .warning)
            return
        }
        guard let host = self.host else {
            self.lastAgentStatusProbeSucceeded = false
            self.lastAgentStatusProbeErrorText = "runtime host unavailable"
            self.lastAgentStatusProbeResponseText = nil
            self.appendLog("agent status probe failed: runtime host unavailable", level: .error)
            return
        }

        self.appendLog("agent status probe start runId=\(runID)")
        let request = GatewayRequestFrame(
            id: UUID().uuidString,
            method: "agents.status",
            params: .object(["runId": .string(runID)]))
        do {
            let response = try await host.invoke(request)
            self.lastAgentStatusProbeSucceeded = response.ok
            self.lastAgentStatusProbeErrorText = response.error?.message
            if response.ok {
                self.lastAgentStatusProbeResponseText = Self.formatAgentSnapshot(from: response.payload)
                self.appendLog("agent status ok runId=\(runID)")
                if let snapshot = self.lastAgentStatusProbeResponseText, !snapshot.isEmpty {
                    self.appendLog("agent status snapshot: \(snapshot)")
                }
            } else {
                let codeText = response.error?.code ?? "UNKNOWN"
                self.lastAgentStatusProbeResponseText = nil
                self.appendLog(
                    "agent status probe failed code=\(codeText) message=\(response.error?.message ?? "unknown error")",
                    level: .warning)
            }
        } catch {
            self.lastAgentStatusProbeSucceeded = false
            self.lastAgentStatusProbeErrorText = error.localizedDescription
            self.lastAgentStatusProbeResponseText = nil
            self.appendLog("agent status probe threw: \(error.localizedDescription)", level: .error)
        }
    }

    func abortAgentRun() async {
        guard self.state == .running else {
            self.appendLog("agent abort skipped: runtime not running", level: .warning)
            self.lastAgentAbortProbeSucceeded = nil
            self.lastAgentAbortProbeErrorText = nil
            self.lastAgentAbortProbeResponseText = nil
            return
        }
        guard let runID = self.lastAgentRunID else {
            self.lastAgentAbortProbeSucceeded = false
            self.lastAgentAbortProbeErrorText = "no active agent run id"
            self.lastAgentAbortProbeResponseText = nil
            self.appendLog("agent abort skipped: no known run id", level: .warning)
            return
        }
        guard let host = self.host else {
            self.lastAgentAbortProbeSucceeded = false
            self.lastAgentAbortProbeErrorText = "runtime host unavailable"
            self.lastAgentAbortProbeResponseText = nil
            self.appendLog("agent abort failed: runtime host unavailable", level: .error)
            return
        }

        self.appendLog("agent abort start runId=\(runID)")
        let request = GatewayRequestFrame(
            id: UUID().uuidString,
            method: "agents.abort",
            params: .object(["runId": .string(runID)]))
        do {
            let response = try await host.invoke(request)
            self.lastAgentAbortProbeSucceeded = response.ok
            self.lastAgentAbortProbeErrorText = response.error?.message
            if response.ok {
                self.lastAgentAbortProbeResponseText = Self.formatAgentSnapshot(from: response.payload)
                self.lastAgentRunID = nil
                self.appendLog("agent abort ok runId=\(runID)")
                if let snapshot = self.lastAgentAbortProbeResponseText, !snapshot.isEmpty {
                    self.appendLog("agent abort snapshot: \(snapshot)")
                }
            } else {
                let codeText = response.error?.code ?? "UNKNOWN"
                let message = response.error?.message ?? "unknown error"
                let lowerMessage = message.lowercased()
                if codeText == "METHOD_NOT_FOUND",
                   lowerMessage.contains("agent run not found")
                   || lowerMessage.contains("already finished")
                {
                    self.lastAgentAbortProbeSucceeded = true
                    self.lastAgentAbortProbeErrorText = nil
                    self.lastAgentAbortProbeResponseText = nil
                    self.lastAgentRunID = nil
                    self.appendLog("agent abort no-op runId=\(runID) already finished or not found")
                } else {
                    self.lastAgentAbortProbeResponseText = nil
                    self.appendLog(
                        "agent abort failed code=\(codeText) message=\(message)",
                        level: .warning)
                }
            }
        } catch {
            self.lastAgentAbortProbeSucceeded = false
            self.lastAgentAbortProbeErrorText = error.localizedDescription
            self.lastAgentAbortProbeResponseText = nil
            self.appendLog("agent abort threw: \(error.localizedDescription)", level: .error)
        }
    }

    func probeUpstreamHealth() async {
        guard self.state == .running else {
            self.lastUpstreamProbeSucceeded = nil
            self.lastUpstreamProbeErrorText = nil
            return
        }
        guard let upstreamClient = self.upstreamClient else {
            self.lastUpstreamProbeSucceeded = nil
            self.lastUpstreamProbeErrorText = "not configured"
            self.appendLog("upstream probe skipped: not configured", level: .warning)
            return
        }

        do {
            let response = try await upstreamClient.probeHealth()
            self.lastUpstreamProbeSucceeded = response.ok
            self.lastUpstreamProbeErrorText = response.error?.message
            if response.ok {
                self.appendLog("upstream probe ok")
            } else {
                self.appendLog(
                    "upstream probe failed: \(response.error?.message ?? "unknown error")",
                    level: .warning)
            }
        } catch {
            self.lastUpstreamProbeSucceeded = false
            self.lastUpstreamProbeErrorText = error.localizedDescription
            self.appendLog("upstream probe threw: \(error.localizedDescription)", level: .error)
        }
    }

    func startWebSocketListenerIfNeeded() async {
        guard self.listenerState != .listening else { return }
        guard let webSocketServer = self.webSocketServer else {
            self.listenerState = .failed
            self.listenerErrorText = "websocket server unavailable"
            return
        }
        do {
            let boundPort = try await webSocketServer.start(port: self.webSocketListenPortPreference)
            self.listenerPort = boundPort
            self.listenerErrorText = nil
            self.listenerState = .listening
            self.webSocketRetryTask?.cancel()
            self.webSocketRetryTask = nil
            self.webSocketRetryAttempt = 0
            self.webSocketRetryDelaySeconds = nil
            let endpointSummary = Self.listenerEndpointSummary(
                port: boundPort,
                localAddresses: self.localIPv4Addresses,
                scheme: "ws")
            self.appendLog("websocket listener active on \(endpointSummary)")
        } catch {
            self.listenerPort = nil
            self.listenerErrorText = error.localizedDescription
            self.listenerState = .failed
            self.appendLog("websocket listener failed: \(error.localizedDescription)", level: .error)
            self.scheduleWebSocketRetry()
        }
    }

    func restartWebSocketListener() async {
        self.appendLog("websocket listener restart requested")
        await self.stopWebSocketListener()
        await self.startWebSocketListenerIfNeeded()
    }

    func stopWebSocketListener() async {
        self.webSocketRetryTask?.cancel()
        self.webSocketRetryTask = nil
        self.webSocketRetryAttempt = 0
        self.webSocketRetryDelaySeconds = nil
        await self.webSocketServer?.stop()
        self.listenerPort = nil
        self.listenerState = .stopped
        self.listenerErrorText = nil
        self.lastWebSocketProbeSucceeded = nil
        self.lastWebSocketProbeErrorText = nil
        self.appendLog("websocket listener stopped")
    }

    func probeHealthOverWebSocket() async {
        guard self.state == .running, let listenerPort = self.listenerPort else {
            self.lastWebSocketProbeSucceeded = nil
            self.lastWebSocketProbeErrorText = nil
            return
        }

        do {
            let response = try await Self.sendHealthProbeOverWebSocket(
                port: listenerPort,
                authConfig: self.gatewayAuthConfig)
            self.lastWebSocketProbeSucceeded = response.ok
            self.lastWebSocketProbeErrorText = response.error?.message
            if response.ok {
                self.appendLog("websocket probe ok")
            } else {
                self.appendLog(
                    "websocket probe failed: \(response.error?.message ?? "unknown error")",
                    level: .warning)
            }
        } catch {
            self.lastWebSocketProbeSucceeded = false
            self.lastWebSocketProbeErrorText = error.localizedDescription
            self.appendLog("websocket probe threw: \(error.localizedDescription)", level: .error)
        }
    }

    func startTCPListenerIfNeeded() async {
        guard self.exposeTCPListener else { return }
        guard self.tcpListenerState != .listening else { return }
        guard let tcpServer = self.tcpServer else {
            self.tcpListenerState = .failed
            self.tcpListenerErrorText = "tcp debug server unavailable"
            return
        }

        if let existingPort = await tcpServer.currentPort() {
            self.tcpListenerPort = existingPort
            self.tcpListenerErrorText = nil
            self.tcpListenerState = .listening
            self.tcpRetryTask?.cancel()
            self.tcpRetryTask = nil
            self.tcpRetryAttempt = 0
            self.tcpRetryDelaySeconds = nil
            let endpointSummary = Self.listenerEndpointSummary(
                port: existingPort,
                localAddresses: self.localIPv4Addresses,
                scheme: "tcp")
            self.appendLog("tcp debug listener already bound on \(endpointSummary), marking active")
            return
        }

        await self.startTCPListenerOnPort(self.tcpListenPortPreference, allowFallbackToEphemeral: true)
    }

    private func startTCPListenerOnPort(
        _ port: UInt16,
        allowFallbackToEphemeral: Bool
    ) async {
        guard let tcpServer = self.tcpServer else { return }

        do {
            let boundPort = try await tcpServer.start(port: port)
            self.tcpListenerPort = boundPort
            self.tcpListenerErrorText = nil
            self.tcpListenerState = .listening
            self.tcpRetryTask?.cancel()
            self.tcpRetryTask = nil
            self.tcpRetryAttempt = 0
            self.tcpRetryDelaySeconds = nil
            let endpointSummary = Self.listenerEndpointSummary(
                port: boundPort,
                localAddresses: self.localIPv4Addresses,
                scheme: "tcp")
            self.appendLog("tcp debug listener active on \(endpointSummary)")
            return
        } catch {
            if let tcpError = error as? GatewayTCPJSONServerError, tcpError == .alreadyRunning {
                if let existingPort = await tcpServer.currentPort() {
                    self.tcpListenerPort = existingPort
                    self.tcpListenerState = .listening
                    self.tcpListenerErrorText = nil
                    self.tcpRetryTask?.cancel()
                    self.tcpRetryTask = nil
                    self.tcpRetryAttempt = 0
                    self.tcpRetryDelaySeconds = nil
                    let endpointSummary = Self.listenerEndpointSummary(
                        port: existingPort,
                        localAddresses: self.localIPv4Addresses,
                        scheme: "tcp")
                    self.appendLog("tcp debug listener already running on \(endpointSummary), marking active")
                    return
                }

                self.appendLog(
                    "tcp debug listener already running without bound port, forcing rebind",
                    level: .warning)
                await tcpServer.stop()
                self.tcpListenerState = .stopped
                self.tcpListenerPort = nil
                self.scheduleTCPRetry(after: 1)
                return
            }

            if allowFallbackToEphemeral,
               Self.isTCPAddressInUseError(error),
               port != 0
            {
                self.appendLog(
                    "tcp debug listener port \(port) unavailable, retrying ephemeral port",
                    level: .warning)
                await self.startTCPListenerOnPort(0, allowFallbackToEphemeral: false)
                if self.tcpListenerState == .listening {
                    return
                }
                if self.tcpListenerState == .failed {
                    return
                }
            }

            self.tcpListenerPort = nil
            self.tcpListenerErrorText = error.localizedDescription
            self.tcpListenerState = .failed
            self.appendLog("tcp debug listener failed: \(error.localizedDescription)", level: .error)
            self.scheduleTCPRetry()
            return
        }
    }

    func restartTCPListener() async {
        guard self.exposeTCPListener else { return }
        self.appendLog("tcp debug listener restart requested")
        await self.stopTCPListener()
        await self.startTCPListenerIfNeeded()
    }

    func stopTCPListener() async {
        self.tcpRetryTask?.cancel()
        self.tcpRetryTask = nil
        self.tcpRetryAttempt = 0
        self.tcpRetryDelaySeconds = nil
        await self.tcpServer?.stop()
        self.tcpListenerPort = nil
        self.tcpListenerState = .stopped
        self.tcpListenerErrorText = nil
        self.lastTCPProbeSucceeded = nil
        self.lastTCPProbeErrorText = nil
        self.appendLog("tcp debug listener stopped")
    }

    func probeHealthOverTCP() async {
        guard self.state == .running, let listenerPort = self.tcpListenerPort else {
            self.lastTCPProbeSucceeded = nil
            self.lastTCPProbeErrorText = nil
            return
        }

        do {
            let response = try await Self.sendHealthProbeOverTCP(
                port: listenerPort,
                authConfig: self.gatewayAuthConfig)
            self.lastTCPProbeSucceeded = response.ok
            self.lastTCPProbeErrorText = response.error?.message
            if response.ok {
                self.appendLog("tcp probe ok")
            } else {
                self.appendLog(
                    "tcp probe failed: \(response.error?.message ?? "unknown error")",
                    level: .warning)
            }
        } catch {
            self.lastTCPProbeSucceeded = false
            self.lastTCPProbeErrorText = error.localizedDescription
            self.appendLog("tcp probe threw: \(error.localizedDescription)", level: .error)
        }
    }

    private func scheduleWebSocketRetry() {
        guard self.state == .running else { return }
        guard self.webSocketRetryTask == nil else { return }
        self.webSocketRetryAttempt += 1
        let exponentialDelay = 1 << min(self.webSocketRetryAttempt - 1, 5)
        let delaySeconds = min(30, max(1, exponentialDelay))
        self.webSocketRetryDelaySeconds = delaySeconds
        self.appendLog(
            "websocket retry in \(delaySeconds)s (attempt \(self.webSocketRetryAttempt))",
            level: .warning)

        self.webSocketRetryTask = Task {
            try? await Task.sleep(nanoseconds: UInt64(delaySeconds) * 1_000_000_000)
            guard !Task.isCancelled else { return }
            self.webSocketRetryTask = nil
            self.webSocketRetryDelaySeconds = nil
            await self.startWebSocketListenerIfNeeded()
        }
    }

    private func scheduleTCPRetry() {
        self.scheduleTCPRetry(after: nil)
    }

    private func scheduleTCPRetry(after overrideDelay: Int?) {
        guard self.state == .running else { return }
        guard self.tcpRetryTask == nil else { return }
        self.tcpRetryAttempt += 1
        let delaySeconds: Int
        if let overrideDelay {
            delaySeconds = max(1, min(20, overrideDelay))
        } else {
            let exponentialDelay = 1 << min(self.tcpRetryAttempt - 1, 4)
            delaySeconds = min(20, max(1, exponentialDelay))
        }
        self.tcpRetryDelaySeconds = delaySeconds
        self.appendLog(
            "tcp debug retry in \(delaySeconds)s (attempt \(self.tcpRetryAttempt))",
            level: .warning)

        self.tcpRetryTask = Task {
            try? await Task.sleep(nanoseconds: UInt64(delaySeconds) * 1_000_000_000)
            guard !Task.isCancelled else { return }
            self.tcpRetryTask = nil
            self.tcpRetryDelaySeconds = nil
            await self.startTCPListenerIfNeeded()
        }
    }

    private func rebuildGatewayStack() {
        self.webSocketRetryTask?.cancel()
        self.webSocketRetryTask = nil
        self.webSocketRetryAttempt = 0
        self.webSocketRetryDelaySeconds = nil
        self.tcpRetryTask?.cancel()
        self.tcpRetryTask = nil
        self.tcpRetryAttempt = 0
        self.tcpRetryDelaySeconds = nil

        self.gatewayAuthConfig = Self.makeAuthConfig(from: self.controlPlaneSettings)
        self.listenerAuthMode = self.gatewayAuthConfig.mode
        self.listenerAuthHint = Self.authHint(for: self.gatewayAuthConfig)

        let upstreamLoad = Self.makeUpstreamConfig(from: self.controlPlaneSettings)
        self.upstreamConfigured = upstreamLoad.config != nil
        self.upstreamURLText = upstreamLoad.urlText
        self.upstreamConfigErrorText = upstreamLoad.errorText
        self.upstreamClient = upstreamLoad.config.map { GatewayUpstreamWebSocketClient(config: $0) }

        let localLLMConfig = Self.makeLocalLLMConfig(from: self.controlPlaneSettings)
        self.localLLMConfigured = localLLMConfig.isConfigured
        self.localLLMProviderLabel = Self.localLLMProviderDisplayName(localLLMConfig.provider)
        self.localLLMConfigErrorText = nil
        if localLLMConfig.provider != .disabled, !localLLMConfig.isConfigured {
            self.localLLMConfigErrorText = "provider selected but local LLM config is incomplete"
        }
        let bootstrapWorkspacePath = Self.defaultBootstrapWorkspacePath()
        if bootstrapWorkspacePath.isEmpty {
            self.appendLog("bootstrap workspace unavailable; auto-install skipped", level: .warning)
        } else {
            do {
                let seedResult = try TVOSBootstrapWorkspaceSeeder.ensureSeeded(
                    workspacePath: bootstrapWorkspacePath)
                if seedResult.createdCount > 0 {
                    self.appendLog(
                        "bootstrap install created \(seedResult.createdCount) file(s): "
                            + seedResult.createdFiles.joined(separator: ", "))
                }
                if !seedResult.failedFiles.isEmpty {
                    let failures = seedResult.failedFiles
                        .sorted(by: { $0.key < $1.key })
                        .map { "\($0.key)=\($0.value)" }
                        .joined(separator: "; ")
                    self.appendLog(
                        "bootstrap install write failures: \(failures)",
                        level: .error)
                }
                if !seedResult.missingTemplateFiles.isEmpty {
                    self.appendLog(
                        "bootstrap install missing templates: "
                            + seedResult.missingTemplateFiles.joined(separator: ", "),
                        level: .warning)
                }
                if let status = seedResult.status {
                    if status.bootstrapPending {
                        self.appendLog(
                            "bootstrap onboarding pending"
                                + (status.bootstrapSeededAt.map { " (seeded=\($0))" } ?? ""))
                    } else {
                        self.appendLog(
                            "bootstrap onboarding completed"
                                + (status.onboardingCompletedAt.map { " (\($0))" } ?? ""))
                    }
                }
            } catch {
                self.appendLog("bootstrap install failed: \(error.localizedDescription)", level: .error)
            }
        }

        let bootstrapConfig = GatewayBootstrapConfig(
            enabled: true,
            workspacePath: bootstrapWorkspacePath,
            fileNames: Self.bootstrapInjectionFileNames(workspacePath: bootstrapWorkspacePath),
            perFileMaxChars: GatewayBootstrapConfig.default.perFileMaxChars,
            totalMaxChars: GatewayBootstrapConfig.default.totalMaxChars,
            includeMissingMarkers: false)

        let resolvedTransport: GatewayLoopbackTransport
        if let transportOverride = self.transportOverride {
            resolvedTransport = transportOverride
        } else {
            var localRouter: GatewayLocalMethodRouter?
            let adminBridge = TVOSRuntimeAdminBridge(runtime: self)
            let primaryMemoryStorePath = Self.defaultMemoryStorePath()
            self.appendLog("local memory store path: \(primaryMemoryStorePath.path)")
            do {
                localRouter = try GatewayLocalMethodRouter(
                    config: GatewayLocalMethodRouterConfig(
                        hostLabel: "tvos-local",
                        upstreamConfigured: self.upstreamConfigured,
                        upstreamForwarder: self.upstreamClient,
                        llmConfig: localLLMConfig,
                        memoryStorePath: primaryMemoryStorePath,
                        bootstrapConfig: bootstrapConfig,
                        enableLocalSafeTools: true,
                        enableLocalFileTools: true,
                        enableAutoProfileRewrite: false,
                        adminBridge: adminBridge))
            } catch {
                let firstErrorText = "local router init failed: \(error.localizedDescription)"
                self.localLLMConfigErrorText = firstErrorText
                self.appendLog("local method router init failed: \(error.localizedDescription)", level: .error)

                let fallbackMemoryStorePath = Self.fallbackMemoryStorePath()
                if fallbackMemoryStorePath.path != primaryMemoryStorePath.path {
                    self.appendLog(
                        "retrying local router with fallback memory path: \(fallbackMemoryStorePath.path)",
                        level: .warning)
                    do {
                        localRouter = try GatewayLocalMethodRouter(
                            config: GatewayLocalMethodRouterConfig(
                                hostLabel: "tvos-local",
                                upstreamConfigured: self.upstreamConfigured,
                                upstreamForwarder: self.upstreamClient,
                                llmConfig: localLLMConfig,
                                memoryStorePath: fallbackMemoryStorePath,
                                bootstrapConfig: bootstrapConfig,
                                enableLocalSafeTools: true,
                                enableLocalFileTools: true,
                                enableAutoProfileRewrite: false,
                                adminBridge: adminBridge))
                        self.localLLMConfigErrorText = nil
                        self.appendLog(
                            "local router recovered with fallback memory path",
                            level: .warning)
                    } catch {
                        self.localLLMConfigErrorText = firstErrorText
                        self.appendLog(
                            "local method router fallback init failed: \(error.localizedDescription)",
                            level: .error)
                    }
                }
            }
            resolvedTransport = GatewayLoopbackTransport(
                core: GatewayCore(authConfig: self.gatewayAuthConfig),
                upstream: self.upstreamClient,
                localMethods: localRouter)
        }

        self.host = GatewayLoopbackHost(transport: resolvedTransport)
        self.webSocketServer = GatewayWebSocketServer(transport: resolvedTransport)
        self.tcpServer = GatewayTCPJSONServer(
            transport: resolvedTransport,
            authConfig: self.gatewayAuthConfig)
    }

    fileprivate func adminConfigSnapshot(nowMs: Int64) -> GatewayJSONValue {
        let settingsPayload = self.adminSettingsPayload(self.controlPlaneSettings)
        var payload = settingsPayload
        payload["settings"] = .object(settingsPayload)
        payload["state"] = self.adminRuntimeStatePayload(nowMs: nowMs)
        payload["bootstrap"] = self.adminBootstrapPayload()
        payload["skills"] = self.adminSkillsPayload()
        payload["config"] = .object([
            "gatewayTVOS": .object(settingsPayload),
            "session": .object([
                "mainKey": .string("main"),
                "scope": .string("local"),
            ]),
        ])
        payload["ts"] = .integer(nowMs)
        return .object(payload)
    }

    fileprivate func adminConfigSet(params: GatewayJSONValue, nowMs: Int64) async throws -> GatewayJSONValue {
        let nextSettings = try self.adminSettingsFromParams(params)
        let wasRunning = self.state == .running
        await self.applyControlPlaneSettings(nextSettings)
        let settingsPayload = self.adminSettingsPayload(self.controlPlaneSettings)
        self.appendLog("admin config.set applied via RPC")
        return .object([
            "applied": .bool(true),
            "settings": .object(settingsPayload),
            "state": self.adminRuntimeStatePayload(nowMs: nowMs),
            "bootstrap": self.adminBootstrapPayload(),
            "skills": self.adminSkillsPayload(),
            "wasRunning": .bool(wasRunning),
            "ts": .integer(nowMs),
        ])
    }

    fileprivate func adminRuntimeRestart(nowMs: Int64) async -> GatewayJSONValue {
        let wasRunning = self.state == .running
        await self.restart(with: self.controlPlaneSettings)
        self.appendLog("admin runtime.restart applied via RPC")
        return .object([
            "restarted": .bool(true),
            "state": self.adminRuntimeStatePayload(nowMs: nowMs),
            "bootstrap": self.adminBootstrapPayload(),
            "skills": self.adminSkillsPayload(),
            "wasRunning": .bool(wasRunning),
            "ts": .integer(nowMs),
        ])
    }

    private func adminSettingsFromParams(_ params: GatewayJSONValue) throws -> TVOSGatewayControlPlaneSettings {
        guard let root = params.objectValue else {
            throw TVOSRuntimeAdminBridgeError.invalidRequest("config.set params must be an object")
        }

        var source = root
        if let settings = root["settings"]?.objectValue {
            source = settings
        } else if let configObject = root["config"]?.objectValue {
            if let tvosSettings = configObject["gatewayTVOS"]?.objectValue {
                source = tvosSettings
            } else if let tvosSettings = configObject["tvos"]?.objectValue {
                source = tvosSettings
            } else {
                source = configObject
            }
        }

        var next = self.controlPlaneSettings
        let authObject = Self.firstObject(in: source, keys: ["auth", "listenerAuth"])
        let upstreamObject = Self.firstObject(in: source, keys: ["upstream", "gateway"])
        let localLLMObject = Self.firstObject(in: source, keys: ["localLLM", "localLlm", "llm"])

        let authModeRaw =
            Self.firstString(in: source, keys: ["authMode", "auth_mode"])
            ?? authObject?["mode"]?.stringValue
        if let authModeRaw {
            guard let mode = Self.parseAuthMode(authModeRaw) else {
                throw TVOSRuntimeAdminBridgeError.invalidRequest("invalid authMode: \(authModeRaw)")
            }
            next.authMode = mode
        }

        if let authToken =
            Self.firstString(in: source, keys: ["authToken", "auth_token"])
            ?? authObject?["token"]?.stringValue
        {
            next.authToken = authToken
        }

        if let authPassword =
            Self.firstString(in: source, keys: ["authPassword", "auth_password"])
            ?? authObject?["password"]?.stringValue
        {
            next.authPassword = authPassword
        }

        if let upstreamURL =
            Self.firstString(in: source, keys: ["upstreamURL", "upstreamUrl", "url"])
            ?? upstreamObject?["url"]?.stringValue
        {
            next.upstreamURL = upstreamURL
        }

        if let upstreamToken =
            Self.firstString(in: source, keys: ["upstreamToken", "upstream_token"])
            ?? upstreamObject?["token"]?.stringValue
        {
            next.upstreamToken = upstreamToken
        }

        if let upstreamPassword =
            Self.firstString(in: source, keys: ["upstreamPassword", "upstream_password"])
            ?? upstreamObject?["password"]?.stringValue
        {
            next.upstreamPassword = upstreamPassword
        }

        if let upstreamRole =
            Self.firstString(in: source, keys: ["upstreamRole", "upstream_role"])
            ?? upstreamObject?["role"]?.stringValue
        {
            next.upstreamRole = upstreamRole
        }

        if let upstreamScopes =
            Self.firstString(in: source, keys: ["upstreamScopesCSV", "upstreamScopes", "scopes"])
            ?? upstreamObject?["scopes"]?.stringValue
        {
            next.upstreamScopesCSV = upstreamScopes
        }

        let providerRaw =
            Self.firstString(in: source, keys: ["localLLMProvider", "localLlmProvider", "llmProvider"])
            ?? localLLMObject?["provider"]?.stringValue
        if let providerRaw {
            guard let provider = Self.parseLocalLLMProvider(providerRaw) else {
                throw TVOSRuntimeAdminBridgeError.invalidRequest(
                    "invalid localLLMProvider: \(providerRaw)")
            }
            next.localLLMProvider = provider
        }

        if let baseURL =
            Self.firstString(in: source, keys: ["localLLMBaseURL", "localLlmBaseURL", "llmBaseURL", "baseURL"])
            ?? localLLMObject?["baseURL"]?.stringValue
        {
            next.localLLMBaseURL = baseURL
        }

        if let apiKey =
            Self.firstString(in: source, keys: ["localLLMAPIKey", "localLlmApiKey", "llmAPIKey", "apiKey"])
            ?? localLLMObject?["apiKey"]?.stringValue
        {
            next.localLLMAPIKey = apiKey
        }

        if let model =
            Self.firstString(in: source, keys: ["localLLMModel", "localLlmModel", "llmModel", "model"])
            ?? localLLMObject?["model"]?.stringValue
        {
            next.localLLMModel = model
        }

        return Self.normalizedSettings(next)
    }

    private func adminSettingsPayload(_ settings: TVOSGatewayControlPlaneSettings) -> [String: GatewayJSONValue] {
        [
            "authMode": .string(settings.authMode.rawValue),
            "authToken": .string(settings.authToken),
            "authPassword": .string(settings.authPassword),
            "upstreamURL": .string(settings.upstreamURL),
            "upstreamToken": .string(settings.upstreamToken),
            "upstreamPassword": .string(settings.upstreamPassword),
            "upstreamRole": .string(settings.upstreamRole),
            "upstreamScopesCSV": .string(settings.upstreamScopesCSV),
            "localLLMProvider": .string(settings.localLLMProvider.rawValue),
            "localLLMBaseURL": .string(settings.localLLMBaseURL),
            "localLLMAPIKey": .string(settings.localLLMAPIKey),
            "localLLMModel": .string(settings.localLLMModel),
        ]
    }

    private func adminRuntimeStatePayload(nowMs: Int64) -> GatewayJSONValue {
        .object([
            "runtime": .string(self.state.rawValue),
            "webSocket": .string(self.listenerState.rawValue),
            "webSocketPort": self.listenerPort.map { .integer(Int64($0)) } ?? .null,
            "tcpDebug": .string(self.tcpListenerState.rawValue),
            "tcpDebugPort": self.tcpListenerPort.map { .integer(Int64($0)) } ?? .null,
            "upstreamConfigured": .bool(self.upstreamConfigured),
            "localLLMConfigured": .bool(self.localLLMConfigured),
            "ts": .integer(nowMs),
        ])
    }

    private func adminBootstrapPayload() -> GatewayJSONValue {
        let workspacePath = Self.defaultBootstrapWorkspacePath()
        guard !workspacePath.isEmpty else {
            return .object([
                "enabled": .bool(false),
                "workspacePath": .null,
                "bootstrapPending": .bool(true),
                "files": .array([]),
            ])
        }

        let workspaceURL = URL(fileURLWithPath: workspacePath, isDirectory: true)
        let fileManager = FileManager.default
        let status = TVOSBootstrapWorkspaceSeeder.loadStatus(workspacePath: workspacePath)
        let maxChars = max(256, GatewayBootstrapConfig.default.perFileMaxChars)
        let bootstrapFileNames = Self.bootstrapInjectionFileNames(workspacePath: workspacePath)
        var fileEntries: [GatewayJSONValue] = []
        var existingCount = 0

        for filename in bootstrapFileNames {
            let fileURL = workspaceURL.appendingPathComponent(filename, isDirectory: false)
            var isDirectory: ObjCBool = false
            let exists = fileManager.fileExists(atPath: fileURL.path, isDirectory: &isDirectory) && !isDirectory.boolValue
            if exists {
                existingCount += 1
            }

            var entry: [String: GatewayJSONValue] = [
                "name": .string(filename),
                "path": .string(fileURL.path),
                "exists": .bool(exists),
            ]

            if exists, let data = try? Data(contentsOf: fileURL) {
                entry["bytes"] = .integer(Int64(data.count))
                if let text = String(data: data, encoding: .utf8) {
                    let preview = Self.clampAdminPreview(text, maxChars: maxChars)
                    entry["content"] = .string(preview.text)
                    entry["truncated"] = .bool(preview.truncated)
                } else {
                    entry["content"] = .string("(binary or non-utf8 content)")
                    entry["truncated"] = .bool(false)
                }
            } else {
                entry["bytes"] = .integer(0)
                entry["content"] = .string("")
                entry["truncated"] = .bool(false)
            }

            fileEntries.append(.object(entry))
        }

        return .object([
            "enabled": .bool(true),
            "workspacePath": .string(workspacePath),
            "statePath": status.map { .string($0.statePath) } ?? .null,
            "bootstrapSeededAt": status?.bootstrapSeededAt.map { .string($0) } ?? .null,
            "onboardingCompletedAt": status?.onboardingCompletedAt.map { .string($0) } ?? .null,
            "bootstrapPending": .bool(status?.bootstrapPending ?? true),
            "bootstrapExists": .bool(status?.bootstrapExists ?? false),
            "expectedFiles": .integer(Int64(bootstrapFileNames.count)),
            "existingFiles": .integer(Int64(existingCount)),
            "files": .array(fileEntries),
        ])
    }

    private func adminSkillsPayload() -> GatewayJSONValue {
        let workspacePath = Self.defaultBootstrapWorkspacePath()
        guard !workspacePath.isEmpty else {
            return .object([
                "enabled": .bool(false),
                "workspacePath": .null,
                "skillsRootPath": .null,
                "skillsRootExists": .bool(false),
                "files": .array([]),
            ])
        }

        let workspaceURL = URL(fileURLWithPath: workspacePath, isDirectory: true)
        let skillsRootURL = workspaceURL.appendingPathComponent("skills", isDirectory: true)
        let fileManager = FileManager.default
        let maxChars = max(256, GatewayBootstrapConfig.default.perFileMaxChars)
        var rootIsDirectory: ObjCBool = false
        let skillsRootExists = fileManager.fileExists(atPath: skillsRootURL.path, isDirectory: &rootIsDirectory)
            && rootIsDirectory.boolValue

        guard skillsRootExists else {
            return .object([
                "enabled": .bool(true),
                "workspacePath": .string(workspacePath),
                "skillsRootPath": .string(skillsRootURL.path),
                "skillsRootExists": .bool(false),
                "fileCount": .integer(0),
                "files": .array([]),
            ])
        }

        let skillFileURLs = Self.collectSkillFileURLs(rootURL: skillsRootURL, fileManager: fileManager)
        var fileEntries: [GatewayJSONValue] = []
        fileEntries.reserveCapacity(skillFileURLs.count)

        for fileURL in skillFileURLs {
            let relativePath = Self.relativeAdminPath(fileURL: fileURL, rootURL: workspaceURL)
            var entry: [String: GatewayJSONValue] = [
                "name": .string(relativePath),
                "path": .string(fileURL.path),
                "exists": .bool(true),
            ]
            if let data = try? Data(contentsOf: fileURL) {
                entry["bytes"] = .integer(Int64(data.count))
                if let text = String(data: data, encoding: .utf8) {
                    let preview = Self.clampAdminPreview(text, maxChars: maxChars)
                    entry["content"] = .string(preview.text)
                    entry["truncated"] = .bool(preview.truncated)
                } else {
                    entry["content"] = .string("(binary or non-utf8 content)")
                    entry["truncated"] = .bool(false)
                }
            } else {
                entry["bytes"] = .integer(0)
                entry["content"] = .string("(unreadable)")
                entry["truncated"] = .bool(false)
            }
            fileEntries.append(.object(entry))
        }

        return .object([
            "enabled": .bool(true),
            "workspacePath": .string(workspacePath),
            "skillsRootPath": .string(skillsRootURL.path),
            "skillsRootExists": .bool(true),
            "fileCount": .integer(Int64(fileEntries.count)),
            "files": .array(fileEntries),
        ])
    }

    private static func collectSkillFileURLs(rootURL: URL, fileManager: FileManager) -> [URL] {
        guard let enumerator = fileManager.enumerator(
            at: rootURL,
            includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants])
        else {
            return []
        }

        var results: [URL] = []
        for case let fileURL as URL in enumerator {
            let resourceValues = try? fileURL.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey])
            if resourceValues?.isDirectory == true {
                continue
            }
            guard resourceValues?.isRegularFile == true else {
                continue
            }

            let filename = fileURL.lastPathComponent.lowercased()
            if filename == "skill.md" || filename.hasSuffix(".md") {
                results.append(fileURL)
            }
        }

        results.sort { $0.path.localizedCaseInsensitiveCompare($1.path) == .orderedAscending }
        return results
    }

    private static func relativeAdminPath(fileURL: URL, rootURL: URL) -> String {
        let rootPath = rootURL.path.hasSuffix("/") ? rootURL.path : rootURL.path + "/"
        let fullPath = fileURL.path
        if fullPath.hasPrefix(rootPath) {
            return String(fullPath.dropFirst(rootPath.count))
        }
        return fileURL.lastPathComponent
    }

    private static func bootstrapInjectionFileNames(workspacePath: String) -> [String] {
        var ordered = GatewayBootstrapConfig.default.fileNames
        let trimmedWorkspacePath = workspacePath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedWorkspacePath.isEmpty else {
            return ordered
        }

        let fileManager = FileManager.default
        let workspaceURL = URL(fileURLWithPath: trimmedWorkspacePath, isDirectory: true)
        let skillsRootURL = workspaceURL.appendingPathComponent("skills", isDirectory: true)
        let skillURLs = Self.collectSkillFileURLs(rootURL: skillsRootURL, fileManager: fileManager)

        for fileURL in skillURLs {
            let relativePath = Self.relativeAdminPath(fileURL: fileURL, rootURL: workspaceURL)
            if !ordered.contains(relativePath) {
                ordered.append(relativePath)
            }
        }
        return ordered
    }

    private static func clampAdminPreview(_ raw: String, maxChars: Int) -> (text: String, truncated: Bool) {
        let normalized = raw.replacingOccurrences(of: "\r\n", with: "\n")
        guard maxChars > 0 else {
            return ("", !normalized.isEmpty)
        }
        if normalized.count <= maxChars {
            return (normalized, false)
        }
        let prefix = String(normalized.prefix(max(0, maxChars - 1)))
        return (prefix + "…", true)
    }

    private static func firstString(
        in object: [String: GatewayJSONValue],
        keys: [String]) -> String?
    {
        for key in keys {
            guard let value = object[key] else { continue }
            if let text = value.stringValue {
                return text
            }
            if case .null = value {
                return ""
            }
        }
        return nil
    }

    private static func firstObject(
        in object: [String: GatewayJSONValue],
        keys: [String]) -> [String: GatewayJSONValue]?
    {
        for key in keys {
            if let nested = object[key]?.objectValue {
                return nested
            }
        }
        return nil
    }

    private static func parseAuthMode(_ raw: String) -> GatewayCoreAuthMode? {
        let normalized = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch normalized {
        case "none", "off", "disabled":
            return .none
        case "token":
            return .token
        case "password", "pass":
            return .password
        default:
            return nil
        }
    }

    private static func parseLocalLLMProvider(_ raw: String) -> GatewayLocalLLMProviderKind? {
        let normalized = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch normalized {
        case "disabled", "none", "off":
                return .disabled
        case "openai", "openai-compatible", "openai_compatible":
            return .openAICompatible
        case "anthropic", "anthropic-compatible", "anthropic_compatible":
            return .anthropicCompatible
        case "minimax", "minimax-compatible", "minimax_compatible":
            return .minimaxCompatible
        default:
            return GatewayLocalLLMProviderKind(rawValue: normalized)
        }
    }

    private static func normalizedSessionKey(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? Self.defaultChatSessionKey : trimmed
    }

    private static func extractChatRunID(from payload: GatewayJSONValue?) -> String? {
        payload?.objectValue?["runId"]?.stringValue
    }

    private static func decodeChatTurns(from payload: GatewayJSONValue?) -> [TVOSGatewayChatTurn] {
        guard let payloadObject = payload?.objectValue,
              let messagesValue = payloadObject["messages"],
              case let .array(messages) = messagesValue
        else {
            return []
        }

        var turns: [TVOSGatewayChatTurn] = []
        turns.reserveCapacity(messages.count)

        for (index, message) in messages.enumerated() {
            guard let messageObject = message.objectValue else { continue }

            let role = messageObject["role"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
            let normalizedRole = (role?.isEmpty == false) ? role! : "assistant"
            let text = Self.chatText(from: messageObject["content"])
            if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                continue
            }

            let timestampMs: Int64? = {
                guard let raw = messageObject["timestamp"] else { return nil }
                switch raw {
                case let .integer(value):
                    return value
                case let .double(value):
                    guard value.isFinite else { return nil }
                    return Int64(value.rounded())
                default:
                    return nil
                }
            }()
            let timestamp = timestampMs.map { Date(timeIntervalSince1970: TimeInterval($0) / 1_000.0) }
            let runID = messageObject["runId"]?.stringValue
            let uniqueID = [
                String(timestampMs ?? Int64(index)),
                String(index),
                normalizedRole,
                runID ?? "",
                String(text.hashValue),
            ].joined(separator: "|")

            turns.append(
                TVOSGatewayChatTurn(
                    id: uniqueID,
                    role: normalizedRole,
                    text: text,
                    timestamp: timestamp,
                    runID: runID))
        }
        return turns
    }

    private static func chatText(from content: GatewayJSONValue?) -> String {
        guard let content else { return "" }
        if let text = content.stringValue {
            return text
        }
        guard case let .array(items) = content else {
            return ""
        }

        var chunks: [String] = []
        chunks.reserveCapacity(items.count)
        for item in items {
            guard let itemObject = item.objectValue else { continue }
            let type = itemObject["type"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if type == nil || type == "text",
               let text = itemObject["text"]?.stringValue,
               !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            {
                chunks.append(text)
            }
        }
        return chunks.joined(separator: "\n")
    }

    private static func latestAssistantReplyText(from payload: GatewayJSONValue?) -> String? {
        guard let payloadObject = payload?.objectValue,
              let messagesValue = payloadObject["messages"],
              case let .array(messages) = messagesValue
        else {
            return nil
        }

        for message in messages.reversed() {
            guard let messageObject = message.objectValue,
                  messageObject["role"]?.stringValue == "assistant",
                  let contentValue = messageObject["content"],
                  case let .array(contentItems) = contentValue
            else {
                continue
            }

            var textChunks: [String] = []
            for item in contentItems {
                guard let itemObject = item.objectValue else { continue }
                if itemObject["type"]?.stringValue == "text",
                   let text = itemObject["text"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !text.isEmpty
                {
                    textChunks.append(text)
                }
            }

            if !textChunks.isEmpty {
                return textChunks.joined(separator: " ")
            }
        }
        return nil
    }

    static func localLLMProviderDisplayName(_ provider: GatewayLocalLLMProviderKind) -> String {
        switch provider {
        case .disabled:
            return "disabled"
        case .openAICompatible:
            return "openai-compatible"
        case .anthropicCompatible:
            return "anthropic-compatible"
        case .minimaxCompatible:
            return "minimax-compatible"
        }
    }

    static func defaultLocalLLMBaseURL(for provider: GatewayLocalLLMProviderKind) -> String? {
        switch provider {
        case .disabled:
            return nil
        case .openAICompatible:
            return "https://api.openai.com/v1"
        case .anthropicCompatible:
            return "https://api.anthropic.com/v1"
        case .minimaxCompatible:
            return "https://api.minimax.io/v1"
        }
    }

    static func defaultLocalLLMModel(for provider: GatewayLocalLLMProviderKind) -> String? {
        switch provider {
        case .disabled:
            return nil
        case .openAICompatible:
            return "gpt-4o-mini"
        case .anthropicCompatible:
            return "claude-3.5-sonnet"
        case .minimaxCompatible:
            return "MiniMax-M2.5"
        }
    }

    private static func extractAgentRunID(from payload: GatewayJSONValue?) -> String? {
        payload?.objectValue?["runId"]?.stringValue
    }

    private static func formatAgentSnapshot(from payload: GatewayJSONValue?) -> String {
        guard let payloadObject = payload?.objectValue else {
            return "no snapshot"
        }

        var parts: [String] = []
        if let runId = payloadObject["runId"]?.stringValue {
            parts.append("runId=\(runId)")
        }
        if let sessionKey = payloadObject["sessionKey"]?.stringValue {
            parts.append("session=\(sessionKey)")
        }
        if let status = payloadObject["status"]?.stringValue {
            parts.append("status=\(status)")
        }
        if let currentStep = payloadObject["currentStep"]?.stringValue {
            parts.append("currentStep=\(currentStep)")
        }
        if let totalSteps = payloadObject["totalSteps"]?.int64Value {
            parts.append("totalSteps=\(totalSteps)")
        }
        if let stepsCompleted = payloadObject["stepsCompleted"]?.int64Value {
            parts.append("stepsCompleted=\(stepsCompleted)")
        }
        if let output = payloadObject["output"]?.stringValue {
            parts.append("output=\(Self.compactText(output, max: 160))")
        }
        if let error = payloadObject["error"]?.stringValue {
            parts.append("error=\(Self.compactText(error, max: 160))")
        }
        return parts.isEmpty ? "empty snapshot" : parts.joined(separator: " | ")
    }

    private static func compactText(_ text: String, max: Int) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > max else { return trimmed }
        return String(trimmed.prefix(max - 1)) + "…"
    }

    private static func sendHealthProbeOverWebSocket(
        port: UInt16,
        authConfig: GatewayCoreAuthConfig) async throws -> GatewayResponseFrame
    {
        guard let url = URL(string: "ws://127.0.0.1:\(port)") else {
            throw URLError(.badURL)
        }

        let session = URLSession(configuration: .ephemeral)
        let task = session.webSocketTask(with: url)
        task.resume()
        defer {
            task.cancel(with: .goingAway, reason: nil)
            session.invalidateAndCancel()
        }

        let connectRequest = Self.makeConnectRequest(authConfig: authConfig)
        try await Self.sendWebSocketRequest(task: task, frame: connectRequest)

        let connectResponse = try await Self.waitForResponse(task: task, requestID: connectRequest.id)
        guard connectResponse.ok else {
            return connectResponse
        }

        let healthRequest = GatewayRequestFrame(id: UUID().uuidString, method: "health")
        try await Self.sendWebSocketRequest(task: task, frame: healthRequest)
        return try await Self.waitForResponse(task: task, requestID: healthRequest.id)
    }

    private static func sendWebSocketRequest(
        task: URLSessionWebSocketTask,
        frame: GatewayRequestFrame) async throws
    {
        let data = try JSONEncoder().encode(frame)
        try await task.send(.data(data))
    }

    private static func waitForResponse(
        task: URLSessionWebSocketTask,
        requestID: String) async throws -> GatewayResponseFrame
    {
        while true {
            let message = try await task.receive()
            guard let data = Self.webSocketMessageData(message) else { continue }

            if let response = try? JSONDecoder().decode(GatewayResponseFrame.self, from: data),
               response.type == "res"
            {
                if response.id == requestID {
                    return response
                }
                continue
            }

            // Ignore event frames while waiting for the matching response.
            if (try? JSONDecoder().decode(GatewayEventFrame.self, from: data)) != nil {
                continue
            }
        }
    }

    private static func webSocketMessageData(_ message: URLSessionWebSocketTask.Message) -> Data? {
        switch message {
        case let .data(data):
            return data
        case let .string(text):
            return text.data(using: .utf8)
        @unknown default:
            return nil
        }
    }

    private static func makeConnectRequest(authConfig: GatewayCoreAuthConfig) -> GatewayRequestFrame {
        var params: [String: GatewayJSONValue] = [
            "minProtocol": .integer(Int64(GatewayCore.defaultProtocolVersion)),
            "maxProtocol": .integer(Int64(GatewayCore.defaultProtocolVersion)),
            "client": .object([
                "id": .string("openclaw.tvos.gateway-probe"),
                "displayName": .string("OpenClawTV Probe"),
                "version": .string("0.0.0-dev"),
                "platform": .string("tvOS"),
                "mode": .string("gateway-host"),
            ]),
            "role": .string("operator"),
            "scopes": .array([.string("operator.admin")]),
        ]

        if let auth = Self.authPayload(for: authConfig) {
            var authObject: [String: GatewayJSONValue] = [:]
            if let token = auth.token {
                authObject["token"] = .string(token)
            }
            if let password = auth.password {
                authObject["password"] = .string(password)
            }
            params["auth"] = .object(authObject)
        }

        return GatewayRequestFrame(
            id: UUID().uuidString,
            method: "connect",
            params: .object(params))
    }

    private static func sendHealthProbeOverTCP(
        port: UInt16,
        authConfig: GatewayCoreAuthConfig) async throws -> GatewayResponseFrame
    {
        let connection = NWConnection(
            host: NWEndpoint.Host("127.0.0.1"),
            port: NWEndpoint.Port(rawValue: port) ?? .any,
            using: .tcp)
        let queue = DispatchQueue(label: "ai.openclaw.tvos.gateway-probe.tcp.\(UUID().uuidString)")
        connection.start(queue: queue)

        let request = GatewayRequestFrame(id: UUID().uuidString, method: "health")
        let envelope = GatewayTCPRequestEnvelope(
            request: request,
            auth: Self.authPayload(for: authConfig))
        var requestData = try JSONEncoder().encode(envelope)
        requestData.append(0x0A)

        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: requestData, completion: .contentProcessed { error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                continuation.resume()
            })
        }

        let responseData = try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Data, Error>) in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 1_048_576) {
                data,
                _,
                _,
                error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                continuation.resume(returning: data ?? Data())
            }
        }
        connection.cancel()

        let line = responseData.split(
            separator: 0x0A,
            maxSplits: 1,
            omittingEmptySubsequences: true).first
        let frameData = Data(line ?? responseData[...])
        return try JSONDecoder().decode(GatewayResponseFrame.self, from: frameData)
    }

    private static func authPayload(for config: GatewayCoreAuthConfig) -> GatewayConnectAuth? {
        switch config.mode {
        case .none:
            return nil
        case .token:
            guard let token = config.token, !token.isEmpty else { return nil }
            return GatewayConnectAuth(token: token)
        case .password:
            guard let password = config.password, !password.isEmpty else { return nil }
            return GatewayConnectAuth(password: password)
        }
    }

    private static func authHint(for config: GatewayCoreAuthConfig) -> String? {
        switch config.mode {
        case .none:
            return nil
        case .token:
            guard let token = config.token else { return "(missing token)" }
            return "token (\(Self.redacted(token)))"
        case .password:
            guard let password = config.password else { return "(missing password)" }
            return "password (\(Self.redacted(password)))"
        }
    }

    private static func redacted(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "empty" }
        let suffix = String(trimmed.suffix(4))
        return "***\(suffix)"
    }

    private static func loadControlPlaneSettings(
        defaults: UserDefaults = .standard) -> TVOSGatewayControlPlaneSettings
    {
        var settings = TVOSGatewayControlPlaneSettings.default

        let authModeRaw =
            Self.trimmed(defaults.string(forKey: "gateway.tvos.auth.mode"))
            ?? GatewayCoreAuthMode.none.rawValue
        settings.authMode = GatewayCoreAuthMode(rawValue: authModeRaw) ?? .none
        settings.authToken =
            Self.trimmed(defaults.string(forKey: "gateway.tvos.auth.token"))
            ?? ""
        settings.authPassword =
            Self.trimmed(defaults.string(forKey: "gateway.tvos.auth.password"))
            ?? ""

        settings.upstreamURL =
            Self.trimmed(defaults.string(forKey: "gateway.tvos.upstream.url"))
            ?? ""
        settings.upstreamToken =
            Self.trimmed(defaults.string(forKey: "gateway.tvos.upstream.token"))
            ?? ""
        settings.upstreamPassword =
            Self.trimmed(defaults.string(forKey: "gateway.tvos.upstream.password"))
            ?? ""
        settings.upstreamRole =
            Self.trimmed(defaults.string(forKey: "gateway.tvos.upstream.role"))
            ?? "node"
        settings.upstreamScopesCSV =
            Self.trimmed(defaults.string(forKey: "gateway.tvos.upstream.scopes"))
            ?? ""

        let localProviderRaw =
            Self.trimmed(defaults.string(forKey: "gateway.tvos.localLLM.provider"))
            ?? GatewayLocalLLMProviderKind.disabled.rawValue
        settings.localLLMProvider = GatewayLocalLLMProviderKind(rawValue: localProviderRaw) ?? .disabled
        settings.localLLMBaseURL =
            Self.trimmed(defaults.string(forKey: "gateway.tvos.localLLM.baseURL"))
            ?? ""
        settings.localLLMAPIKey =
            Self.trimmed(defaults.string(forKey: "gateway.tvos.localLLM.apiKey"))
            ?? ""
        settings.localLLMModel =
            Self.trimmed(defaults.string(forKey: "gateway.tvos.localLLM.model"))
            ?? ""

        return Self.normalizedSettings(settings)
    }

    private static func persistControlPlaneSettings(
        _ settings: TVOSGatewayControlPlaneSettings,
        defaults: UserDefaults = .standard)
    {
        defaults.set(settings.authMode.rawValue, forKey: "gateway.tvos.auth.mode")

        switch settings.authMode {
        case .none:
            defaults.removeObject(forKey: "gateway.tvos.auth.token")
            defaults.removeObject(forKey: "gateway.tvos.auth.password")
        case .token:
            defaults.set(Self.trimmed(settings.authToken), forKey: "gateway.tvos.auth.token")
            defaults.removeObject(forKey: "gateway.tvos.auth.password")
        case .password:
            defaults.removeObject(forKey: "gateway.tvos.auth.token")
            defaults.set(Self.trimmed(settings.authPassword), forKey: "gateway.tvos.auth.password")
        }

        defaults.set(Self.trimmed(settings.upstreamURL), forKey: "gateway.tvos.upstream.url")
        defaults.set(Self.trimmed(settings.upstreamToken), forKey: "gateway.tvos.upstream.token")
        defaults.set(Self.trimmed(settings.upstreamPassword), forKey: "gateway.tvos.upstream.password")
        defaults.set(Self.trimmed(settings.upstreamRole), forKey: "gateway.tvos.upstream.role")
        defaults.set(Self.trimmed(settings.upstreamScopesCSV), forKey: "gateway.tvos.upstream.scopes")

        defaults.set(settings.localLLMProvider.rawValue, forKey: "gateway.tvos.localLLM.provider")
        defaults.set(Self.trimmed(settings.localLLMBaseURL), forKey: "gateway.tvos.localLLM.baseURL")
        defaults.set(Self.trimmed(settings.localLLMAPIKey), forKey: "gateway.tvos.localLLM.apiKey")
        defaults.set(Self.trimmed(settings.localLLMModel), forKey: "gateway.tvos.localLLM.model")
    }

    private func verifyPersistedControlPlaneSettings(_ expected: TVOSGatewayControlPlaneSettings) {
        let persisted = Self.loadControlPlaneSettings()
        guard persisted != expected else { return }

        var mismatches: [String] = []
        func markIfDifferent<T: Equatable>(_ key: String, _ lhs: T, _ rhs: T) {
            if lhs != rhs {
                mismatches.append(key)
            }
        }

        markIfDifferent("authMode", expected.authMode, persisted.authMode)
        markIfDifferent("authToken", expected.authToken, persisted.authToken)
        markIfDifferent("authPassword", expected.authPassword, persisted.authPassword)
        markIfDifferent("upstreamURL", expected.upstreamURL, persisted.upstreamURL)
        markIfDifferent("upstreamToken", expected.upstreamToken, persisted.upstreamToken)
        markIfDifferent("upstreamPassword", expected.upstreamPassword, persisted.upstreamPassword)
        markIfDifferent("upstreamRole", expected.upstreamRole, persisted.upstreamRole)
        markIfDifferent("upstreamScopesCSV", expected.upstreamScopesCSV, persisted.upstreamScopesCSV)
        markIfDifferent("localLLMProvider", expected.localLLMProvider, persisted.localLLMProvider)
        markIfDifferent("localLLMBaseURL", expected.localLLMBaseURL, persisted.localLLMBaseURL)
        markIfDifferent("localLLMAPIKey", expected.localLLMAPIKey, persisted.localLLMAPIKey)
        markIfDifferent("localLLMModel", expected.localLLMModel, persisted.localLLMModel)

        self.appendLog(
            "settings persistence mismatch fields=\(mismatches.joined(separator: ","))"
                + " runtime.auth=\(expected.authMode.rawValue)/\(Self.redacted(expected.authToken))/\(Self.redacted(expected.authPassword))"
                + " persisted.auth=\(persisted.authMode.rawValue)/\(Self.redacted(persisted.authToken))/\(Self.redacted(persisted.authPassword))"
                + " runtime.upstream=\(Self.trimmed(expected.upstreamURL) ?? "(none)") role=\(Self.trimmed(expected.upstreamRole) ?? "node") scopes=\(Self.trimmed(expected.upstreamScopesCSV) ?? "(none)") token=\(Self.presenceState(expected.upstreamToken)) password=\(Self.presenceState(expected.upstreamPassword))"
                + " persisted.upstream=\(Self.trimmed(persisted.upstreamURL) ?? "(none)") role=\(Self.trimmed(persisted.upstreamRole) ?? "node") scopes=\(Self.trimmed(persisted.upstreamScopesCSV) ?? "(none)") token=\(Self.presenceState(persisted.upstreamToken)) password=\(Self.presenceState(persisted.upstreamPassword))"
                + " runtime.llm=\(expected.localLLMProvider.rawValue) baseURL=\(Self.trimmed(expected.localLLMBaseURL) ?? "(none)") model=\(Self.trimmed(expected.localLLMModel) ?? "(none)") apiKey=\(Self.presenceState(expected.localLLMAPIKey))"
                + " persisted.llm=\(persisted.localLLMProvider.rawValue) baseURL=\(Self.trimmed(persisted.localLLMBaseURL) ?? "(none)") model=\(Self.trimmed(persisted.localLLMModel) ?? "(none)") apiKey=\(Self.presenceState(persisted.localLLMAPIKey))",
            level: .warning)
    }

    private static func presenceState(_ value: String) -> String {
        (Self.trimmed(value)?.isEmpty == false) ? "present" : "missing"
    }

    private static func normalizedSettings(
        _ settings: TVOSGatewayControlPlaneSettings
    ) -> TVOSGatewayControlPlaneSettings {
        let authMode: GatewayCoreAuthMode
        let normalizedAuthToken = Self.trimmed(settings.authToken) ?? ""
        let normalizedAuthPassword = Self.trimmed(settings.authPassword) ?? ""

        switch settings.authMode {
        case .none:
            authMode = .none
        case .token:
            authMode = normalizedAuthToken.isEmpty ? .none : .token
        case .password:
            authMode = normalizedAuthPassword.isEmpty ? .none : .password
        }

        let sanitizedAuthToken =
            authMode == .token ? normalizedAuthToken : ""
        let sanitizedAuthPassword =
            authMode == .password ? normalizedAuthPassword : ""

        return TVOSGatewayControlPlaneSettings(
            authMode: authMode,
            authToken: sanitizedAuthToken,
            authPassword: sanitizedAuthPassword,
            upstreamURL: Self.trimmed(settings.upstreamURL) ?? "",
            upstreamToken: Self.trimmed(settings.upstreamToken) ?? "",
            upstreamPassword: Self.trimmed(settings.upstreamPassword) ?? "",
            upstreamRole: Self.trimmed(settings.upstreamRole) ?? "node",
            upstreamScopesCSV: Self.trimmed(settings.upstreamScopesCSV) ?? "",
            localLLMProvider: settings.localLLMProvider,
            localLLMBaseURL: Self.trimmed(settings.localLLMBaseURL) ?? "",
            localLLMAPIKey: Self.trimmed(settings.localLLMAPIKey) ?? "",
            localLLMModel: Self.trimmed(settings.localLLMModel) ?? "")
    }

    private static func makeAuthConfig(from settings: TVOSGatewayControlPlaneSettings) -> GatewayCoreAuthConfig {
        let token = Self.trimmed(settings.authToken)
        let password = Self.trimmed(settings.authPassword)

        switch settings.authMode {
        case .none:
            return .none
        case .token:
            guard let token else { return .none }
            return GatewayCoreAuthConfig(mode: .token, token: token)
        case .password:
            guard let password else { return .none }
            return GatewayCoreAuthConfig(mode: .password, password: password)
        }
    }

    private func logAuthNormalization(
        from original: TVOSGatewayControlPlaneSettings,
        to normalized: TVOSGatewayControlPlaneSettings,
        context: String)
    {
        if original.authMode == .token && normalized.authMode == .none {
            self.appendLog(
                "auth mode normalization [\(context)]: token mode requested without token; "
                    + "falling back to none")
        }
        if original.authMode == .password && normalized.authMode == .none {
            self.appendLog(
                "auth mode normalization [\(context)]: password mode requested without password; "
                    + "falling back to none")
        }
        if original.authMode == .none && normalized.authMode == .none {
            if Self.trimmed(original.authToken) != nil || Self.trimmed(original.authPassword) != nil {
                self.appendLog(
                    "auth mode normalization [\(context)]: auth mode none, credentials ignored")
            }
        }
    }

    private func logControlPlaneConfigDump(context: String) {
        let upstreamURL = Self.trimmed(self.controlPlaneSettings.upstreamURL) ?? "(none)"
        let upstreamRole = Self.trimmed(self.controlPlaneSettings.upstreamRole) ?? "node"
        let localModel = Self.trimmed(self.controlPlaneSettings.localLLMModel) ?? "(none)"
        let localBaseURL =
            Self.trimmed(self.controlPlaneSettings.localLLMBaseURL) ?? "(none)"
        let bootstrapPath = Self.defaultBootstrapWorkspacePath()
        let bootstrapState = bootstrapPath.isEmpty ? "(none)" : bootstrapPath
        let authTokenState = self.controlPlaneSettings.authToken.isEmpty
            ? "(missing)"
            : Self.redacted(self.controlPlaneSettings.authToken)
        let authPasswordState = self.controlPlaneSettings.authPassword.isEmpty
            ? "(missing)"
            : Self.redacted(self.controlPlaneSettings.authPassword)

        self.appendLog(
            "config dump [\(context)] authMode=\(self.controlPlaneSettings.authMode.rawValue)"
                + " authToken=\(authTokenState)"
                + " authPassword=\(authPasswordState)"
                + " upstream=\(upstreamURL)"
                + " role=\(upstreamRole)"
                + " llm=\(self.controlPlaneSettings.localLLMProvider.rawValue)"
                + " model=\(localModel)"
                + " baseURL=\(localBaseURL)"
                + " bootstrapPath=\(bootstrapState)")
    }

    private static func makeUpstreamConfig(
        from settings: TVOSGatewayControlPlaneSettings) -> TVOSGatewayUpstreamConfigLoadResult
    {
        guard let rawURL = Self.trimmed(settings.upstreamURL) else {
            return TVOSGatewayUpstreamConfigLoadResult(
                config: nil,
                urlText: nil,
                errorText: nil)
        }
        guard let url = URL(string: rawURL) else {
            return TVOSGatewayUpstreamConfigLoadResult(
                config: nil,
                urlText: rawURL,
                errorText: "invalid upstream URL")
        }
        let scheme = url.scheme?.lowercased() ?? ""
        guard scheme == "ws" || scheme == "wss" else {
            return TVOSGatewayUpstreamConfigLoadResult(
                config: nil,
                urlText: rawURL,
                errorText: "upstream URL scheme must be ws or wss")
        }

        let scopes = Self.trimmed(settings.upstreamScopesCSV)?
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        return TVOSGatewayUpstreamConfigLoadResult(
            config: GatewayUpstreamWebSocketConfig(
                url: url,
                token: Self.trimmed(settings.upstreamToken),
                password: Self.trimmed(settings.upstreamPassword),
                role: Self.trimmed(settings.upstreamRole) ?? "node",
                scopes: scopes),
            urlText: url.absoluteString,
            errorText: nil)
    }

    private static func makeLocalLLMConfig(from settings: TVOSGatewayControlPlaneSettings) -> GatewayLocalLLMConfig {
        let baseURL = Self.trimmed(settings.localLLMBaseURL).flatMap(URL.init(string:))
        return GatewayLocalLLMConfig(
            provider: settings.localLLMProvider,
            baseURL: baseURL,
            apiKey: Self.trimmed(settings.localLLMAPIKey),
            model: Self.trimmed(settings.localLLMModel))
    }

    private static func defaultMemoryStorePath() -> URL {
        let fileManager = FileManager.default
        if let cachesBase = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first {
            let preferredStore = cachesBase
                .appendingPathComponent("OpenClawTV", isDirectory: true)
            if self.isWritableDirectory(preferredStore) {
                return preferredStore.appendingPathComponent("GatewayMemory.sqlite", isDirectory: false)
            }
            if self.isWritableDirectory(cachesBase) {
                return cachesBase.appendingPathComponent("GatewayMemory.sqlite", isDirectory: false)
            }
        }

        if let libraryBase = fileManager.urls(for: .libraryDirectory, in: .userDomainMask).first {
            let legacyStore = libraryBase
                .appendingPathComponent("Caches", isDirectory: true)
                .appendingPathComponent("OpenClawTV", isDirectory: true)
            if self.isWritableDirectory(legacyStore) {
                return legacyStore.appendingPathComponent("GatewayMemory.sqlite", isDirectory: false)
            }
            if self.isWritableDirectory(libraryBase) {
                return libraryBase
                    .appendingPathComponent("Caches", isDirectory: true)
                    .appendingPathComponent("GatewayMemory.sqlite", isDirectory: false)
            }
        }

        return fileManager.temporaryDirectory
            .appendingPathComponent("GatewayMemory.sqlite", isDirectory: false)
    }

    private static func defaultBootstrapWorkspacePath() -> String {
        let fileManager = FileManager.default
        var candidates: [URL] = []
        if let documents = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first {
            candidates.append(
                documents
                    .appendingPathComponent("OpenClawTV", isDirectory: true)
                    .appendingPathComponent("Workspace", isDirectory: true))
        }
        if let caches = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first {
            candidates.append(
                caches
                    .appendingPathComponent("OpenClawTVWorkspace", isDirectory: true))
        }
        candidates.append(
            fileManager.temporaryDirectory
                .appendingPathComponent("OpenClawTVWorkspace", isDirectory: true))

        for candidate in candidates {
            if self.isWritableDirectory(candidate) {
                return candidate.path
            }
        }
        return ""
    }

    private static func isWritableDirectory(_ directory: URL) -> Bool {
        let fileManager = FileManager.default
        do {
            try fileManager.createDirectory(
                at: directory,
                withIntermediateDirectories: true)
            let testURL = directory.appendingPathComponent(".openclaw-write-test-\(UUID().uuidString)")
            let marker = Data("ok".utf8)
            try marker.write(to: testURL, options: .atomic)
            try? fileManager.removeItem(at: testURL)
            return true
        } catch {
            return false
        }
    }

    private static func isTCPAddressInUseError(_ error: Error) -> Bool {
        let nsError = error as NSError
        if nsError.domain == NSPOSIXErrorDomain && nsError.code == EADDRINUSE
        {
            return true
        }
        return error.localizedDescription.lowercased().contains("address already in use")
    }

    private static func fallbackMemoryStorePath() -> URL {
        let fileManager = FileManager.default
        if let cachesBase = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first {
            if self.isWritableDirectory(cachesBase) {
                return cachesBase.appendingPathComponent("GatewayMemory.sqlite", isDirectory: false)
            }
            return cachesBase
                .appendingPathComponent("OpenClawTV", isDirectory: true)
                .appendingPathComponent("GatewayMemory.sqlite", isDirectory: false)
        }
        return fileManager.temporaryDirectory
            .appendingPathComponent("GatewayMemory.sqlite", isDirectory: false)
    }

    private func appendLog(_ message: String, level: TVOSGatewayRuntimeLogEntry.Level = .info) {
        let formattedMessage = "[OpenClaw tvOS][\(level.rawValue.uppercased())] \(message)"
#if DEBUG
        print(formattedMessage)
#endif
        switch level {
        case .info:
            Self.runtimeLogger.info("\(formattedMessage, privacy: .public)")
        case .warning:
            Self.runtimeLogger.warning("\(formattedMessage, privacy: .public)")
        case .error:
            Self.runtimeLogger.error("\(formattedMessage, privacy: .public)")
        }

        self.diagnosticsLog.append(
            TVOSGatewayRuntimeLogEntry(level: level, message: message))

        let overflowCount = self.diagnosticsLog.count - Self.maxDiagnosticsLogEntries
        if overflowCount > 0 {
            self.diagnosticsLog.removeFirst(overflowCount)
        }
    }

    private static func trimmed(_ value: String?) -> String? {
        let raw = (value ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return raw.isEmpty ? nil : raw
    }

    private static func listenerEndpointSummary(
        port: UInt16,
        localAddresses: [String],
        scheme: String) -> String
    {
        let loopback = "\(scheme)://127.0.0.1:\(port)"
        guard !localAddresses.isEmpty else {
            return "0.0.0.0:\(port) (\(loopback))"
        }
        let lan = localAddresses
            .map { "\(scheme)://\($0):\(port)" }
            .joined(separator: ", ")
        return "0.0.0.0:\(port) (\(loopback), \(lan))"
    }

    private struct LocalIPv4Interface: Sendable {
        let name: String
        let address: String
    }

    private static func collectLocalIPv4Interfaces() -> [LocalIPv4Interface] {
        var interfaces: [LocalIPv4Interface] = []
        var pointer: UnsafeMutablePointer<ifaddrs>?

        guard getifaddrs(&pointer) == 0, let first = pointer else {
            return []
        }
        defer { freeifaddrs(pointer) }

        var current: UnsafeMutablePointer<ifaddrs>? = first
        while let entry = current {
            defer { current = entry.pointee.ifa_next }

            let flags = entry.pointee.ifa_flags
            guard (flags & UInt32(IFF_UP)) != 0, (flags & UInt32(IFF_RUNNING)) != 0 else {
                continue
            }
            guard (flags & UInt32(IFF_LOOPBACK)) == 0 else {
                continue
            }
            guard let addressPtr = entry.pointee.ifa_addr else {
                continue
            }
            guard addressPtr.pointee.sa_family == UInt8(AF_INET) else {
                continue
            }

            let interfaceName = String(cString: entry.pointee.ifa_name)
            guard !interfaceName.hasPrefix("lo"), !interfaceName.hasPrefix("utun"),
                  !interfaceName.hasPrefix("awdl"), !interfaceName.hasPrefix("llw")
            else {
                continue
            }

            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let getNameResult = getnameinfo(
                addressPtr,
                socklen_t(addressPtr.pointee.sa_len),
                &host,
                socklen_t(host.count),
                nil,
                0,
                NI_NUMERICHOST)
            guard getNameResult == 0 else {
                continue
            }

            let utf8Bytes = host.map { UInt8(bitPattern: $0) }
            let ipAddress = String(decoding: utf8Bytes.prefix { $0 != 0 }, as: UTF8.self)
            guard !ipAddress.isEmpty else {
                continue
            }

            interfaces.append(
                LocalIPv4Interface(
                    name: interfaceName,
                    address: ipAddress))
        }

        interfaces.sort { lhs, rhs in
            let leftPriority = Self.interfacePriority(lhs.name)
            let rightPriority = Self.interfacePriority(rhs.name)
            if leftPriority != rightPriority {
                return leftPriority < rightPriority
            }
            if lhs.name != rhs.name {
                return lhs.name < rhs.name
            }
            return lhs.address < rhs.address
        }

        var seenAddresses = Set<String>()
        return interfaces.filter { seenAddresses.insert($0.address).inserted }
    }

    private static func interfacePriority(_ name: String) -> Int {
        if name == "en0" {
            return 0
        }
        if name == "en1" {
            return 1
        }
        if name.hasPrefix("en") {
            return 2
        }
        if name.hasPrefix("bridge") {
            return 3
        }
        return 4
    }
}
#endif
