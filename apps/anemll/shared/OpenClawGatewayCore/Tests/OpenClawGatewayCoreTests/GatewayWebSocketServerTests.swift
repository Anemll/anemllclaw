import Foundation
import XCTest
@testable import OpenClawGatewayCore

final class GatewayWebSocketServerTests: XCTestCase {
    func testServerSendsConnectChallengeOnAccept() async throws {
        let server = GatewayWebSocketServer(
            transport: GatewayLoopbackTransport(
                core: GatewayCore(startedAtMs: 1_700_000_000_000)))
        let port = try await server.start(port: 0)
        defer { Task { await server.stop() } }

        let (session, task) = try Self.makeWebSocketTask(port: port)
        defer {
            task.cancel(with: .goingAway, reason: nil)
            session.invalidateAndCancel()
        }

        let event = try await Self.waitForEvent(task: task, named: "connect.challenge")
        XCTAssertEqual(event.type, "event")
        XCTAssertEqual(event.event, "connect.challenge")
        XCTAssertFalse(event.payload?.objectValue?["nonce"]?.stringValue?.isEmpty ?? true)
    }

    func testServerRequiresConnectBeforeRequests() async throws {
        let server = GatewayWebSocketServer(
            transport: GatewayLoopbackTransport(
                core: GatewayCore(startedAtMs: 1_700_000_000_000)))
        let port = try await server.start(port: 0)
        defer { Task { await server.stop() } }

        let (session, task) = try Self.makeWebSocketTask(port: port)
        defer {
            task.cancel(with: .goingAway, reason: nil)
            session.invalidateAndCancel()
        }

        _ = try await Self.waitForEvent(task: task, named: "connect.challenge")

        let healthRequest = GatewayRequestFrame(id: "req-health", method: "health")
        try await Self.send(task: task, frame: healthRequest)
        let response = try await Self.waitForResponse(task: task, requestID: healthRequest.id)

        XCTAssertFalse(response.ok)
        XCTAssertEqual(response.error?.code, GatewayCoreErrorCode.authRequired.rawValue)
        XCTAssertEqual(response.error?.message, "connect required before invoking health")
    }

    func testServerConnectAndHealthRoundTrip() async throws {
        let server = GatewayWebSocketServer(
            transport: GatewayLoopbackTransport(
                core: GatewayCore(startedAtMs: 1_700_000_000_000)))
        let port = try await server.start(port: 0)
        defer { Task { await server.stop() } }

        let (session, task) = try Self.makeWebSocketTask(port: port)
        defer {
            task.cancel(with: .goingAway, reason: nil)
            session.invalidateAndCancel()
        }

        _ = try await Self.waitForEvent(task: task, named: "connect.challenge")

        let connectRequest = Self.makeConnectRequest(id: "req-connect")
        try await Self.send(task: task, frame: connectRequest)

        let connectResponse = try await Self.waitForResponse(task: task, requestID: connectRequest.id)
        XCTAssertTrue(connectResponse.ok)
        let hello = try Self.decodePayload(connectResponse.payload, as: GatewayHelloPayload.self)
        XCTAssertEqual(hello?.type, "hello-ok")
        XCTAssertEqual(hello?.protocolVersion, GatewayCore.defaultProtocolVersion)
        XCTAssertEqual(hello?.policy.tickIntervalMs, GatewayCore.defaultTickIntervalMs)

        let healthRequest = GatewayRequestFrame(id: "req-health", method: "health")
        try await Self.send(task: task, frame: healthRequest)

        let healthResponse = try await Self.waitForResponse(task: task, requestID: healthRequest.id)
        XCTAssertTrue(healthResponse.ok)
        XCTAssertEqual(healthResponse.id, healthRequest.id)
    }

    func testServerEmitsTickAfterSuccessfulConnect() async throws {
        let server = GatewayWebSocketServer(
            transport: GatewayLoopbackTransport(
                core: GatewayCore(startedAtMs: 1_700_000_000_000)),
            tickIntervalMs: 50)
        let port = try await server.start(port: 0)
        defer { Task { await server.stop() } }

        let (session, task) = try Self.makeWebSocketTask(port: port)
        defer {
            task.cancel(with: .goingAway, reason: nil)
            session.invalidateAndCancel()
        }

        _ = try await Self.waitForEvent(task: task, named: "connect.challenge")

        let connectRequest = Self.makeConnectRequest(id: "req-connect")
        try await Self.send(task: task, frame: connectRequest)
        _ = try await Self.waitForResponse(task: task, requestID: connectRequest.id)

        let tick = try await Self.waitForEvent(task: task, named: "tick")
        XCTAssertEqual(tick.event, "tick")
        XCTAssertNotNil(tick.seq)
    }

