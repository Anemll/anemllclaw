#if os(tvOS)
import Darwin
import Foundation
import Network
import Observation
import OpenClawGatewayCore

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

@MainActor
@Observable
final class TVOSLocalGatewayRuntime {
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

    private static let maxDiagnosticsLogEntries = 150

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

        self.host = nil
        self.webSocketServer = nil
        self.tcpServer = nil
        self.upstreamClient = nil
        self.webSocketRetryTask = nil
        self.tcpRetryTask = nil

        self.rebuildGatewayStack()
        self.refreshLocalNetworkAddresses()

        self.appendLog(
            "runtime initialized wsPort=\(listenPort) tcpDebug=\(exposeTCPListener ? "enabled" : "disabled") auth=\(self.gatewayAuthConfig.mode.rawValue)")
        if self.upstreamConfigured {
            self.appendLog("upstream configured url=\(self.upstreamURLText ?? "(unknown)")")
        } else if let errorText = self.upstreamConfigErrorText {
            self.appendLog("upstream config error: \(errorText)", level: .error)
        } else {
            self.appendLog("upstream not configured", level: .warning)
        }
    }

    func start() async {
        guard self.state != .running else { return }
        self.refreshLocalNetworkAddresses()
        self.appendLog("runtime start requested")
        await self.host?.start()
        await self.startWebSocketListenerIfNeeded()
        if self.exposeTCPListener {
            await self.startTCPListenerIfNeeded()
        }
        self.state = .running
        self.appendLog(
            "runtime running ws=\(self.listenerState.rawValue) tcp=\(self.tcpListenerState.rawValue)")
    }

    func stop() async {
        guard self.state != .stopped else { return }
        self.appendLog("runtime stop requested")
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
        self.webSocketRetryAttempt = 0
        self.webSocketRetryDelaySeconds = nil
        self.tcpRetryAttempt = 0
        self.tcpRetryDelaySeconds = nil
        self.appendLog("error states cleared")
    }

    func applyControlPlaneSettings(_ next: TVOSGatewayControlPlaneSettings) async {
        let normalized = Self.normalizedSettings(next)
        guard normalized != self.controlPlaneSettings else {
            self.appendLog("control plane settings unchanged")
            return
        }

        let wasRunning = self.state == .running
        if wasRunning {
            await self.stop()
        }

        self.controlPlaneSettings = normalized
        Self.persistControlPlaneSettings(normalized)
        self.rebuildGatewayStack()
        self.clearErrorStates()
        self.appendLog(
            "control plane settings applied auth=\(normalized.authMode.rawValue) upstream=\(Self.trimmed(normalized.upstreamURL) ?? "(none)") llm=\(normalized.localLLMProvider.rawValue)")

        if wasRunning {
            await self.start()
            await self.probeHealth()
            await self.probeHealthOverWebSocket()
            await self.probeUpstreamHealth()
        }
    }

    func refreshLocalNetworkAddresses() {
        let addresses = Self.collectLocalIPv4Interfaces()
        self.localIPv4Address = addresses.first?.address
        self.localIPv4Addresses = addresses.map(\.address)
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
            self.appendLog("websocket listener active on 127.0.0.1:\(boundPort)")
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
        do {
            let boundPort = try await tcpServer.start(port: self.tcpListenPortPreference)
            self.tcpListenerPort = boundPort
            self.tcpListenerErrorText = nil
            self.tcpListenerState = .listening
            self.tcpRetryTask?.cancel()
            self.tcpRetryTask = nil
            self.tcpRetryAttempt = 0
            self.tcpRetryDelaySeconds = nil
            self.appendLog("tcp debug listener active on 127.0.0.1:\(boundPort)")
        } catch {
            self.tcpListenerPort = nil
            self.tcpListenerErrorText = error.localizedDescription
            self.tcpListenerState = .failed
            self.appendLog("tcp debug listener failed: \(error.localizedDescription)", level: .error)
            self.scheduleTCPRetry()
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
        guard self.state == .running else { return }
        guard self.tcpRetryTask == nil else { return }
        self.tcpRetryAttempt += 1
        let exponentialDelay = 1 << min(self.tcpRetryAttempt - 1, 4)
        let delaySeconds = min(20, max(1, exponentialDelay))
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
        self.localLLMProviderLabel = localLLMConfig.provider.rawValue
        self.localLLMConfigErrorText = nil
        if localLLMConfig.provider != .disabled, !localLLMConfig.isConfigured {
            self.localLLMConfigErrorText = "provider selected but local LLM config is incomplete"
        }

        let resolvedTransport: GatewayLoopbackTransport
        if let transportOverride = self.transportOverride {
            resolvedTransport = transportOverride
        } else {
            var localRouter: GatewayLocalMethodRouter?
            do {
                localRouter = try GatewayLocalMethodRouter(
                    config: GatewayLocalMethodRouterConfig(
                        hostLabel: "tvos-local",
                        upstreamConfigured: self.upstreamConfigured,
                        llmConfig: localLLMConfig,
                        memoryStorePath: Self.defaultMemoryStorePath(),
                        enableLocalSafeTools: true))
            } catch {
                self.localLLMConfigErrorText = "local router init failed: \(error.localizedDescription)"
                self.appendLog(
                    "local method router init failed: \(error.localizedDescription)",
                    level: .error)
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
        let env = ProcessInfo.processInfo.environment
        var settings = TVOSGatewayControlPlaneSettings.default

        let authModeRaw = Self.trimmed(env["OPENCLAW_TVOS_AUTH_MODE"])
            ?? Self.trimmed(defaults.string(forKey: "gateway.tvos.auth.mode"))
            ?? GatewayCoreAuthMode.none.rawValue
        settings.authMode = GatewayCoreAuthMode(rawValue: authModeRaw) ?? .none
        settings.authToken = Self.trimmed(env["OPENCLAW_TVOS_AUTH_TOKEN"])
            ?? Self.trimmed(defaults.string(forKey: "gateway.tvos.auth.token"))
            ?? ""
        settings.authPassword = Self.trimmed(env["OPENCLAW_TVOS_AUTH_PASSWORD"])
            ?? Self.trimmed(defaults.string(forKey: "gateway.tvos.auth.password"))
            ?? ""

        settings.upstreamURL = Self.trimmed(env["OPENCLAW_TVOS_UPSTREAM_URL"])
            ?? Self.trimmed(defaults.string(forKey: "gateway.tvos.upstream.url"))
            ?? ""
        settings.upstreamToken = Self.trimmed(env["OPENCLAW_TVOS_UPSTREAM_TOKEN"])
            ?? Self.trimmed(defaults.string(forKey: "gateway.tvos.upstream.token"))
            ?? ""
        settings.upstreamPassword = Self.trimmed(env["OPENCLAW_TVOS_UPSTREAM_PASSWORD"])
            ?? Self.trimmed(defaults.string(forKey: "gateway.tvos.upstream.password"))
            ?? ""
        settings.upstreamRole = Self.trimmed(env["OPENCLAW_TVOS_UPSTREAM_ROLE"])
            ?? Self.trimmed(defaults.string(forKey: "gateway.tvos.upstream.role"))
            ?? "node"
        settings.upstreamScopesCSV = Self.trimmed(env["OPENCLAW_TVOS_UPSTREAM_SCOPES"])
            ?? Self.trimmed(defaults.string(forKey: "gateway.tvos.upstream.scopes"))
            ?? ""

        let localProviderRaw = Self.trimmed(env["OPENCLAW_TVOS_LOCAL_LLM_PROVIDER"])
            ?? Self.trimmed(defaults.string(forKey: "gateway.tvos.localLLM.provider"))
            ?? GatewayLocalLLMProviderKind.disabled.rawValue
        settings.localLLMProvider = GatewayLocalLLMProviderKind(rawValue: localProviderRaw) ?? .disabled
        settings.localLLMBaseURL = Self.trimmed(env["OPENCLAW_TVOS_LOCAL_LLM_BASE_URL"])
            ?? Self.trimmed(defaults.string(forKey: "gateway.tvos.localLLM.baseURL"))
            ?? ""
        settings.localLLMAPIKey = Self.trimmed(env["OPENCLAW_TVOS_LOCAL_LLM_API_KEY"])
            ?? Self.trimmed(defaults.string(forKey: "gateway.tvos.localLLM.apiKey"))
            ?? ""
        settings.localLLMModel = Self.trimmed(env["OPENCLAW_TVOS_LOCAL_LLM_MODEL"])
            ?? Self.trimmed(defaults.string(forKey: "gateway.tvos.localLLM.model"))
            ?? ""

        return Self.normalizedSettings(settings)
    }

    private static func persistControlPlaneSettings(
        _ settings: TVOSGatewayControlPlaneSettings,
        defaults: UserDefaults = .standard)
    {
        defaults.set(settings.authMode.rawValue, forKey: "gateway.tvos.auth.mode")
        defaults.set(Self.trimmed(settings.authToken), forKey: "gateway.tvos.auth.token")
        defaults.set(Self.trimmed(settings.authPassword), forKey: "gateway.tvos.auth.password")

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

    private static func normalizedSettings(_ settings: TVOSGatewayControlPlaneSettings) -> TVOSGatewayControlPlaneSettings {
        TVOSGatewayControlPlaneSettings(
            authMode: settings.authMode,
            authToken: Self.trimmed(settings.authToken) ?? "",
            authPassword: Self.trimmed(settings.authPassword) ?? "",
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
            return GatewayCoreAuthConfig(mode: .token, token: token)
        case .password:
            return GatewayCoreAuthConfig(mode: .password, password: password)
        }
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
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        return base
            .appendingPathComponent("OpenClawTV", isDirectory: true)
            .appendingPathComponent("GatewayMemory.sqlite", isDirectory: false)
    }

    private func appendLog(_ message: String, level: TVOSGatewayRuntimeLogEntry.Level = .info) {
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
