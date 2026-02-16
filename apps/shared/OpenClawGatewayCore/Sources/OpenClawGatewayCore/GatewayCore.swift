import Foundation

public enum GatewayCoreErrorCode: String, Codable, Sendable, Equatable {
    case authRequired = "AUTH_REQUIRED"
    case authFailed = "AUTH_FAILED"
    case invalidRequest = "INVALID_REQUEST"
    case methodNotFound = "METHOD_NOT_FOUND"
    case unsupportedOnHost = "UNSUPPORTED_ON_HOST"
    case internalError = "INTERNAL_ERROR"
}

public struct GatewayInvocationRequest: Sendable, Equatable {
    public let method: String
    public let paramsJSON: String?

    public init(method: String, paramsJSON: String? = nil) {
        self.method = method
        self.paramsJSON = paramsJSON
    }
}

public struct GatewayHealthPayload: Codable, Sendable, Equatable {
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

public struct GatewayStatusPayload: Codable, Sendable, Equatable {
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

public struct GatewayFailurePayload: Codable, Sendable, Equatable {
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

    public func dispatch(
        _ request: GatewayRequestFrame,
        nowMs: Int64 = GatewayCore.currentTimestampMs()) -> GatewayResponseFrame
    {
        let invocation = GatewayInvocationRequest(
            method: request.method,
            paramsJSON: request.paramsJSON)
        let result = self.handle(invocation, nowMs: nowMs)
        return self.makeResponse(id: request.id, result: result)
    }

    private func makeResponse(id: String, result: GatewayInvocationResult) -> GatewayResponseFrame {
        switch result {
        case let .success(payload):
            return GatewayResponseFrame.success(id: id, payload: Self.encodePayload(payload))
        case let .failure(error):
            return GatewayResponseFrame.failure(id: id, code: error.code, message: error.message)
        }
    }

    private static func encodePayload(_ payload: GatewaySuccessPayload) -> GatewayJSONValue? {
        switch payload {
        case let .health(value):
            return self.encodeCodable(value)
        case let .status(value):
            return self.encodeCodable(value)
        }
    }

    private static func encodeCodable<T: Encodable>(_ value: T) -> GatewayJSONValue? {
        do {
            let data = try JSONEncoder().encode(value)
            return try JSONDecoder().decode(GatewayJSONValue.self, from: data)
        } catch {
            return nil
        }
    }
}