    func testServerEnforcesConnectAuthFromCore() async throws {
        let core = GatewayCore(
            startedAtMs: 1_700_000_000_000,
            authConfig: .token("secret-token"))
        let server = GatewayWebSocketServer(
            transport: GatewayLoopbackTransport(core: core))
        let port = try await server.start(port: 0)
        defer { Task { await server.stop() } }

        let (session, task) = try Self.makeWebSocketTask(port: port)
        defer {
            task.cancel(with: .goingAway, reason: nil)
            session.invalidateAndCancel()
        }

        _ = try await Self.waitForEvent(task: task, named: "connect.challenge")

        let missingAuth = Self.makeConnectRequest(id: "req-connect-no-auth")
        try await Self.send(task: task, frame: missingAuth)
        let missingAuthResponse = try await Self.waitForResponse(task: task, requestID: missingAuth.id)
        XCTAssertFalse(missingAuthResponse.ok)
        XCTAssertEqual(missingAuthResponse.error?.code, GatewayCoreErrorCode.authRequired.rawValue)

        let wrongAuth = Self.makeConnectRequest(
            id: "req-connect-bad-auth",
            auth: GatewayConnectAuth(token: "bad-token"))
        try await Self.send(task: task, frame: wrongAuth)
        let wrongAuthResponse = try await Self.waitForResponse(task: task, requestID: wrongAuth.id)
        XCTAssertFalse(wrongAuthResponse.ok)
        XCTAssertEqual(wrongAuthResponse.error?.code, GatewayCoreErrorCode.authFailed.rawValue)

        let correctAuth = Self.makeConnectRequest(
            id: "req-connect-good-auth",
            auth: GatewayConnectAuth(token: "secret-token"))
        try await Self.send(task: task, frame: correctAuth)
        let goodAuthResponse = try await Self.waitForResponse(task: task, requestID: correctAuth.id)
        XCTAssertTrue(goodAuthResponse.ok)
    }

    private static func makeWebSocketTask(
        port: UInt16) throws -> (session: URLSession, task: URLSessionWebSocketTask)
    {
        guard let url = URL(string: "ws://127.0.0.1:\(port)") else {
            throw URLError(.badURL)
        }
        let session = URLSession(configuration: .ephemeral)
        let task = session.webSocketTask(with: url)
        task.resume()
        return (session: session, task: task)
    }

    private static func send(task: URLSessionWebSocketTask, frame: GatewayRequestFrame) async throws {
        let data = try JSONEncoder().encode(frame)
        try await task.send(.data(data))
    }

    private static func waitForResponse(
        task: URLSessionWebSocketTask,
        requestID: String) async throws -> GatewayResponseFrame
    {
        while true {
            let message = try await self.receiveMessage(task: task)
            guard let data = self.messageData(message) else { continue }
            if let response = try? JSONDecoder().decode(GatewayResponseFrame.self, from: data),
               response.type == "res"
            {
                if response.id == requestID {
                    return response
                }
                continue
            }
        }
    }

    private static func waitForEvent(
        task: URLSessionWebSocketTask,
        named eventName: String) async throws -> GatewayEventFrame
    {
        while true {
            let message = try await self.receiveMessage(task: task)
            guard let data = self.messageData(message) else { continue }
            if let event = try? JSONDecoder().decode(GatewayEventFrame.self, from: data),
               event.type == "event",
               event.event == eventName
            {
                return event
            }
        }
    }

    private static func receiveMessage(
        task: URLSessionWebSocketTask,
        timeoutMs: UInt64 = 4_000) async throws -> URLSessionWebSocketTask.Message
    {
        try await withThrowingTaskGroup(of: URLSessionWebSocketTask.Message.self) { group in
            group.addTask { try await task.receive() }
            group.addTask {
                try await Task.sleep(nanoseconds: timeoutMs * 1_000_000)
                throw URLError(.timedOut)
            }

            guard let first = try await group.next() else {
                throw URLError(.cannotParseResponse)
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

    private static func makeConnectRequest(
        id: String,
        auth: GatewayConnectAuth? = nil) -> GatewayRequestFrame
    {
        var object: [String: GatewayJSONValue] = [
            "minProtocol": .integer(Int64(GatewayCore.defaultProtocolVersion)),
            "maxProtocol": .integer(Int64(GatewayCore.defaultProtocolVersion)),
            "client": .object([
                "id": .string("openclaw.test.ws"),
                "version": .string("0.0.0-test"),
                "platform": .string("tvOS"),
                "mode": .string("ios"),
            ]),
        ]
        if let auth {
            var authObject: [String: GatewayJSONValue] = [:]
            if let token = auth.token {
                authObject["token"] = .string(token)
            }
            if let password = auth.password {
                authObject["password"] = .string(password)
            }
            object["auth"] = .object(authObject)
        }
        return GatewayRequestFrame(
            id: id,
            method: "connect",
            params: .object(object))
    }

    private static func decodePayload<T: Decodable>(
        _ payload: GatewayJSONValue?,
        as type: T.Type) throws -> T?
    {
        guard let payload else { return nil }
        let data = try JSONEncoder().encode(payload)
        return try JSONDecoder().decode(type, from: data)
    }
}
