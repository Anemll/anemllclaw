import Foundation

public enum GatewayCoreErrorCode: String, Codable, Sendable, Equatable {
    case authRequired = "AUTH_REQUIRED"
    case authFailed = "AUTH_FAILED"
    case invalidRequest = "INVALID_REQUEST"
    case methodNotFound = "METHOD_NOT_FOUND"
    case unsupportedOnHost = "UNSUPPORTED_ON_HOST"
    case upstreamRequired = "UPSTREAM_REQUIRED"
    case internalError = "INTERNAL_ERROR"
}

public enum GatewayCoreAuthMode: String, Codable, Sendable, Equatable {
    case none
    case token
    case password
}

public struct GatewayCoreAuthConfig: Codable, Sendable, Equatable {
    public let mode: GatewayCoreAuthMode
    public let token: String?
    public let password: String?

    public init(mode: GatewayCoreAuthMode, token: String? = nil, password: String? = nil) {
        self.mode = mode
        self.token = token
        self.password = password
    }

    public static let none = GatewayCoreAuthConfig(mode: .none)

    public static func token(_ token: String) -> GatewayCoreAuthConfig {
        GatewayCoreAuthConfig(mode: .token, token: token)
    }

    public static func password(_ password: String) -> GatewayCoreAuthConfig {
        GatewayCoreAuthConfig(mode: .password, password: password)
    }
}

public struct GatewayConnectAuth: Codable, Sendable, Equatable {
    public let token: String?
    public let password: String?

    public init(token: String? = nil, password: String? = nil) {
        self.token = token
        self.password = password
    }
}

public struct GatewayConnectClient: Codable, Sendable, Equatable {
    public let id: String
    public let displayName: String?
    public let version: String
    public let platform: String
    public let mode: String

    public init(
        id: String,
        displayName: String? = nil,
        version: String,
        platform: String,
        mode: String)
    {
        self.id = id
        self.displayName = displayName
        self.version = version
        self.platform = platform
        self.mode = mode
    }
}

public struct GatewayConnectParams: Codable, Sendable, Equatable {
    public let minProtocol: Int
    public let maxProtocol: Int
    public let client: GatewayConnectClient
    public let auth: GatewayConnectAuth?
    public let role: String?
    public let scopes: [String]?

    public init(
        minProtocol: Int,
        maxProtocol: Int,
        client: GatewayConnectClient,
        auth: GatewayConnectAuth? = nil,
        role: String? = nil,
        scopes: [String]? = nil)
    {
        self.minProtocol = minProtocol
        self.maxProtocol = maxProtocol
        self.client = client
        self.auth = auth
        self.role = role
        self.scopes = scopes
    }
}

public struct GatewayHelloServer: Codable, Sendable, Equatable {
    public let version: String
    public let connId: String
    public let host: String?

    public init(version: String, connId: String, host: String? = nil) {
        self.version = version
        self.connId = connId
        self.host = host
    }
}

public struct GatewayHelloFeatures: Codable, Sendable, Equatable {
    public let methods: [String]
    public let events: [String]

    public init(methods: [String], events: [String]) {
        self.methods = methods
        self.events = events
    }
}

public struct GatewayHelloStateVersion: Codable, Sendable, Equatable {
    public let presence: Int
    public let health: Int

    public init(presence: Int, health: Int) {
        self.presence = presence
        self.health = health
    }
}

public struct GatewayHelloSnapshot: Codable, Sendable, Equatable {
    public let presence: [GatewayJSONValue]
    public let health: GatewayJSONValue
    public let stateVersion: GatewayHelloStateVersion
    public let uptimeMs: Int
    public let configPath: String?
    public let stateDir: String?
    public let sessionDefaults: [String: GatewayJSONValue]?
    public let authMode: GatewayJSONValue?

    public init(
        presence: [GatewayJSONValue],
        health: GatewayJSONValue,
        stateVersion: GatewayHelloStateVersion,
        uptimeMs: Int,
        configPath: String? = nil,
        stateDir: String? = nil,
        sessionDefaults: [String: GatewayJSONValue]? = nil,
        authMode: GatewayJSONValue? = nil)
    {
        self.presence = presence
        self.health = health
        self.stateVersion = stateVersion
        self.uptimeMs = uptimeMs
        self.configPath = configPath
        self.stateDir = stateDir
        self.sessionDefaults = sessionDefaults
        self.authMode = authMode
    }
}

