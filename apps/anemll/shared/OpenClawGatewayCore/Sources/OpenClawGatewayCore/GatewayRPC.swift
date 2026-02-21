import Foundation

public struct GatewayRequestFrame: Codable, Sendable, Equatable {
    public let type: String
    public let id: String
    public let method: String
    public let params: GatewayJSONValue?

    public init(
        id: String,
        method: String,
        params: GatewayJSONValue? = nil,
        type: String = "req")
    {
        self.type = type
        self.id = id
        self.method = method
        self.params = params
    }

    public var paramsJSON: String? {
        guard let params = self.params else { return nil }
        return try? params.jsonString()
    }
}

public struct GatewayTCPRequestEnvelope: Codable, Sendable, Equatable {
    public let request: GatewayRequestFrame
    public let auth: GatewayConnectAuth?

    public init(request: GatewayRequestFrame, auth: GatewayConnectAuth? = nil) {
        self.request = request
        self.auth = auth
    }
}

public struct GatewayErrorShape: Codable, Sendable, Equatable {
    public let code: String
    public let message: String

    public init(code: String, message: String) {
        self.code = code
        self.message = message
    }
}

public struct GatewayResponseFrame: Codable, Sendable, Equatable {
    public let type: String
    public let id: String
    public let ok: Bool
    public let payload: GatewayJSONValue?
    public let error: GatewayErrorShape?

    public init(
        id: String,
        ok: Bool,
        payload: GatewayJSONValue?,
        error: GatewayErrorShape?,
        type: String = "res")
    {
        self.type = type
        self.id = id
        self.ok = ok
        self.payload = payload
        self.error = error
    }

    public static func success(id: String, payload: GatewayJSONValue?) -> GatewayResponseFrame {
        GatewayResponseFrame(id: id, ok: true, payload: payload, error: nil)
    }

    public static func failure(
        id: String,
        code: GatewayCoreErrorCode,
        message: String) -> GatewayResponseFrame
    {
        GatewayResponseFrame(
            id: id,
            ok: false,
            payload: nil,
            error: GatewayErrorShape(code: code.rawValue, message: message))
    }
}

public struct GatewayEventFrame: Codable, Sendable, Equatable {
    public let type: String
    public let event: String
    public let payload: GatewayJSONValue?
    public let seq: Int?
    public let stateVersion: GatewayJSONValue?

    public init(
        event: String,
        payload: GatewayJSONValue? = nil,
        seq: Int? = nil,
        stateVersion: GatewayJSONValue? = nil,
        type: String = "event")
    {
        self.type = type
        self.event = event
        self.payload = payload
        self.seq = seq
        self.stateVersion = stateVersion
    }

    private enum CodingKeys: String, CodingKey {
        case type
        case event
        case payload
        case seq
        case stateVersion
    }
}
