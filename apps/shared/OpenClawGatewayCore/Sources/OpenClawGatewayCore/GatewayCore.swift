import Foundation

public enum GatewayCoreErrorCode: String, Sendable, Equatable {
    case methodNotFound = "METHOD_NOT_FOUND"
}

public struct GatewayInvocationRequest: Sendable, Equatable {
    public let method: String
    public let paramsJSON: String?

    public init(method: String, paramsJSON: String? = nil) {
        self.method = method
        self.paramsJSON = paramsJSON
    }
}

public struct GatewayHealthPayload: Sendable, Equatable {
    public let ok: Bool
    public let ts: Int64
    public let uptimeMs: Int64
    public let durationMs: Int

    public init(ok: Bool, ts: Int64, uptimeMs: Int64, durationMs: Int) {
        self.ok = ok
        self.ts = ts
        self.uptimeMs = uptimeMs
        self.durationMs = durationMs
    }
}

public struct GatewayStatusPayload: Sendable, Equatable {
    public let heartbeatDefaultAgentId: String
    public let sessionCount: Int

    public init(heartbeatDefaultAgentId: String, sessionCount: Int) {
        self.heartbeatDefaultAgentId = heartbeatDefaultAgentId
        self.sessionCount = sessionCount
    }
}

public enum GatewaySuccessPayload: Sendable, Equatable {
    case health(GatewayHealthPayload)
    case status(GatewayStatusPayload)
}

public struct GatewayFailurePayload: Sendable, Equatable {
    public let code: GatewayCoreErrorCode
    public let message: String

    public init(code: GatewayCoreErrorCode, message: String) {
        self.code = code
        self.message = message
    }
}

public enum GatewayInvocationResult: Sendable, Equatable {
    case success(GatewaySuccessPayload)
    case failure(GatewayFailurePayload)
}

public struct GatewayCore: Sendable {
    private let startedAtMs: Int64

    public init(startedAtMs: Int64 = GatewayCore.currentTimestampMs()) {
        self.startedAtMs = startedAtMs
    }

    public static func currentTimestampMs() -> Int64 {
        Int64(Date().timeIntervalSince1970 * 1000)
    }

    public func handle(
        _ request: GatewayInvocationRequest,
        nowMs: Int64 = GatewayCore.currentTimestampMs()) -> GatewayInvocationResult
    {
        switch request.method {
        case "health":
            let uptimeMs = max(0, nowMs - self.startedAtMs)
            return .success(
                .health(
                    GatewayHealthPayload(
                        ok: true,
                        ts: nowMs,
                        uptimeMs: uptimeMs,
                        durationMs: 0)))
        case "status":
            return .success(
                .status(
                    GatewayStatusPayload(
                        heartbeatDefaultAgentId: "main",
                        sessionCount: 0)))
        default:
            return .failure(
                GatewayFailurePayload(
                    code: .methodNotFound,
                    message: "unknown method: \(request.method)"))
        }
    }
}
