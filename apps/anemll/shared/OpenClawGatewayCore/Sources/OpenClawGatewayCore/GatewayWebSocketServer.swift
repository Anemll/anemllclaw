import Foundation
import Network

public enum GatewayWebSocketServerError: Error, Sendable, Equatable {
    case alreadyRunning
    case missingBoundPort
}

public actor GatewayWebSocketServer {
    private struct ConnectionState: Sendable {
        var didConnect = false
        var sequence = 0
    }

    private let transport: any GatewayRPCTransport
    private let queue = DispatchQueue(label: "ai.openclaw.gatewaycore.ws-server")
    private let decoder = JSONDecoder()
    private let encoder = JSONEncoder()
    private let tickIntervalMs: Int

    private var listener: NWListener?
    private var boundPort: UInt16?
    private var connections: [ObjectIdentifier: NWConnection] = [:]
    private var states: [ObjectIdentifier: ConnectionState] = [:]
    private var tickTasks: [ObjectIdentifier: Task<Void, Never>] = [:]

    public init(
        transport: any GatewayRPCTransport = GatewayLoopbackTransport(),
        tickIntervalMs: Int = GatewayCore.defaultTickIntervalMs)
    {
        self.transport = transport
        self.tickIntervalMs = max(250, tickIntervalMs)
    }

    public func start(port: UInt16 = 0, localhostOnly: Bool = true) async throws -> UInt16 {
        guard self.listener == nil else {
            throw GatewayWebSocketServerError.alreadyRunning
        }

        let tcpOptions = NWProtocolTCP.Options()
        let wsOptions = NWProtocolWebSocket.Options()
        wsOptions.autoReplyPing = true
        wsOptions.maximumMessageSize = 16 * 1024 * 1024

        let parameters = NWParameters(tls: nil, tcp: tcpOptions)
        parameters.defaultProtocolStack.applicationProtocols.insert(wsOptions, at: 0)
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
                        continuation.resume(throwing: GatewayWebSocketServerError.missingBoundPort)
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

        for task in self.tickTasks.values {
            task.cancel()
        }
        self.tickTasks.removeAll()

        for connection in self.connections.values {
            connection.cancel()
        }
        self.connections.removeAll()
        self.states.removeAll()
    }

    public func currentPort() -> UInt16? {
        self.boundPort
    }

    private func accept(_ connection: NWConnection) {
        let id = ObjectIdentifier(connection)
        self.connections[id] = connection
        self.states[id] = ConnectionState()

        connection.stateUpdateHandler = { state in
            switch state {
            case .cancelled, .failed:
                Task { await self.removeConnection(id) }
            default:
                break
            }
        }

        connection.start(queue: self.queue)
        self.sendConnectChallenge(on: connection, id: id)
        self.receive(on: connection, id: id)
    }

    private func receive(on connection: NWConnection, id: ObjectIdentifier) {
        connection.receiveMessage { data, _, isComplete, error in
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
        error: NWError?) async
    {
        guard self.connections[id] != nil else { return }

        if error != nil {
            connection.cancel()
            self.removeConnection(id)
            return
        }

        guard let data, !data.isEmpty else {
            if isComplete {
                connection.cancel()
                self.removeConnection(id)
                return
            }
            self.receive(on: connection, id: id)
            return
        }

        let response = await self.processRequestFrame(data, connectionId: id)
        self.sendResponse(on: connection, id: id, response: response)
        self.receiveIfActive(on: connection, id: id)
    }

    private func processRequestFrame(
        _ frameData: Data,
        connectionId: ObjectIdentifier) async -> GatewayResponseFrame
    {
        guard let request = try? self.decoder.decode(GatewayRequestFrame.self, from: frameData) else {
            let fallbackID = Self.extractRequestID(frameData) ?? "invalid"
            return GatewayResponseFrame.failure(
                id: fallbackID,
                code: .invalidRequest,
                message: "invalid request frame")
        }

        let state = self.states[connectionId] ?? ConnectionState()
        if request.method != "connect", !state.didConnect {
            return GatewayResponseFrame.failure(
                id: request.id,
                code: .authRequired,
                message: "connect required before invoking \(request.method)")
        }

        do {
            let response = try await self.transport.send(request)
            if request.method == "connect", response.ok {
                var next = state
                let didConnectAlready = next.didConnect
                next.didConnect = true
                self.states[connectionId] = next
                if !didConnectAlready {
                    self.startTickLoop(connectionId: connectionId)
                }
            }
            return response
        } catch {
            return GatewayResponseFrame.failure(
                id: request.id,
                code: .internalError,
                message: "transport error: \(error.localizedDescription)")
        }
    }

    private func sendConnectChallenge(on connection: NWConnection, id: ObjectIdentifier) {
        let event = GatewayEventFrame(
            event: "connect.challenge",
            payload: .object([
                "nonce": .string(UUID().uuidString),
            ]))
        self.sendEvent(on: connection, id: id, event: event)
    }

    private func startTickLoop(connectionId: ObjectIdentifier) {
        self.tickTasks[connectionId]?.cancel()
        let intervalMs = self.tickIntervalMs
        self.tickTasks[connectionId] = Task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(intervalMs) * 1_000_000)
                await self.sendTick(connectionId: connectionId)
            }
        }
    }

    private func sendTick(connectionId: ObjectIdentifier) async {
        guard let connection = self.connections[connectionId] else { return }
        guard var state = self.states[connectionId], state.didConnect else { return }

        state.sequence += 1
        self.states[connectionId] = state

        let event = GatewayEventFrame(
            event: "tick",
            payload: .object([
                "ts": .integer(GatewayCore.currentTimestampMs()),
            ]),
            seq: state.sequence,
            stateVersion: .object([
                "presence": .integer(1),
                "health": .integer(1),
            ]))
        self.sendEvent(on: connection, id: connectionId, event: event)
    }

    private func sendResponse(
        on connection: NWConnection,
        id: ObjectIdentifier,
        response: GatewayResponseFrame)
    {
        guard let data = try? self.encoder.encode(response) else {
            connection.cancel()
            self.removeConnection(id)
            return
        }
        self.sendWebSocketJSON(on: connection, id: id, data: data)
    }

    private func sendEvent(
        on connection: NWConnection,
        id: ObjectIdentifier,
        event: GatewayEventFrame)
    {
        guard let data = try? self.encoder.encode(event) else {
            connection.cancel()
            self.removeConnection(id)
            return
        }
        self.sendWebSocketJSON(on: connection, id: id, data: data)
    }

    private func sendWebSocketJSON(on connection: NWConnection, id: ObjectIdentifier, data: Data) {
        let metadata = NWProtocolWebSocket.Metadata(opcode: .text)
        let context = NWConnection.ContentContext(
            identifier: "gateway-ws-json",
            metadata: [metadata])

        connection.send(
            content: data,
            contentContext: context,
            isComplete: true,
            completion: .contentProcessed { error in
                guard error != nil else { return }
                connection.cancel()
                Task { await self.removeConnection(id) }
            })
    }

    private func receiveIfActive(on connection: NWConnection, id: ObjectIdentifier) {
        guard self.connections[id] != nil else { return }
        self.receive(on: connection, id: id)
    }

    private func removeConnection(_ id: ObjectIdentifier) {
        self.tickTasks[id]?.cancel()
        self.tickTasks[id] = nil
        self.connections[id] = nil
        self.states[id] = nil
    }

    private static func extractRequestID(_ frameData: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: frameData),
              let dict = object as? [String: Any],
              let id = dict["id"] as? String
        else { return nil }
        return id
    }
}
