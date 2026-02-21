import Foundation

public struct GatewayUpstreamWebSocketConfig: Sendable, Equatable {
    public let url: URL
    public let token: String?
    public let password: String?
    public let role: String?
    public let scopes: [String]?
    public let clientID: String
    public let clientDisplayName: String?
    public let clientVersion: String
    public let clientPlatform: String
    public let clientMode: String
    public let requestTimeoutMs: UInt64

    public init(
        url: URL,
        token: String? = nil,
        password: String? = nil,
        role: String? = "node",
        scopes: [String]? = nil,
        clientID: String = "openclaw.tvos.gateway-core",
        clientDisplayName: String? = "OpenClaw tvOS Gateway",
        clientVersion: String = "0.0.0-dev",
        clientPlatform: String = "tvOS",
        clientMode: String = "gateway-host",
        requestTimeoutMs: UInt64 = 15000)
    {
        self.url = url
        self.token = token
        self.password = password
        self.role = role
        self.scopes = scopes
        self.clientID = clientID
        self.clientDisplayName = clientDisplayName
        self.clientVersion = clientVersion
        self.clientPlatform = clientPlatform
        self.clientMode = clientMode
        self.requestTimeoutMs = max(1000, requestTimeoutMs)
    }
}

public enum GatewayUpstreamWebSocketClientError: Error, Sendable, Equatable {
    case invalidURLScheme(String)
    case socketUnavailable
    case connectFailed(String)
    case timeout
}

public protocol GatewayUpstreamForwarding: Sendable {
    func forward(_ request: GatewayRequestFrame) async throws -> GatewayResponseFrame
}

public actor GatewayUpstreamWebSocketClient: GatewayUpstreamForwarding {
    private let config: GatewayUpstreamWebSocketConfig
    private let decoder = JSONDecoder()
    private let encoder = JSONEncoder()

    private var session: URLSession?
    private var task: URLSessionWebSocketTask?
    private var didConnect = false

    public init(config: GatewayUpstreamWebSocketConfig) {
        self.config = config
    }

    public func forward(_ request: GatewayRequestFrame) async throws -> GatewayResponseFrame {
        try await self.ensureConnected()

        do {
            try await self.sendFrame(request)
            return try await self.waitForResponse(requestID: request.id)
        } catch {
            self.disconnect()
            throw error
        }
    }

    public func probeHealth() async throws -> GatewayResponseFrame {
        try await self.forward(
            GatewayRequestFrame(
                id: UUID().uuidString,
                method: "health"))
    }

    public func disconnect() {
        self.task?.cancel(with: .goingAway, reason: nil)
        self.task = nil
        self.didConnect = false

        self.session?.invalidateAndCancel()
        self.session = nil
    }

    private func ensureConnected() async throws {
        if self.didConnect, self.task != nil {
            return
        }

        let scheme = self.config.url.scheme?.lowercased() ?? ""
        guard scheme == "ws" || scheme == "wss" else {
            throw GatewayUpstreamWebSocketClientError.invalidURLScheme(scheme)
        }

        self.disconnect()

        let session = URLSession(configuration: .ephemeral)
        let task = session.webSocketTask(with: self.config.url)
        task.resume()

        self.session = session
        self.task = task

        do {
            try await self.performConnectHandshake()
            self.didConnect = true
        } catch {
            self.disconnect()
            throw error
        }
    }

    private func performConnectHandshake() async throws {
        guard let task = self.task else {
            throw GatewayUpstreamWebSocketClientError.socketUnavailable
        }

        let connectRequest = self.makeConnectRequest()
        let data = try self.encoder.encode(connectRequest)
        try await task.send(.data(data))

        let connectResponse = try await self.waitForResponse(requestID: connectRequest.id)
        guard connectResponse.ok else {
            let message = connectResponse.error?.message ?? "upstream connect failed"
            throw GatewayUpstreamWebSocketClientError.connectFailed(message)
        }
    }

    private func sendFrame(_ frame: GatewayRequestFrame) async throws {
        guard let task = self.task else {
            throw GatewayUpstreamWebSocketClientError.socketUnavailable
        }
        let data = try self.encoder.encode(frame)
        try await task.send(.data(data))
    }

    private func waitForResponse(requestID: String) async throws -> GatewayResponseFrame {
        guard let task = self.task else {
            throw GatewayUpstreamWebSocketClientError.socketUnavailable
        }

        while true {
            let message = try await self.receiveMessage(task: task)
            guard let data = Self.messageData(message) else { continue }

            if let response = try? self.decoder.decode(GatewayResponseFrame.self, from: data),
               response.type == "res"
            {
                if response.id == requestID {
                    return response
                }
                continue
            }

            // Ignore event and non-response frames while waiting for the matching request id.
            continue
        }
    }

    private func receiveMessage(task: URLSessionWebSocketTask) async throws -> URLSessionWebSocketTask.Message {
        try await withThrowingTaskGroup(of: URLSessionWebSocketTask.Message.self) { group in
            group.addTask { try await task.receive() }
            group.addTask {
                try await Task.sleep(nanoseconds: self.config.requestTimeoutMs * 1_000_000)
                throw GatewayUpstreamWebSocketClientError.timeout
            }

            guard let first = try await group.next() else {
                throw GatewayUpstreamWebSocketClientError.socketUnavailable
            }
            group.cancelAll()
            return first
        }
    }

    private static func messageData(_ message: URLSessionWebSocketTask.Message) -> Data? {
        switch message {
        case let .data(data):
            return data
        case let .string(text):
            return text.data(using: .utf8)
        @unknown default:
            return nil
        }
    }

    private func makeConnectRequest() -> GatewayRequestFrame {
        var params: [String: GatewayJSONValue] = [
            "minProtocol": .integer(Int64(GatewayCore.defaultProtocolVersion)),
            "maxProtocol": .integer(Int64(GatewayCore.defaultProtocolVersion)),
            "client": .object([
                "id": .string(self.config.clientID),
                "displayName": .string(self.config.clientDisplayName ?? self.config.clientID),
                "version": .string(self.config.clientVersion),
                "platform": .string(self.config.clientPlatform),
                "mode": .string(self.config.clientMode),
            ]),
        ]

        if let role = self.config.role?.trimmingCharacters(in: .whitespacesAndNewlines), !role.isEmpty {
            params["role"] = .string(role)
        }
        if let scopes = self.config.scopes, !scopes.isEmpty {
            params["scopes"] = .array(scopes.map { .string($0) })
        }

        var auth: [String: GatewayJSONValue] = [:]
        if let token = self.config.token?.trimmingCharacters(in: .whitespacesAndNewlines), !token.isEmpty {
            auth["token"] = .string(token)
        }
        if let password = self.config.password?.trimmingCharacters(in: .whitespacesAndNewlines), !password.isEmpty {
            auth["password"] = .string(password)
        }
        if !auth.isEmpty {
            params["auth"] = .object(auth)
        }

        return GatewayRequestFrame(
            id: UUID().uuidString,
            method: "connect",
            params: .object(params))
    }
}
