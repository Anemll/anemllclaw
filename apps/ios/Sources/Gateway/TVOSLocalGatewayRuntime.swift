#if os(tvOS)
import Foundation
import Network
import Observation
import OpenClawGatewayCore

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

    private(set) var listenerAuthMode: GatewayCoreAuthMode
    private(set) var listenerAuthHint: String?

    private(set) var lastProbeSucceeded: Bool?
    private(set) var lastWebSocketProbeSucceeded: Bool?
    private(set) var lastWebSocketProbeErrorText: String?
    private(set) var lastTCPProbeSucceeded: Bool?
    private(set) var lastTCPProbeErrorText: String?

    private let webSocketListenPortPreference: UInt16
    private let tcpListenPortPreference: UInt16
    private let exposeTCPListener: Bool
    private let gatewayAuthConfig: GatewayCoreAuthConfig

    private let host: GatewayLoopbackHost
    private let webSocketServer: GatewayWebSocketServer
    private let tcpServer: GatewayTCPJSONServer

    init(
        exposeTCPListener: Bool = true,
        listenPort: UInt16 = 18_789,
        tcpDebugPort: UInt16 = 18_790,
        transport: GatewayLoopbackTransport? = nil,
        tcpAuthConfig: GatewayCoreAuthConfig = .none)
    {
        self.exposeTCPListener = exposeTCPListener
        self.webSocketListenPortPreference = listenPort
        self.tcpListenPortPreference = tcpDebugPort
        self.gatewayAuthConfig = tcpAuthConfig
        self.listenerAuthMode = tcpAuthConfig.mode
        self.listenerAuthHint = Self.authHint(for: tcpAuthConfig)

        let resolvedTransport = transport ?? GatewayLoopbackTransport(
            core: GatewayCore(authConfig: tcpAuthConfig))
        self.host = GatewayLoopbackHost(transport: resolvedTransport)
        self.webSocketServer = GatewayWebSocketServer(transport: resolvedTransport)
        self.tcpServer = GatewayTCPJSONServer(transport: resolvedTransport, authConfig: tcpAuthConfig)
    }

    func start() async {
        guard self.state != .running else { return }
        await self.host.start()
        await self.startWebSocketListenerIfNeeded()
        if self.exposeTCPListener {
            await self.startTCPListenerIfNeeded()
        }
        self.state = .running
    }

    func stop() async {
        guard self.state != .stopped else { return }
        if self.exposeTCPListener {
            await self.stopTCPListener()
        }
        await self.stopWebSocketListener()
        await self.host.stop()

        self.state = .stopped
        self.lastProbeSucceeded = nil
        self.lastWebSocketProbeSucceeded = nil
        self.lastWebSocketProbeErrorText = nil
        self.lastTCPProbeSucceeded = nil
        self.lastTCPProbeErrorText = nil
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
        } catch {
            self.lastProbeSucceeded = false
        }
    }

    func startWebSocketListenerIfNeeded() async {
        guard self.listenerState != .listening else { return }
        do {
            let boundPort = try await self.webSocketServer.start(port: self.webSocketListenPortPreference)
            self.listenerPort = boundPort
            self.listenerErrorText = nil
            self.listenerState = .listening
        } catch {
            self.listenerPort = nil
            self.listenerErrorText = error.localizedDescription
            self.listenerState = .failed
        }
    }

    func restartWebSocketListener() async {
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
        } catch {
            self.lastWebSocketProbeSucceeded = false
            self.lastWebSocketProbeErrorText = error.localizedDescription
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
        } catch {
            self.tcpListenerPort = nil
            self.tcpListenerErrorText = error.localizedDescription
            self.tcpListenerState = .failed
        }
    }

    func restartTCPListener() async {
        guard self.exposeTCPListener else { return }
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
        } catch {
            self.lastTCPProbeSucceeded = false
            self.lastTCPProbeErrorText = error.localizedDescription
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
}
#endif
