import Foundation
import Network

public enum GatewayTCPJSONServerError: Error, Sendable, Equatable {
    case alreadyRunning
    case missingBoundPort
}

public actor GatewayTCPJSONServer {
    private let transport: any GatewayRPCTransport
    private let authConfig: GatewayCoreAuthConfig
    private let queue = DispatchQueue(label: "ai.openclaw.gatewaycore.tcp-server")
    private let decoder = JSONDecoder()
    private let encoder = JSONEncoder()

    private var listener: NWListener?
    private var boundPort: UInt16?
    private var connections: [ObjectIdentifier: NWConnection] = [:]
    private var buffers: [ObjectIdentifier: Data] = [:]

    public init(
        transport: any GatewayRPCTransport = GatewayLoopbackTransport(),
        authConfig: GatewayCoreAuthConfig = .none)
    {
        self.transport = transport
        self.authConfig = authConfig
    }

    public func start(port: UInt16 = 0, localhostOnly: Bool = true) async throws -> UInt16 {
        guard self.listener == nil else {
            throw GatewayTCPJSONServerError.alreadyRunning
        }

        let parameters: NWParameters = .tcp
        if localhostOnly {
            parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: .ipv4(.loopback), port: .any)
        }

        let nwPort = NWEndpoint.Port(rawValue: port) ?? .any
        let listener = try NWListener(using: parameters, on: nwPort)
        listener.newConnectionHandler = { connection in
            Task { await self.accept(connection) }
        }

        let resolvedPort: UInt16 = try await withCheckedThrowingContinuation { continuation in
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    listener.stateUpdateHandler = nil
                    guard let resolved = listener.port?.rawValue else {
                        continuation.resume(throwing: GatewayTCPJSONServerError.missingBoundPort)
                        return
                    }
                    continuation.resume(returning: resolved)
                case let .failed(error):
                    listener.stateUpdateHandler = nil
                    continuation.resume(throwing: error)
                default:
                    break
                }
            }
            listener.start(queue: self.queue)
        }

        self.listener = listener
        self.boundPort = resolvedPort
        return resolvedPort
    }

    public func stop() {
        self.listener?.cancel()
        self.listener = nil
        self.boundPort = nil

        for connection in self.connections.values {
            connection.cancel()
        }
        self.connections.removeAll()
        self.buffers.removeAll()
    }

    public func currentPort() -> UInt16? {
        self.boundPort
    }

    private func accept(_ connection: NWConnection) {
        let id = ObjectIdentifier(connection)
        self.connections[id] = connection
        self.buffers[id] = Data()

        connection.stateUpdateHandler = { state in
            switch state {
            case .cancelled:
                Task { await self.removeConnection(id) }
            case .failed:
                Task { await self.removeConnection(id) }
            default:
                break
            }
        }
        connection.start(queue: self.queue)
        self.receive(on: connection, id: id)
    }

    private func receive(on connection: NWConnection, id: ObjectIdentifier) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1_048_576) {
            data,
                _,
                isComplete,
                error in
            Task {
                await self.handleReceive(
                    on: connection,
                    id: id,
                    data: data,
                    isComplete: isComplete,
                    error: error)
            }
        }
    }

    private func handleReceive(
        on connection: NWConnection,
        id: ObjectIdentifier,
        data: Data?,
        isComplete: Bool,
        error: NWError?)
    {
        guard self.connections[id] != nil else { return }

        if let data, !data.isEmpty {
            var buffer = self.buffers[id] ?? Data()
            buffer.append(data)
            self.buffers[id] = buffer
        }

        guard error == nil else {
            connection.cancel()
            self.removeConnection(id)
            return
        }

        guard let frameData = self.extractFrameData(connectionId: id, isComplete: isComplete) else {
            if isComplete {
                connection.cancel()
                self.removeConnection(id)
                return
            }
            self.receive(on: connection, id: id)
            return
        }

        Task {
            let response = await self.processRequestFrame(frameData)
            self.sendResponse(on: connection, id: id, response: response)
        }
    }

    private func processRequestFrame(_ frameData: Data) async -> GatewayResponseFrame {
        guard let parsed = self.parseRequestFrame(frameData) else {
            let fallbackID = Self.extractRequestID(frameData) ?? "invalid"
            return GatewayResponseFrame.failure(
                id: fallbackID,
                code: .invalidRequest,
                message: "invalid request frame")
        }

        let request = parsed.request
        if let authFailure = Self.validateAuth(self.authConfig, provided: parsed.auth) {
            return GatewayResponseFrame.failure(
                id: request.id,
                code: authFailure.code,
                message: authFailure.message)
        }

        do {
            return try await self.transport.send(request)
        } catch {
            return GatewayResponseFrame.failure(
                id: request.id,
                code: .internalError,
                message: "transport error: \(error.localizedDescription)")
        }
    }

    private func parseRequestFrame(
        _ frameData: Data) -> (request: GatewayRequestFrame, auth: GatewayConnectAuth?)?
    {
        if let envelope = try? self.decoder.decode(GatewayTCPRequestEnvelope.self, from: frameData) {
            return (request: envelope.request, auth: envelope.auth)
        }
        if let request = try? self.decoder.decode(GatewayRequestFrame.self, from: frameData) {
            return (request: request, auth: nil)
        }
        return nil
    }

    private static func validateAuth(
        _ config: GatewayCoreAuthConfig,
        provided auth: GatewayConnectAuth?) -> GatewayFailurePayload?
    {
        switch config.mode {
        case .none:
            return nil
        case .token:
            guard let expected = config.token, !expected.isEmpty else {
                return GatewayFailurePayload(
                    code: .internalError,
                    message: "tcp auth config missing token")
            }
            guard let provided = auth?.token, !provided.isEmpty else {
                return GatewayFailurePayload(
                    code: .authRequired,
                    message: "tcp auth token required")
            }
            guard provided == expected else {
                return GatewayFailurePayload(
                    code: .authFailed,
                    message: "tcp auth token mismatch")
            }
            return nil
        case .password:
            guard let expected = config.password, !expected.isEmpty else {
                return GatewayFailurePayload(
                    code: .internalError,
                    message: "tcp auth config missing password")
            }
            guard let provided = auth?.password, !provided.isEmpty else {
                return GatewayFailurePayload(
                    code: .authRequired,
                    message: "tcp auth password required")
            }
            guard provided == expected else {
                return GatewayFailurePayload(
                    code: .authFailed,
                    message: "tcp auth password mismatch")
            }
            return nil
        }
    }

    private func sendResponse(
        on connection: NWConnection,
        id: ObjectIdentifier,
        response: GatewayResponseFrame)
    {
        guard var data = try? self.encoder.encode(response) else {
            connection.cancel()
            self.removeConnection(id)
            return
        }
        data.append(0x0A)

        connection.send(content: data, completion: .contentProcessed { _ in
            connection.cancel()
            Task { await self.removeConnection(id) }
        })
    }

    private func extractFrameData(connectionId: ObjectIdentifier, isComplete: Bool) -> Data? {
        guard var buffer = self.buffers[connectionId] else { return nil }
        if let newlineIndex = buffer.firstIndex(of: 0x0A) {
            let line = Data(buffer[..<newlineIndex])
            buffer.removeSubrange(...newlineIndex)
            self.buffers[connectionId] = buffer
            return line
        }
        if isComplete, !buffer.isEmpty {
            self.buffers[connectionId] = Data()
            return buffer
        }
        return nil
    }

    private func removeConnection(_ id: ObjectIdentifier) {
        self.connections[id] = nil
        self.buffers[id] = nil
    }

    private static func extractRequestID(_ frameData: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: frameData),
              let dict = object as? [String: Any]
        else { return nil }
        if let directID = dict["id"] as? String {
            return directID
        }
        if let request = dict["request"] as? [String: Any] {
            return request["id"] as? String
        }
        return nil
    }
}
