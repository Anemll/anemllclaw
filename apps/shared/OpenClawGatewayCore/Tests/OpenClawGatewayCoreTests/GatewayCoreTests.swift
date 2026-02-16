import XCTest
@testable import OpenClawGatewayCore

final class GatewayCoreTests: XCTestCase {
    func testHealthHandlerReturnsStablePayload() {
        let startedAtMs: Int64 = 1_700_000_000_000
        let nowMs: Int64 = 1_700_000_000_250
        let core = GatewayCore(startedAtMs: startedAtMs)

        let result = core.handle(
            GatewayInvocationRequest(method: "health"),
            nowMs: nowMs)

        guard case let .success(.health(payload)) = result else {
            XCTFail("Expected health success payload")
            return
        }

        XCTAssertTrue(payload.ok)
        XCTAssertEqual(payload.ts, nowMs)
        XCTAssertEqual(payload.uptimeMs, 250)
        XCTAssertEqual(payload.durationMs, 0)
    }

    func testUnknownMethodReturnsMethodNotFound() {
        let core = GatewayCore(startedAtMs: 1_700_000_000_000)
        let result = core.handle(
            GatewayInvocationRequest(method: "__gateway_core_contract_unknown_method__"),
            nowMs: 1_700_000_000_100)

        guard case let .failure(error) = result else {
            XCTFail("Expected method-not-found failure")
            return
        }

        XCTAssertEqual(error.code, .methodNotFound)
        XCTAssertEqual(error.message, "unknown method: __gateway_core_contract_unknown_method__")
    }

    func testStatusHandlerReturnsStablePayload() {
        let core = GatewayCore(startedAtMs: 1_700_000_000_000)
        let result = core.handle(
            GatewayInvocationRequest(method: "status"),
            nowMs: 1_700_000_000_100)

        guard case let .success(.status(payload)) = result else {
            XCTFail("Expected status success payload")
            return
        }

        XCTAssertEqual(payload.heartbeatDefaultAgentId, "main")
        XCTAssertEqual(payload.sessionCount, 0)
    }
}
