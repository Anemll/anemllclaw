import Foundation
import Network

public enum GatewayTCPJSONServerError: Error, Sendable, Equatable {
    case alreadyRunning
    case missingBoundPort
}

public actor GatewayTCPJSONServer {
    private let transport: any GatewayRPCTransport
    private let queue = DispatchQueue(label: "ai.openclaw.gatewaycore.tcp-server")
    private let decoder = JSONDecoder()
    private let encoder = JSONEncoder()

    private var listener: NWListener?
    private var boundPort: UInt16?
    private var connections: [ObjectIdentifier: NWConnection] = [:]
    private var buffers: [ObjectIdentifier: Data] = [:]

    public init(transport: any GatewayRPCTransport = GatewayLoopbackTransport()) {
        self.transport = transport
    }

    public func start(port: UInt16 = 0) async throws -> UInt16 {
        guard self.listener == nil else {
            throw GatewayTCPJSONServerError.alreadyRunning
        }

        let nwPort = NWEndpoint.Port(rawValue: port) ?? .any
        let listener = try NWListener(using: .tcp, on: nwPort)
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
        if let request = try? self.decoder.decode(GatewayRequestFrame.self, from: frameData) {
            do {
                return try await self.transport.send(request)
            } catch {
                return GatewayResponseFrame.failure(
                    id: request.id,
                    code: .internalError,
                    message: "transport error: \(error.localizedDescription)")
            }
        }

        let fallbackID = Self.extractRequestID(frameData) ?? "invalid"
        return GatewayResponseFrame.failure(
            id: fallbackID,
            code: .invalidRequest,
            message: "invalid request frame")
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
        return dict["id"] as? String
    }
}
