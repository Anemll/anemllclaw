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

    func testNodeOnlyMethodReturnsUnsupportedOnHost() {
        let core = GatewayCore(startedAtMs: 1_700_000_000_000)
        let result = core.handle(
            GatewayInvocationRequest(method: "chat.send"),
            nowMs: 1_700_000_000_100)

        guard case let .failure(error) = result else {
            XCTFail("Expected unsupported-on-host failure")
            return
        }

        XCTAssertEqual(error.code, .unsupportedOnHost)
        XCTAssertEqual(error.message, "unsupported on tvOS host: chat.send")
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

    func testConnectHandshakeReturnsHelloPayload() throws {
        let core = GatewayCore(startedAtMs: 1_700_000_000_000)
        let response = core.dispatch(
            self.makeConnectRequest(id: "req-connect"),
            nowMs: 1_700_000_000_500)

        XCTAssertTrue(response.ok)
        XCTAssertNil(response.error)
        let hello = try self.decodePayload(response.payload, as: GatewayHelloPayload.self)
        XCTAssertEqual(hello?.type, "hello-ok")
        XCTAssertEqual(hello?.protocolVersion, GatewayCore.defaultProtocolVersion)
        XCTAssertTrue(hello?.features.methods.contains("connect") == true)
        XCTAssertTrue(hello?.features.methods.contains("health") == true)
        XCTAssertTrue(hello?.features.events.contains("tick") == true)
        XCTAssertEqual(hello?.snapshot.stateVersion.health, 1)
        XCTAssertEqual(hello?.snapshot.stateVersion.presence, 1)
        XCTAssertEqual(hello?.snapshot.uptimeMs, 500)
        XCTAssertEqual(hello?.snapshot.presence.count, 0)
        XCTAssertEqual(hello?.policy.tickIntervalMs, GatewayCore.defaultTickIntervalMs)
    }

    func testConnectHandshakeRejectsProtocolMismatch() {
        let core = GatewayCore(startedAtMs: 1_700_000_000_000)
        let response = core.dispatch(
            self.makeConnectRequest(
                id: "req-connect-mismatch",
                minProtocol: GatewayCore.defaultProtocolVersion + 1,
                maxProtocol: GatewayCore.defaultProtocolVersion + 1),
            nowMs: 1_700_000_000_500)

        XCTAssertFalse(response.ok)
        XCTAssertEqual(response.error?.code, GatewayCoreErrorCode.invalidRequest.rawValue)
        XCTAssertEqual(response.error?.message, "protocol mismatch")
    }

    func testConnectHandshakeRequiresTokenWhenConfigured() {
        let core = GatewayCore(
            startedAtMs: 1_700_000_000_000,
            authConfig: .token("secret-token"))

        let missingAuth = core.dispatch(
            self.makeConnectRequest(id: "req-connect-no-auth"),
            nowMs: 1_700_000_000_500)
        XCTAssertFalse(missingAuth.ok)
        XCTAssertEqual(missingAuth.error?.code, GatewayCoreErrorCode.authRequired.rawValue)

        let wrongToken = core.dispatch(
            self.makeConnectRequest(
                id: "req-connect-wrong-auth",
                auth: GatewayConnectAuth(token: "wrong-token")),
            nowMs: 1_700_000_000_500)
        XCTAssertFalse(wrongToken.ok)
        XCTAssertEqual(wrongToken.error?.code, GatewayCoreErrorCode.authFailed.rawValue)

        let correctToken = core.dispatch(
            self.makeConnectRequest(
                id: "req-connect-correct-auth",
                auth: GatewayConnectAuth(token: "secret-token")),
            nowMs: 1_700_000_000_500)
        XCTAssertTrue(correctToken.ok)
        XCTAssertNil(correctToken.error)
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

    func testLoopbackTransportDelegatesUnsupportedMethodToUpstream() async throws {
        let upstream = TestUpstreamForwarder(
            response: .success(
                id: "req-chat-send",
                payload: .object([
                    "status": .string("proxied"),
                ])))
        let transport = GatewayLoopbackTransport(
            core: GatewayCore(startedAtMs: 1_700_000_000_000),
            upstream: upstream)

        let response = try await transport.send(
            GatewayRequestFrame(id: "req-chat-send", method: "chat.send"),
            nowMs: 1_700_000_000_100)

        XCTAssertTrue(response.ok)
        XCTAssertEqual(response.id, "req-chat-send")
        XCTAssertEqual(response.payload?.objectValue?["status"]?.stringValue, "proxied")
        let forwarded = await upstream.forwardedRequestIDs()
        XCTAssertEqual(forwarded, ["req-chat-send"])
    }

    func testLoopbackTransportDelegatesMethodNotFoundToUpstream() async throws {
        let upstream = TestUpstreamForwarder(
            response: .success(
                id: "req-custom-method",
                payload: .object([
                    "status": .string("proxied"),
                    "method": .string("custom.experimental"),
                ])))
        let transport = GatewayLoopbackTransport(
            core: GatewayCore(startedAtMs: 1_700_000_000_000),
            upstream: upstream)

        let response = try await transport.send(
            GatewayRequestFrame(id: "req-custom-method", method: "custom.experimental"),
            nowMs: 1_700_000_000_100)

        XCTAssertTrue(response.ok)
        XCTAssertEqual(response.id, "req-custom-method")
        XCTAssertEqual(response.payload?.objectValue?["status"]?.stringValue, "proxied")
        XCTAssertEqual(response.payload?.objectValue?["method"]?.stringValue, "custom.experimental")
        let forwarded = await upstream.forwardedRequestIDs()
        XCTAssertEqual(forwarded, ["req-custom-method"])
    }

    func testLoopbackTransportKeepsMethodNotFoundWithoutUpstream() async throws {
        let transport = GatewayLoopbackTransport(
            core: GatewayCore(startedAtMs: 1_700_000_000_000))

        let response = try await transport.send(
            GatewayRequestFrame(id: "req-custom-method-local", method: "custom.experimental"),
            nowMs: 1_700_000_000_100)

        XCTAssertFalse(response.ok)
        XCTAssertEqual(response.error?.code, GatewayCoreErrorCode.methodNotFound.rawValue)
        XCTAssertEqual(response.error?.message, "unknown method: custom.experimental")
    }

    func testLoopbackTransportReturnsInternalErrorWhenUpstreamFails() async throws {
        let upstream = TestUpstreamForwarder(errorMessage: "upstream offline")
        let transport = GatewayLoopbackTransport(
            core: GatewayCore(startedAtMs: 1_700_000_000_000),
            upstream: upstream)

        let response = try await transport.send(
            GatewayRequestFrame(id: "req-chat-send", method: "chat.send"),
            nowMs: 1_700_000_000_100)

        XCTAssertFalse(response.ok)
        XCTAssertEqual(response.error?.code, GatewayCoreErrorCode.internalError.rawValue)
        XCTAssertEqual(response.error?.message, "upstream forwarding failed: upstream offline")
    }

    private func makeConnectRequest(
        id: String,
        minProtocol: Int = GatewayCore.defaultProtocolVersion,
        maxProtocol: Int = GatewayCore.defaultProtocolVersion,
        auth: GatewayConnectAuth? = nil) -> GatewayRequestFrame
    {
        var object: [String: GatewayJSONValue] = [
            "minProtocol": .integer(Int64(minProtocol)),
            "maxProtocol": .integer(Int64(maxProtocol)),
            "client": .object([
                "id": .string("openclaw.test"),
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

    private func decodePayload<T: Decodable>(
        _ payload: GatewayJSONValue?,
        as type: T.Type) throws -> T?
    {
        guard let payload else { return nil }
        let data = try JSONEncoder().encode(payload)
        return try JSONDecoder().decode(type, from: data)
    }
}

private actor TestUpstreamForwarder: GatewayUpstreamForwarding {
    private let response: GatewayResponseFrame?
    private let errorMessage: String?
    private var forwardedIDs: [String] = []

    init(response: GatewayResponseFrame? = nil, errorMessage: String? = nil) {
        self.response = response
        self.errorMessage = errorMessage
    }

    func forward(_ request: GatewayRequestFrame) async throws -> GatewayResponseFrame {
        self.forwardedIDs.append(request.id)
        if let errorMessage = self.errorMessage {
            throw NSError(
                domain: "GatewayCoreTests",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: errorMessage])
        }
        if let response = self.response {
            return response
        }
        return GatewayResponseFrame.success(id: request.id, payload: nil)
    }

    func forwardedRequestIDs() -> [String] {
        self.forwardedIDs
    }
}
