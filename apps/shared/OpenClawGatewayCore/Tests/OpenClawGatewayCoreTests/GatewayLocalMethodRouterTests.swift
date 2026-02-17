import Foundation
import XCTest
@testable import OpenClawGatewayCore

final class GatewayLocalMethodRouterTests: XCTestCase {
    private actor ConcurrencyTracker {
        private var active = 0
        private var maxActive = 0

        func begin() {
            self.active += 1
            self.maxActive = max(self.maxActive, self.active)
        }

        func end() {
            self.active -= 1
        }

        func observedMaxActive() -> Int {
            self.maxActive
        }
    }

    private actor StubLLMProvider: GatewayLocalLLMProvider {
        let kind: GatewayLocalLLMProviderKind = .openAICompatible
        let model: String = "stub-model"
        private var requestCount = 0

        func complete(_ request: GatewayLocalLLMRequest) async throws -> GatewayLocalLLMResponse {
            self.requestCount += 1
            let prompt = request.messages.last?.text ?? ""
            return GatewayLocalLLMResponse(
                text: "echo: \(prompt)",
                model: self.model,
                provider: self.kind,
                usageInputTokens: 8,
                usageOutputTokens: 4)
        }

        func observedRequestCount() -> Int {
            self.requestCount
        }
    }

    func testSessionOperationQueueSerializesConcurrentWork() async throws {
        let queue = GatewaySessionOperationQueue()
        let tracker = ConcurrencyTracker()

        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<25 {
                group.addTask {
                    _ = try await queue.enqueue {
                        await tracker.begin()
                        try await Task.sleep(nanoseconds: 5_000_000)
                        await tracker.end()
                        return true
                    }
                }
            }

            try await group.waitForAll()
        }

