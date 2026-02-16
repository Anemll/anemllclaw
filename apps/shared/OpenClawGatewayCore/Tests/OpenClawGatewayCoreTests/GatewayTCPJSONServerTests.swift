import Foundation
import Network
import XCTest
@testable import OpenClawGatewayCore

final class GatewayTCPJSONServerTests: XCTestCase {
    func testServerRespondsToHealthRequest() async throws {
        let server = GatewayTCPJSONServer(
            transport: GatewayLoopbackTransport(
                core: GatewayCore(startedAtMs: 1_700_000_000_000)))
        let port = try await server.start(port: 0)
        defer { Task { await server.stop() } }

        let response = try await Self.sendAndReceive(
            port: port,
            payload: Self.encodeLine(
                GatewayRequestFrame(id: "req-health", method: "health")))

        XCTAssertEqual(response.type, "res")
        XCTAssertEqual(response.id, "req-health")
        XCTAssertTrue(response.ok)
        XCTAssertNil(response.error)
        let payload = response.payload?.objectValue
        XCTAssertEqual(payload?["ok"]?.boolValue, true)
    }

    func testServerRejectsInvalidJSONRequest() async throws {
        let server = GatewayTCPJSONServer(
            transport: GatewayLoopbackTransport(
                core: GatewayCore(startedAtMs: 1_700_000_000_000)))
        let port = try await server.start(port: 0)
        defer { Task { await server.stop() } }

        let invalidLine = Data(#"{"type":"req","id":"bad","method":"health""#.utf8) + Data([0x0A])
        let response = try await Self.sendAndReceive(port: port, payload: invalidLine)

        XCTAssertEqual(response.type, "res")
        XCTAssertEqual(response.id, "invalid")
        XCTAssertFalse(response.ok)
        XCTAssertEqual(response.error?.code, GatewayCoreErrorCode.invalidRequest.rawValue)
        XCTAssertEqual(response.error?.message, "invalid request frame")
    }

    func testServerRequiresAuthWhenConfigured() async throws {
        let server = GatewayTCPJSONServer(
            transport: GatewayLoopbackTransport(
                core: GatewayCore(startedAtMs: 1_700_000_000_000)),
            authConfig: .token("secret-token"))
        let port = try await server.start(port: 0)
        defer { Task { await server.stop() } }

        let response = try await Self.sendAndReceive(
            port: port,
            payload: Self.encodeLine(
                GatewayRequestFrame(id: "req-health-no-auth", method: "health")))

        XCTAssertFalse(response.ok)
        XCTAssertEqual(response.id, "req-health-no-auth")
        XCTAssertEqual(response.error?.code, GatewayCoreErrorCode.authRequired.rawValue)
        XCTAssertEqual(response.error?.message, "tcp auth token required")
    }

    func testServerRejectsMismatchedAuthToken() async throws {
        let server = GatewayTCPJSONServer(
            transport: GatewayLoopbackTransport(
                core: GatewayCore(startedAtMs: 1_700_000_000_000)),
            authConfig: .token("secret-token"))
        let port = try await server.start(port: 0)
        defer { Task { await server.stop() } }

        let envelope = GatewayTCPRequestEnvelope(
            request: GatewayRequestFrame(id: "req-health-bad-auth", method: "health"),
            auth: GatewayConnectAuth(token: "wrong-token"))
        let response = try await Self.sendAndReceive(
            port: port,
            payload: Self.encodeLine(envelope))

        XCTAssertFalse(response.ok)
        XCTAssertEqual(response.id, "req-health-bad-auth")
        XCTAssertEqual(response.error?.code, GatewayCoreErrorCode.authFailed.rawValue)
        XCTAssertEqual(response.error?.message, "tcp auth token mismatch")
    }

    func testServerAcceptsMatchingAuthToken() async throws {
        let server = GatewayTCPJSONServer(
            transport: GatewayLoopbackTransport(
                core: GatewayCore(startedAtMs: 1_700_000_000_000)),
            authConfig: .token("secret-token"))
        let port = try await server.start(port: 0)
        defer { Task { await server.stop() } }

        let envelope = GatewayTCPRequestEnvelope(
            request: GatewayRequestFrame(id: "req-health-good-auth", method: "health"),
            auth: GatewayConnectAuth(token: "secret-token"))
        let response = try await Self.sendAndReceive(
            port: port,
            payload: Self.encodeLine(envelope))

        XCTAssertTrue(response.ok)
        XCTAssertEqual(response.id, "req-health-good-auth")
        let payload = response.payload?.objectValue
        XCTAssertEqual(payload?["ok"]?.boolValue, true)
    }

    func testServerAcceptsMatchingAuthPassword() async throws {
        let server = GatewayTCPJSONServer(
            transport: GatewayLoopbackTransport(
                core: GatewayCore(startedAtMs: 1_700_000_000_000)),
            authConfig: .password("secret-password"))
        let port = try await server.start(port: 0)
        defer { Task { await server.stop() } }

        let envelope = GatewayTCPRequestEnvelope(
            request: GatewayRequestFrame(id: "req-health-good-password", method: "health"),
            auth: GatewayConnectAuth(password: "secret-password"))
        let response = try await Self.sendAndReceive(
            port: port,
            payload: Self.encodeLine(envelope))

        XCTAssertTrue(response.ok)
        XCTAssertEqual(response.id, "req-health-good-password")
        let payload = response.payload?.objectValue
        XCTAssertEqual(payload?["ok"]?.boolValue, true)
    }

    private static func sendAndReceive(
        port: UInt16,
        payload: Data) async throws -> GatewayResponseFrame
    {
        let connection = NWConnection(
            host: NWEndpoint.Host("127.0.0.1"),
            port: NWEndpoint.Port(rawValue: port) ?? .any,
            using: .tcp)
        let queue = DispatchQueue(label: "ai.openclaw.gatewaycore.tcp-test.\(UUID().uuidString)")
        connection.start(queue: queue)

        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: payload, completion: .contentProcessed { error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                continuation.resume()
            })
        }

        let responseData = try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Data, Error>) in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 1_048_576) {
                data,
                _,
                _,
                error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                continuation.resume(returning: data ?? Data())
            }
        }
        connection.cancel()

        let line = responseData.split(separator: 0x0A, maxSplits: 1, omittingEmptySubsequences: true).first
        let frameData = Data(line ?? responseData[...])
        return try JSONDecoder().decode(GatewayResponseFrame.self, from: frameData)
    }

    private static func encodeLine<T: Encodable>(_ value: T) throws -> Data {
        var data = try JSONEncoder().encode(value)
        data.append(0x0A)
        return data
    }
}