public struct GatewayHelloPolicy: Codable, Sendable, Equatable {
    public let maxPayload: Int
    public let maxBufferedBytes: Int
    public let tickIntervalMs: Int

    public init(maxPayload: Int, maxBufferedBytes: Int, tickIntervalMs: Int) {
        self.maxPayload = maxPayload
        self.maxBufferedBytes = maxBufferedBytes
        self.tickIntervalMs = tickIntervalMs
    }
}

public struct GatewayHelloPayload: Codable, Sendable, Equatable {
    public let type: String
    public let protocolVersion: Int
    public let server: GatewayHelloServer
    public let features: GatewayHelloFeatures
    public let snapshot: GatewayHelloSnapshot
    public let canvasHostURL: String?
    public let auth: [String: GatewayJSONValue]?
    public let policy: GatewayHelloPolicy

    public init(
        type: String = "hello-ok",
        protocolVersion: Int,
        server: GatewayHelloServer,
        features: GatewayHelloFeatures,
        snapshot: GatewayHelloSnapshot,
        canvasHostURL: String? = nil,
        auth: [String: GatewayJSONValue]? = nil,
        policy: GatewayHelloPolicy)
    {
        self.type = type
        self.protocolVersion = protocolVersion
        self.server = server
        self.features = features
        self.snapshot = snapshot
        self.canvasHostURL = canvasHostURL
        self.auth = auth
        self.policy = policy
    }

    private enum CodingKeys: String, CodingKey {
        case type
        case protocolVersion = "protocol"
        case server
        case features
        case snapshot
        case canvasHostURL = "canvasHostUrl"
        case auth
        case policy
    }
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
    case hello(GatewayHelloPayload)
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
    public static let defaultProtocolVersion = 3
    public static let defaultTickIntervalMs = 30000

    private static let defaultMethods = ["connect", "health", "status"]
    private static let defaultEvents = ["connect.challenge", "tick"]

    private static let unsupportedMethodPrefixes = [
        "chat.",
        "sessions.",
        "agents.",
        "config.",
        "voicewake.",
        "talk.",
        "node.invoke",
        "channel.",
        "hooks.",
    ]

    private let startedAtMs: Int64
    private let protocolVersion: Int
    private let serverVersion: String
    private let authConfig: GatewayCoreAuthConfig

    public init(
        startedAtMs: Int64 = GatewayCore.currentTimestampMs(),
        protocolVersion: Int = GatewayCore.defaultProtocolVersion,
        serverVersion: String = "openclaw-gateway-core-swift-dev",
        authConfig: GatewayCoreAuthConfig = .none)
    {
        self.startedAtMs = startedAtMs
        self.protocolVersion = max(1, protocolVersion)
        self.serverVersion = serverVersion
        self.authConfig = authConfig
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
            if Self.isUnsupportedOnHostMethod(request.method) {
                return .failure(
                    GatewayFailurePayload(
                        code: .unsupportedOnHost,
                        message: "unsupported on tvOS host: \(request.method)"))
            }
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
        if request.method == "connect" {
            return self.makeResponse(id: request.id, result: self.handleConnect(request, nowMs: nowMs))
        }
        let invocation = GatewayInvocationRequest(
            method: request.method,
            paramsJSON: request.paramsJSON)
        let result = self.handle(invocation, nowMs: nowMs)
        return self.makeResponse(id: request.id, result: result)
    }