        let maxActive = await tracker.observedMaxActive()
        XCTAssertEqual(maxActive, 1)
    }

    func testSQLiteMemoryStorePersistsAndSearches() async throws {
        let dbPath = self.temporaryMemoryStorePath()

        let store = try GatewaySQLiteMemoryStore(path: dbPath)
        let userTurn = try await store.appendTurn(
            sessionKey: "alpha",
            role: "user",
            text: "hello from apple tv",
            timestampMs: 1_700_000_000_100,
            runID: "run-1")
        _ = try await store.appendTurn(
            sessionKey: "alpha",
            role: "assistant",
            text: "reply from local model",
            timestampMs: 1_700_000_000_200,
            runID: "run-1")

        let searchHits = try await store.search(query: "apple", sessionKey: "alpha", limit: 5)
        XCTAssertFalse(searchHits.isEmpty)
        XCTAssertEqual(searchHits.first?.turn.id, userTurn.id)

        let loadedTurn = try await store.getTurn(id: userTurn.id)
        XCTAssertEqual(loadedTurn?.text, "hello from apple tv")

        // Re-open the same sqlite file to confirm data survives store recreation.
        let reopenedStore = try GatewaySQLiteMemoryStore(path: dbPath)
        let history = try await reopenedStore.history(sessionKey: "alpha", limit: 10)
        XCTAssertEqual(history.count, 2)
        XCTAssertEqual(history.first?.role, "user")
        XCTAssertEqual(history.last?.role, "assistant")
    }

    func testLocalRouterHandlesChatAndHistoryWithLocalProvider() async throws {
        let dbPath = self.temporaryMemoryStorePath()
        let llmProvider = StubLLMProvider()
        let config = GatewayLocalMethodRouterConfig(
            hostLabel: "unit-test",
            upstreamConfigured: false,
            llmConfig: GatewayLocalLLMConfig(
                provider: .openAICompatible,
                baseURL: URL(string: "https://example.invalid"),
                apiKey: "test-key",
                model: "stub-model"),
            memoryStorePath: dbPath,
            enableLocalSafeTools: true)
        let router = try GatewayLocalMethodRouter(config: config, llmProvider: llmProvider)

        let chatSend = GatewayRequestFrame(
            id: "chat-1",
            method: "chat.send",
            params: .object([
                "sessionKey": .string("session-a"),
                "message": .string("hello"),
                "thinking": .string("low"),
            ]))
        let chatResponse = await router.handle(chatSend, nowMs: 1_700_000_001_000)
        XCTAssertEqual(chatResponse?.ok, true)
        XCTAssertEqual(chatResponse?.payload?.objectValue?["status"]?.stringValue, "completed")
        XCTAssertEqual(chatResponse?.payload?.objectValue?["source"]?.stringValue, "local")

        let historyRequest = GatewayRequestFrame(
            id: "history-1",
            method: "chat.history",
            params: .object([
                "sessionKey": .string("session-a"),
                "limit": .integer(10),
            ]))
        let historyResponse = await router.handle(historyRequest, nowMs: 1_700_000_001_050)
        XCTAssertEqual(historyResponse?.ok, true)

        let historyPayload = try self.decodePayload(
            historyResponse?.payload,
            as: ChatHistoryPayload.self)
        XCTAssertEqual(historyPayload?.sessionKey, "session-a")
        XCTAssertEqual(historyPayload?.messages.count, 2)
        XCTAssertEqual(historyPayload?.messages.first?.role, "user")
        XCTAssertEqual(historyPayload?.messages.last?.role, "assistant")
        XCTAssertEqual(historyPayload?.messages.last?.content.first?.text, "echo: hello")

        let providerCalls = await llmProvider.observedRequestCount()
        XCTAssertEqual(providerCalls, 1)
    }

    func testLocalRouterReturnsUpstreamRequiredForUnsafeNodeInvokeWithoutUpstream() async throws {
        let router = try GatewayLocalMethodRouter(
            config: GatewayLocalMethodRouterConfig(
                hostLabel: "unit-test",
                upstreamConfigured: false,
                llmConfig: GatewayLocalLLMConfig(provider: .disabled),
                memoryStorePath: self.temporaryMemoryStorePath(),
                enableLocalSafeTools: true))

        let request = GatewayRequestFrame(
            id: "unsafe-1",
            method: "node.invoke",
            params: .object([
                "command": .string("child_process.exec"),
                "params": .object([
                    "cmd": .string("ls"),
                ]),
            ]))

        let response = await router.handle(request, nowMs: 1_700_000_000_100)
        XCTAssertEqual(response?.ok, false)
        XCTAssertEqual(response?.error?.code, GatewayCoreErrorCode.upstreamRequired.rawValue)
    }

    func testCapabilitiesMapReflectsLocalAndPolicyState() async throws {
        let llmProvider = StubLLMProvider()
        let router = try GatewayLocalMethodRouter(
            config: GatewayLocalMethodRouterConfig(
                hostLabel: "unit-test",
                upstreamConfigured: false,
                llmConfig: GatewayLocalLLMConfig(
                    provider: .openAICompatible,
                    baseURL: URL(string: "https://example.invalid"),
                    apiKey: "test-key",
                    model: "stub-model"),
                memoryStorePath: self.temporaryMemoryStorePath(),
                enableLocalSafeTools: true),
            llmProvider: llmProvider)

        let request = GatewayRequestFrame(
            id: "caps-1",
            method: "capabilities.get")
        let response = await router.handle(request, nowMs: 1_700_000_000_100)

        XCTAssertEqual(response?.ok, true)
        let payload = try self.decodePayload(response?.payload, as: CapabilitiesPayload.self)
        XCTAssertEqual(payload?.host, "unit-test")
        XCTAssertEqual(payload?.llmConfigured, true)
        XCTAssertEqual(payload?.toolPolicy.localSafeCommands, ["time.now", "device.info", "network.fetch"])
        XCTAssertTrue(payload?.toolPolicy.upstreamOnlyPrefixRules.contains("node.invoke") == true)
        XCTAssertEqual(payload?.methods.first(where: { $0.method == "chat.send" })?.route, "local")
    }

    func testLoopbackTransportReturnsUpstreamRequiredWhenLocalAndUpstreamUnavailable() async throws {
        let router = try GatewayLocalMethodRouter(
            config: GatewayLocalMethodRouterConfig(
                hostLabel: "unit-test",
                upstreamConfigured: false,
                llmConfig: GatewayLocalLLMConfig(provider: .disabled),
                memoryStorePath: self.temporaryMemoryStorePath(),
                enableLocalSafeTools: true))
        let transport = GatewayLoopbackTransport(
            core: GatewayCore(startedAtMs: 1_700_000_000_000),
            upstream: nil,
            localMethods: router)

        let request = GatewayRequestFrame(
            id: "chat-upstream-required",
            method: "chat.send",
            params: .object([
                "sessionKey": .string("s1"),
                "message": .string("hello"),
            ]))
        let response = try await transport.send(request, nowMs: 1_700_000_000_100)

        XCTAssertFalse(response.ok)
        XCTAssertEqual(response.error?.code, GatewayCoreErrorCode.upstreamRequired.rawValue)
    }

    private func temporaryMemoryStorePath() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("openclaw-gateway-tests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("GatewayMemory.sqlite", isDirectory: false)
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

private struct ChatHistoryPayload: Decodable {
    let sessionKey: String
    let messages: [ChatHistoryMessage]
}

private struct ChatHistoryMessage: Decodable {
    let role: String
    let content: [ChatHistoryContent]
}

private struct ChatHistoryContent: Decodable {
    let type: String
    let text: String
}

private struct CapabilitiesPayload: Decodable {
    let host: String
    let llmConfigured: Bool
    let methods: [MethodCapability]
    let toolPolicy: ToolPolicy
}

private struct MethodCapability: Decodable {
    let method: String
    let route: String
    let details: String
}

private struct ToolPolicy: Decodable {
    let localSafeCommands: [String]
    let upstreamOnlyPrefixRules: [String]
}
