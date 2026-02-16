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
    private(set) var listenerState: ListenerState = .stopped
    private(set) var listenerPort: UInt16?
    private(set) var listenerErrorText: String?
    private(set) var listenerAuthMode: GatewayCoreAuthMode
    private(set) var listenerAuthHint: String?
    private(set) var lastProbeSucceeded: Bool?
    private(set) var lastTCPProbeSucceeded: Bool?
    private(set) var lastTCPProbeErrorText: String?
    private let listenPortPreference: UInt16
    private let exposeTCPListener: Bool
    private let tcpAuthConfig: GatewayCoreAuthConfig
    private let host: GatewayLoopbackHost
    private let tcpServer: GatewayTCPJSONServer

    init(
        exposeTCPListener: Bool = true,
        listenPort: UInt16 = 18_789,
        transport: GatewayLoopbackTransport = GatewayLoopbackTransport(),
        tcpAuthConfig: GatewayCoreAuthConfig = .none)
    {
        self.exposeTCPListener = exposeTCPListener
        self.listenPortPreference = listenPort
        self.tcpAuthConfig = tcpAuthConfig
        self.listenerAuthMode = tcpAuthConfig.mode
        self.listenerAuthHint = Self.authHint(for: tcpAuthConfig)
        self.host = GatewayLoopbackHost(transport: transport)
        self.tcpServer = GatewayTCPJSONServer(transport: transport, authConfig: tcpAuthConfig)
    }

    func start() async {
        guard self.state != .running else { return }
        await self.host.start()
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
        await self.host.stop()
        self.state = .stopped
        self.lastProbeSucceeded = nil
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

    func startTCPListenerIfNeeded() async {
        guard self.exposeTCPListener else { return }
        guard self.listenerState != .listening else { return }
        do {
            let boundPort = try await self.tcpServer.start(port: self.listenPortPreference)
            self.listenerPort = boundPort
            self.listenerErrorText = nil
            self.listenerState = .listening
        } catch {
            self.listenerPort = nil
            self.listenerErrorText = error.localizedDescription
            self.listenerState = .failed
        }
    }

    func restartTCPListener() async {
        guard self.exposeTCPListener else { return }
        await self.stopTCPListener()
        await self.startTCPListenerIfNeeded()
    }

    func stopTCPListener() async {
        await self.tcpServer.stop()
        self.listenerPort = nil
        self.listenerState = .stopped
        self.listenerErrorText = nil
        self.lastTCPProbeSucceeded = nil
        self.lastTCPProbeErrorText = nil
    }

    func probeHealthOverTCP() async {
        guard self.state == .running, let listenerPort = self.listenerPort else {
            self.lastTCPProbeSucceeded = nil
            self.lastTCPProbeErrorText = nil
            return
        }

        do {
            let response = try await Self.sendHealthProbe(
                port: listenerPort,
                authConfig: self.tcpAuthConfig)
            self.lastTCPProbeSucceeded = response.ok
            self.lastTCPProbeErrorText = response.error?.message
        } catch {
            self.lastTCPProbeSucceeded = false
            self.lastTCPProbeErrorText = error.localizedDescription
        }
    }

    private static func sendHealthProbe(
        port: UInt16,
        authConfig: GatewayCoreAuthConfig) async throws -> GatewayResponseFrame
    {
        let connection = NWConnection(
            host: NWEndpoint.Host("127.0.0.1"),
            port: NWEndpoint.Port(rawValue: port) ?? .any,
            using: .tcp)
        let queue = DispatchQueue(label: "ai.openclaw.tvos.gateway-probe.\(UUID().uuidString)")
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
