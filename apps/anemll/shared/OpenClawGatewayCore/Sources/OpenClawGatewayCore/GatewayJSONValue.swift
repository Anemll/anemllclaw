import Foundation

public enum GatewayJSONValue: Codable, Sendable, Equatable {
    case null
    case bool(Bool)
    case integer(Int64)
    case double(Double)
    case string(String)
    case array([GatewayJSONValue])
    case object([String: GatewayJSONValue])

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
            return
        }
        if let value = try? container.decode(Bool.self) {
            self = .bool(value)
            return
        }
        if let value = try? container.decode(Int64.self) {
            self = .integer(value)
            return
        }
        if let value = try? container.decode(Double.self) {
            self = .double(value)
            return
        }
        if let value = try? container.decode(String.self) {
            self = .string(value)
            return
        }
        if let value = try? container.decode([GatewayJSONValue].self) {
            self = .array(value)
            return
        }
        if let value = try? container.decode([String: GatewayJSONValue].self) {
            self = .object(value)
            return
        }
        throw DecodingError.dataCorruptedError(
            in: container,
            debugDescription: "Unsupported JSON value.")
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null:
            try container.encodeNil()
        case let .bool(value):
            try container.encode(value)
        case let .integer(value):
            try container.encode(value)
        case let .double(value):
            try container.encode(value)
        case let .string(value):
            try container.encode(value)
        case let .array(value):
            try container.encode(value)
        case let .object(value):
            try container.encode(value)
        }
    }

    public var boolValue: Bool? {
        guard case let .bool(value) = self else { return nil }
        return value
    }

    public var int64Value: Int64? {
        switch self {
        case let .integer(value):
            return value
        case let .double(value):
            guard value.isFinite, value.rounded() == value else { return nil }
            return Int64(value)
        default:
            return nil
        }
    }

    public var stringValue: String? {
        guard case let .string(value) = self else { return nil }
        return value
    }

    public var objectValue: [String: GatewayJSONValue]? {
        guard case let .object(value) = self else { return nil }
        return value
    }

    public var foundationJSONValue: Any {
        switch self {
        case .null:
            NSNull()
        case let .bool(value):
            value
        case let .integer(value):
            value
        case let .double(value):
            value
        case let .string(value):
            value
        case let .array(value):
            value.map(\.foundationJSONValue)
        case let .object(value):
            value.mapValues(\.foundationJSONValue)
        }
    }

    public var foundationJSONObjectValue: [String: Any]? {
        guard case let .object(value) = self else { return nil }
        return value.mapValues(\.foundationJSONValue)
    }

    public func jsonString() throws -> String {
        let data = try JSONEncoder().encode(self)
        guard let text = String(data: data, encoding: .utf8) else {
            throw GatewayJSONValueError.invalidUTF8
        }
        return text
    }
}

public enum GatewayJSONValueError: Error, Sendable {
    case invalidUTF8
}
