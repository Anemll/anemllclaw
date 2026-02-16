#if os(tvOS)
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
    private(set) var upstreamConfigured: Bool
    private(set) var upstreamURLText: String?
    private(set) var upstreamConfigErrorText: String?
    private(set) var lastUpstreamProbeSucceeded: Bool?
    private(set) var lastUpstreamProbeErrorText: String?

    private(set) var listenerAuthMode: GatewayCoreAuthMode
    private(set) var listenerAuthHint: String?

    private(set) var lastProbeSucceeded: Bool?
    private(set) var lastWebSocketProbeSucceeded: Bool?
    private(set) var lastWebSocketProbeErrorText: String?
    private(set) var lastTCPProbeSucceeded: Bool?
    private(set) var lastTCPProbeErrorText: String?
    private(set) var diagnosticsLog: [TVOSGatewayRuntimeLogEntry]

    private let webSocketListenPortPreference: UInt16
    private let tcpListenPortPreference: UInt16
    private let exposeTCPListener: Bool
    private let gatewayAuthConfig: GatewayCoreAuthConfig

    private let host: GatewayLoopbackHost
    private let webSocketServer: GatewayWebSocketServer
    private let tcpServer: GatewayTCPJSONServer
    private let upstreamClient: GatewayUpstreamWebSocketClient?

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
        self.gatewayAuthConfig = tcpAuthConfig
        self.listenerAuthMode = tcpAuthConfig.mode
        self.listenerAuthHint = Self.authHint(for: tcpAuthConfig)

        let upstreamLoadResult: TVOSGatewayUpstreamConfigLoadResult
        if let upstreamConfig {
            upstreamLoadResult = TVOSGatewayUpstreamConfigLoadResult(
                config: upstreamConfig,
                urlText: upstreamConfig.url.absoluteString,
                errorText: nil)
        } else {
            upstreamLoadResult = Self.loadUpstreamConfig()
        }
        let resolvedUpstreamConfig = upstreamLoadResult.config
        self.upstreamConfigured = resolvedUpstreamConfig != nil
        self.upstreamURLText = upstreamLoadResult.urlText
        self.upstreamConfigErrorText = upstreamLoadResult.errorText
        self.lastUpstreamProbeSucceeded = nil
        self.lastUpstreamProbeErrorText = nil
        self.diagnosticsLog = []

        let upstreamClient = resolvedUpstreamConfig.map { GatewayUpstreamWebSocketClient(config: $0) }
        self.upstreamClient = upstreamClient

        let resolvedTransport = transport ?? GatewayLoopbackTransport(
            core: GatewayCore(authConfig: tcpAuthConfig),
            upstream: upstreamClient)
        self.host = GatewayLoopbackHost(transport: resolvedTransport)
        self.webSocketServer = GatewayWebSocketServer(transport: resolvedTransport)
        self.tcpServer = GatewayTCPJSONServer(transport: resolvedTransport, authConfig: tcpAuthConfig)

        self.appendLog(
            "runtime initialized wsPort=\(listenPort) tcpDebug=\(exposeTCPListener ? "enabled" : "disabled") auth=\(tcpAuthConfig.mode.rawValue)")
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
        self.appendLog("runtime start requested")
        await self.host.start()
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
        if self.exposeTCPListener {
            await self.stopTCPListener()
        }
        await self.stopWebSocketListener()
        if let upstreamClient = self.upstreamClient {
            await upstreamClient.disconnect()
            self.appendLog("upstream disconnected")
        }
        await self.host.stop()

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

    func probeHealth(nowMs: Int64 = GatewayCore.currentTimestampMs()) async {
        guard self.state == .running else {
            self.lastProbeSucceeded = nil
            return
        }
        do {
            let response = try await self.host.invoke(
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
        do {
            let boundPort = try await self.webSocketServer.start(port: self.webSocketListenPortPreference)
            self.listenerPort = boundPort
            self.listenerErrorText = nil
            self.listenerState = .listening
            self.appendLog("websocket listener active on 127.0.0.1:\(boundPort)")
        } catch {
            self.listenerPort = nil
            self.listenerErrorText = error.localizedDescription
            self.listenerState = .failed
            self.appendLog("websocket listener failed: \(error.localizedDescription)", level: .error)
        }
    }

    func restartWebSocketListener() async {
        self.appendLog("websocket listener restart requested")
        await self.stopWebSocketListener()
        await self.startWebSocketListenerIfNeeded()
    }

    func stopWebSocketListener() async {
        await self.webSocketServer.stop()
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
        do {
            let boundPort = try await self.tcpServer.start(port: self.tcpListenPortPreference)
            self.tcpListenerPort = boundPort
            self.tcpListenerErrorText = nil
            self.tcpListenerState = .listening
            self.appendLog("tcp debug listener active on 127.0.0.1:\(boundPort)")
        } catch {
            self.tcpListenerPort = nil
            self.tcpListenerErrorText = error.localizedDescription
            self.tcpListenerState = .failed
            self.appendLog("tcp debug listener failed: \(error.localizedDescription)", level: .error)
        }
    }

    func restartTCPListener() async {
        guard self.exposeTCPListener else { return }
        self.appendLog("tcp debug listener restart requested")
        await self.stopTCPListener()
        await self.startTCPListenerIfNeeded()
    }

    func stopTCPListener() async {
        await self.tcpServer.stop()
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

    private static func loadUpstreamConfig(
        defaults: UserDefaults = .standard) -> TVOSGatewayUpstreamConfigLoadResult
    {
        let env = ProcessInfo.processInfo.environment
        let rawURLValue = Self.trimmed(env["OPENCLAW_TVOS_UPSTREAM_URL"])
            ?? Self.trimmed(defaults.string(forKey: "gateway.tvos.upstream.url"))

        guard let rawURL = rawURLValue else {
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

        let token = Self.trimmed(env["OPENCLAW_TVOS_UPSTREAM_TOKEN"])
            ?? Self.trimmed(defaults.string(forKey: "gateway.tvos.upstream.token"))
        let password = Self.trimmed(env["OPENCLAW_TVOS_UPSTREAM_PASSWORD"])
            ?? Self.trimmed(defaults.string(forKey: "gateway.tvos.upstream.password"))
        let role = Self.trimmed(env["OPENCLAW_TVOS_UPSTREAM_ROLE"])
            ?? Self.trimmed(defaults.string(forKey: "gateway.tvos.upstream.role"))
            ?? "node"

        let scopesRaw = Self.trimmed(env["OPENCLAW_TVOS_UPSTREAM_SCOPES"])
            ?? Self.trimmed(defaults.string(forKey: "gateway.tvos.upstream.scopes"))
        let scopes: [String]? = scopesRaw?
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        return TVOSGatewayUpstreamConfigLoadResult(
            config: GatewayUpstreamWebSocketConfig(
                url: url,
                token: token,
                password: password,
                role: role,
                scopes: scopes),
            urlText: url.absoluteString,
            errorText: nil)
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
}
#endif
