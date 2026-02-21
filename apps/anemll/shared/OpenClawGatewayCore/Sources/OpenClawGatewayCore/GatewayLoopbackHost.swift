import Foundation

public protocol GatewayRPCTransport: Sendable {
    func send(_ request: GatewayRequestFrame, nowMs: Int64) async throws -> GatewayResponseFrame
}

extension GatewayRPCTransport {
    public func send(_ request: GatewayRequestFrame) async throws -> GatewayResponseFrame {
        try await self.send(request, nowMs: GatewayCore.currentTimestampMs())
    }
}

public actor GatewayLoopbackTransport: GatewayRPCTransport {
    private let core: GatewayCore
    private let upstream: (any GatewayUpstreamForwarding)?
    private let localMethods: (any GatewayLocalMethodHandling)?
    private let decoder = JSONDecoder()
    private let encoder = JSONEncoder()

    public init(
        core: GatewayCore = GatewayCore(),
        upstream: (any GatewayUpstreamForwarding)? = nil,
        localMethods: (any GatewayLocalMethodHandling)? = nil)
    {
        self.core = core
        self.upstream = upstream
        self.localMethods = localMethods
    }

    public func send(
        _ request: GatewayRequestFrame,
        nowMs: Int64) async throws -> GatewayResponseFrame
    {
        if let localMethods,
           let localHandledResponse = await localMethods.handle(request, nowMs: nowMs)
        {
            return localHandledResponse
        }

        let localResponse = self.core.dispatch(request, nowMs: nowMs)
        guard Self.shouldForwardToUpstream(localResponse) else {
            return localResponse
        }
        guard let upstream = self.upstream else {
            if Self.requiresUpstreamWithoutConfiguredForwarder(
                method: request.method,
                response: localResponse)
            {
                return GatewayResponseFrame.failure(
                    id: request.id,
                    code: .upstreamRequired,
                    message: "upstream required for \(request.method): configure upstream URL/token or enable local support")
            }
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

    private static func requiresUpstreamWithoutConfiguredForwarder(
        method: String,
        response: GatewayResponseFrame) -> Bool
    {
        guard let code = response.error?.code else {
            return false
        }
        if code == GatewayCoreErrorCode.unsupportedOnHost.rawValue {
            return true
        }
        guard code == GatewayCoreErrorCode.methodNotFound.rawValue else {
            return false
        }
        if method.hasPrefix("chat.") || method.hasPrefix("memory.") {
            return true
        }
        return GatewayRoutingPolicy.requiresUpstream(method)
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
