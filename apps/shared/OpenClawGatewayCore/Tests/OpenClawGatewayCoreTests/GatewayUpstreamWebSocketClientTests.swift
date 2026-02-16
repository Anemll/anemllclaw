import XCTest
@testable import OpenClawGatewayCore

final class GatewayUpstreamWebSocketClientTests: XCTestCase {
    func testClientForwardsRequestThroughWebSocketGateway() async throws {
        let server = GatewayWebSocketServer(transport: MockUpstreamGatewayTransport())
        let port = try await server.start(port: 0)
        defer { Task { await server.stop() } }

        let client = GatewayUpstreamWebSocketClient(
            config: GatewayUpstreamWebSocketConfig(
                url: URL(string: "ws://127.0.0.1:\(port)")!,
                token: "secret-token"))

        let response = try await client.forward(
            GatewayRequestFrame(
                id: "req-chat-send",
                method: "chat.send",
                params: .object(["message": .string("hello")])))

        XCTAssertTrue(response.ok)
        XCTAssertEqual(response.id, "req-chat-send")
        XCTAssertEqual(response.payload?.objectValue?["status"]?.stringValue, "proxied")
        await client.disconnect()
    }

    func testClientFailsWhenConnectAuthRejected() async throws {
        let server = GatewayWebSocketServer(transport: MockUpstreamGatewayTransport())
        let port = try await server.start(port: 0)
        defer { Task { await server.stop() } }

        let client = GatewayUpstreamWebSocketClient(
            config: GatewayUpstreamWebSocketConfig(
                url: URL(string: "ws://127.0.0.1:\(port)")!,
                token: "wrong-token"))

        do {
            _ = try await client.forward(
                GatewayRequestFrame(
                    id: "req-chat-send",
                    method: "chat.send",
                    params: .object(["message": .string("hello")])))
            XCTFail("Expected auth rejection from upstream connect")
        } catch {
            // Expected
        }
        await client.disconnect()
    }
}

private actor MockUpstreamGatewayTransport: GatewayRPCTransport {
    private let core: GatewayCore

    init() {
        self.core = GatewayCore(
            startedAtMs: 1_700_000_000_000,
            authConfig: .token("secret-token"))
    }

    func send(_ request: GatewayRequestFrame, nowMs: Int64) async throws -> GatewayResponseFrame {
        switch request.method {
        case "chat.send":
            return GatewayResponseFrame.success(
                id: request.id,
                payload: .object([
                    "status": .string("proxied"),
                ]))
        default:
            return self.core.dispatch(request, nowMs: nowMs)
        }
    }
}
