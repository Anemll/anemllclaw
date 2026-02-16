import Foundation

public protocol GatewayRPCTransport: Sendable {
    func send(_ request: GatewayRequestFrame, nowMs: Int64) async throws -> GatewayResponseFrame
}

public extension GatewayRPCTransport {
    func send(_ request: GatewayRequestFrame) async throws -> GatewayResponseFrame {
        try await self.send(request, nowMs: GatewayCore.currentTimestampMs())
    }
}

public actor GatewayLoopbackTransport: GatewayRPCTransport {
    private let core: GatewayCore
    private let upstream: (any GatewayUpstreamForwarding)?
    private let decoder = JSONDecoder()
    private let encoder = JSONEncoder()

    public init(
        core: GatewayCore = GatewayCore(),
        upstream: (any GatewayUpstreamForwarding)? = nil)
    {
        self.core = core
        self.upstream = upstream
    }

    public func send(
        _ request: GatewayRequestFrame,
        nowMs: Int64) async throws -> GatewayResponseFrame
    {
        let localResponse = self.core.dispatch(request, nowMs: nowMs)
        guard Self.shouldForwardToUpstream(localResponse),
              let upstream = self.upstream
        else {
            return localResponse
        }

        do {
            return try await upstream.forward(request)
        } catch {
            return GatewayResponseFrame.failure(
                id: request.id,
                code: .internalError,
                message: "upstream forwarding failed: \(error.localizedDescription)")
        }
    }

    private static func shouldForwardToUpstream(_ response: GatewayResponseFrame) -> Bool {
        guard let code = response.error?.code else {
            return false
        }
        return code == GatewayCoreErrorCode.unsupportedOnHost.rawValue
            || code == GatewayCoreErrorCode.methodNotFound.rawValue
    }

    public func sendJSON(
        _ requestData: Data,
        nowMs: Int64 = GatewayCore.currentTimestampMs()) async throws -> Data
    {
        let request = try self.decoder.decode(GatewayRequestFrame.self, from: requestData)
        let response = try await self.send(request, nowMs: nowMs)
        return try self.encoder.encode(response)
    }
}

public enum GatewayLoopbackHostError: Error, Sendable, Equatable {
    case notRunning
}

public actor GatewayLoopbackHost {
    public enum State: String, Sendable {
        case stopped
        case running
    }

    private let transport: any GatewayRPCTransport
    private var state: State = .stopped

    public init(transport: any GatewayRPCTransport = GatewayLoopbackTransport()) {
        self.transport = transport
    }

    public func start() {
        self.state = .running
    }

    public func stop() {
        self.state = .stopped
    }

    public func currentState() -> State {
        self.state
    }

    public func invoke(
        _ request: GatewayRequestFrame,
        nowMs: Int64 = GatewayCore.currentTimestampMs()) async throws -> GatewayResponseFrame
    {
        guard self.state == .running else {
            throw GatewayLoopbackHostError.notRunning
        }
        return try await self.transport.send(request, nowMs: nowMs)
    }
}
