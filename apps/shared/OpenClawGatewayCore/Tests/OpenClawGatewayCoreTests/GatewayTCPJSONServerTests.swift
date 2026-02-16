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
