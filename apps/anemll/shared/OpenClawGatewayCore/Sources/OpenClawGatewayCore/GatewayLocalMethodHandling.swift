import Foundation

public protocol GatewayLocalMethodHandling: Sendable {
    /// Returns nil when the method should continue through the default core/upstream path.
    func handle(_ request: GatewayRequestFrame, nowMs: Int64) async -> GatewayResponseFrame?
}

enum GatewayPayloadCodec {
    private static let encoder = JSONEncoder()
    private static let decoder = JSONDecoder()

    static func decode<T: Decodable>(_ value: GatewayJSONValue?, as type: T.Type) -> T? {
        guard let value else { return nil }
        do {
            let data = try encoder.encode(value)
            return try self.decoder.decode(type, from: data)
        } catch {
            return nil
        }
    }

    static func encode(_ value: some Encodable) -> GatewayJSONValue? {
        do {
            let data = try encoder.encode(value)
            return try self.decoder.decode(GatewayJSONValue.self, from: data)
        } catch {
            return nil
        }
    }
}

enum GatewayRoutingPolicy {
    static let upstreamOnlyMethodPrefixes = [
        "sessions.",
        "channel.",
        "hooks.",
        "skills.",
        "voicewake.",
        "talk.",
        "node.invoke",
    ]

    static func requiresUpstream(_ method: String) -> Bool {
        self.upstreamOnlyMethodPrefixes.contains { method.hasPrefix($0) }
    }
}