    private func handleConnect(_ request: GatewayRequestFrame, nowMs: Int64) -> GatewayInvocationResult {
        guard let params = self.decodeConnectParams(request.params) else {
            return .failure(
                GatewayFailurePayload(
                    code: .invalidRequest,
                    message: "invalid connect params"))
        }
        guard params.maxProtocol >= self.protocolVersion, params.minProtocol <= self.protocolVersion else {
            return .failure(
                GatewayFailurePayload(
                    code: .invalidRequest,
                    message: "protocol mismatch"))
        }
        if let authError = self.validateConnectAuth(params.auth) {
            return .failure(authError)
        }

        let uptimeMs = max(0, nowMs - self.startedAtMs)
        let healthSnapshot: GatewayJSONValue = .object([
            "ok": .bool(true),
            "ts": .integer(nowMs),
            "uptimeMs": .integer(uptimeMs),
            "durationMs": .integer(0),
        ])

        return .success(
            .hello(
                GatewayHelloPayload(
                    protocolVersion: self.protocolVersion,
                    server: GatewayHelloServer(
                        version: self.serverVersion,
                        connId: "loopback-\(request.id)",
                        host: "tvos-local"),
                    features: GatewayHelloFeatures(
                        methods: GatewayCore.defaultMethods,
                        events: GatewayCore.defaultEvents),
                    snapshot: GatewayHelloSnapshot(
                        presence: [],
                        health: healthSnapshot,
                        stateVersion: GatewayHelloStateVersion(presence: 1, health: 1),
                        uptimeMs: Self.clampedInt(uptimeMs),
                        sessionDefaults: [
                            "model": .string("tvos-local"),
                            "contextTokens": .integer(0),
                        ],
                        authMode: .string(self.authConfig.mode.rawValue)),
                    policy: GatewayHelloPolicy(
                        maxPayload: 1_048_576,
                        maxBufferedBytes: 4_194_304,
                        tickIntervalMs: GatewayCore.defaultTickIntervalMs))))
    }

    private func decodeConnectParams(_ params: GatewayJSONValue?) -> GatewayConnectParams? {
        guard let params else { return nil }
        do {
            let data = try JSONEncoder().encode(params)
            return try JSONDecoder().decode(GatewayConnectParams.self, from: data)
        } catch {
            return nil
        }
    }

    private func validateConnectAuth(_ auth: GatewayConnectAuth?) -> GatewayFailurePayload? {
        switch self.authConfig.mode {
        case .none:
            return nil
        case .token:
            guard let expected = self.authConfig.token, !expected.isEmpty else {
                return GatewayFailurePayload(
                    code: .internalError,
                    message: "gateway auth config missing token")
            }
            guard let provided = auth?.token, !provided.isEmpty else {
                return GatewayFailurePayload(
                    code: .authRequired,
                    message: "connect auth token required")
            }
            guard provided == expected else {
                return GatewayFailurePayload(
                    code: .authFailed,
                    message: "connect auth token mismatch")
            }
            return nil
        case .password:
            guard let expected = self.authConfig.password, !expected.isEmpty else {
                return GatewayFailurePayload(
                    code: .internalError,
                    message: "gateway auth config missing password")
            }
            guard let provided = auth?.password, !provided.isEmpty else {
                return GatewayFailurePayload(
                    code: .authRequired,
                    message: "connect auth password required")
            }
            guard provided == expected else {
                return GatewayFailurePayload(
                    code: .authFailed,
                    message: "connect auth password mismatch")
            }
            return nil
        }
    }

    private func makeResponse(id: String, result: GatewayInvocationResult) -> GatewayResponseFrame {
        switch result {
        case let .success(payload):
            GatewayResponseFrame.success(id: id, payload: Self.encodePayload(payload))
        case let .failure(error):
            GatewayResponseFrame.failure(id: id, code: error.code, message: error.message)
        }
    }

    private static func encodePayload(_ payload: GatewaySuccessPayload) -> GatewayJSONValue? {
        switch payload {
        case let .hello(value):
            self.encodeCodable(value)
        case let .health(value):
            self.encodeCodable(value)
        case let .status(value):
            self.encodeCodable(value)
        }
    }

    private static func encodeCodable(_ value: some Encodable) -> GatewayJSONValue? {
        do {
            let data = try JSONEncoder().encode(value)
            return try JSONDecoder().decode(GatewayJSONValue.self, from: data)
        } catch {
            return nil
        }
    }

    private static func isUnsupportedOnHostMethod(_ method: String) -> Bool {
        self.unsupportedMethodPrefixes.contains { method.hasPrefix($0) }
    }

    private static func clampedInt(_ value: Int64) -> Int {
        if value <= Int64(Int.min) {
            return Int.min
        }
        if value >= Int64(Int.max) {
            return Int.max
        }
        return Int(value)
    }
}
