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

    func testDispatchHealthResponseEnvelopeIsStable() {
        let startedAtMs: Int64 = 1_700_000_000_000
        let nowMs: Int64 = 1_700_000_000_250
        let core = GatewayCore(startedAtMs: startedAtMs)
        let request = GatewayRequestFrame(id: "req-health", method: "health")

        let response = core.dispatch(request, nowMs: nowMs)

        XCTAssertEqual(response.type, "res")
        XCTAssertEqual(response.id, "req-health")
        XCTAssertTrue(response.ok)
        XCTAssertNil(response.error)
        guard let payloadObject = response.payload?.objectValue else {
            XCTFail("Expected health payload object")
            return
        }
        XCTAssertEqual(payloadObject["ok"]?.boolValue, true)
        XCTAssertEqual(payloadObject["ts"]?.int64Value, nowMs)
        XCTAssertEqual(payloadObject["uptimeMs"]?.int64Value, 250)
    }

    func testDispatchUnknownMethodReturnsErrorEnvelope() {
        let core = GatewayCore(startedAtMs: 1_700_000_000_000)
        let response = core.dispatch(
            GatewayRequestFrame(
                id: "req-unknown",
                method: "__gateway_core_contract_unknown_method__"),
            nowMs: 1_700_000_000_100)

        XCTAssertEqual(response.type, "res")
        XCTAssertEqual(response.id, "req-unknown")
        XCTAssertFalse(response.ok)
        XCTAssertNil(response.payload)
        XCTAssertEqual(response.error?.code, GatewayCoreErrorCode.methodNotFound.rawValue)
        XCTAssertEqual(
            response.error?.message,
            "unknown method: __gateway_core_contract_unknown_method__")
    }

    func testLoopbackHostRequiresRunningState() async throws {
        let host = GatewayLoopbackHost(
            transport: GatewayLoopbackTransport(
                core: GatewayCore(startedAtMs: 1_700_000_000_000)))
        let request = GatewayRequestFrame(id: "req-health", method: "health")

        do {
            _ = try await host.invoke(request, nowMs: 1_700_000_000_050)
            XCTFail("Expected invocation to fail while host is stopped")
        } catch let error as GatewayLoopbackHostError {
            XCTAssertEqual(error, .notRunning)
        } catch {
            XCTFail("Expected GatewayLoopbackHostError.notRunning, got \(error)")
        }

        await host.start()
        let response = try await host.invoke(request, nowMs: 1_700_000_000_100)
        XCTAssertTrue(response.ok)
        XCTAssertEqual(response.id, "req-health")
    }

    func testLoopbackTransportJSONRoundTrip() async throws {
        let transport = GatewayLoopbackTransport(
            core: GatewayCore(startedAtMs: 1_700_000_000_000))
        let requestJSON = #"{"type":"req","id":"req-status","method":"status"}"#
        let requestData = Data(requestJSON.utf8)

        let responseData = try await transport.sendJSON(
            requestData,
            nowMs: 1_700_000_000_100)
        let response = try JSONDecoder().decode(GatewayResponseFrame.self, from: responseData)

        XCTAssertEqual(response.type, "res")
        XCTAssertEqual(response.id, "req-status")
        XCTAssertTrue(response.ok)
        XCTAssertNil(response.error)
        guard let payloadObject = response.payload?.objectValue else {
            XCTFail("Expected status payload object")
            return
        }
        XCTAssertEqual(payloadObject["heartbeatDefaultAgentId"]?.stringValue, "main")
    }
}
