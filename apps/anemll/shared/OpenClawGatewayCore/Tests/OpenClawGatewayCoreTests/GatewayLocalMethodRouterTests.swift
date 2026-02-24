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
        private var lastThinking: String?
        private var lastSystemPrompt: String?
        private var lastMessageTexts: [String] = []

        func complete(_ request: GatewayLocalLLMRequest) async throws -> GatewayLocalLLMResponse {
            self.requestCount += 1
            self.lastThinking = request.thinkingLevel
            self.lastSystemPrompt = request.systemPrompt
            self.lastMessageTexts = request.messages.map(\.text)
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

        func observedLastThinkingLevel() -> String? {
            self.lastThinking
        }

        func observedLastSystemPrompt() -> String? {
            self.lastSystemPrompt
        }

        func observedLastMessageTexts() -> [String] {
            self.lastMessageTexts
        }
    }

    private actor DelayedLLMProvider: GatewayLocalLLMProvider {
        let kind: GatewayLocalLLMProviderKind = .openAICompatible
        let model: String = "stub-delayed-model"

        private var requestCount = 0
        private let delayNs: UInt64
        private let concurrencyProbe: ConcurrencyProbe

        init(delayMs: UInt64, concurrencyProbe: ConcurrencyProbe) {
            self.delayNs = delayMs * 1_000_000
            self.concurrencyProbe = concurrencyProbe
        }

        func complete(_ request: GatewayLocalLLMRequest) async throws -> GatewayLocalLLMResponse {
            self.requestCount += 1
            await self.concurrencyProbe.beginStep()
            defer { Task { await self.concurrencyProbe.endStep() } }
            if self.delayNs > 0 {
                try await Task.sleep(nanoseconds: self.delayNs)
            }
            let requestIndex = self.requestCount
            return GatewayLocalLLMResponse(
                text: "agent-response-\(requestIndex)",
                model: self.model,
                provider: self.kind,
                usageInputTokens: 4,
                usageOutputTokens: 4)
        }

        func observedRequestCount() -> Int {
            self.requestCount
        }
    }

    private actor ToolCallingLLMProvider: GatewayLocalLLMToolCallableProvider {
        let kind: GatewayLocalLLMProviderKind = .openAICompatible
        let model: String = "tool-caller"
        private var callCount = 0

        func complete(_ request: GatewayLocalLLMRequest) async throws -> GatewayLocalLLMResponse {
            let prompt = request.messages.last?.text ?? ""
            return GatewayLocalLLMResponse(
                text: "fallback: \(prompt)",
                model: self.model,
                provider: self.kind,
                usageInputTokens: 4,
                usageOutputTokens: 4)
        }

        func completeWithTools(_ request: GatewayLocalLLMToolRequest) async throws -> GatewayLocalLLMToolResponse {
            self.callCount += 1
            if self.callCount == 1 {
                return GatewayLocalLLMToolResponse(
                    text: "",
                    toolCalls: [
                        GatewayLocalLLMToolCall(
                            id: "tool-call-1",
                            name: "write",
                            argumentsJSON: #"{"path":"memory/tool-loop.md","content":"tool loop hello"}"#),
                    ],
                    model: self.model,
                    provider: self.kind,
                    usageInputTokens: 10,
                    usageOutputTokens: 6)
            }
            let sawToolResult = request.messages.contains(where: { message in
                message.role == .tool
                    && (message.text ?? "").contains("bytesWritten")
            })
            return GatewayLocalLLMToolResponse(
                text: sawToolResult ? "file update complete" : "missing tool result",
                toolCalls: [],
                model: self.model,
                provider: self.kind,
                usageInputTokens: 8,
            usageOutputTokens: 5)
        }
    }

    private actor DeferredPlanToolLLMProvider: GatewayLocalLLMToolCallableProvider {
        let kind: GatewayLocalLLMProviderKind = .openAICompatible
        let model: String = "deferred-tool-planner"
        private var callCount = 0

        func complete(_ request: GatewayLocalLLMRequest) async throws -> GatewayLocalLLMResponse {
            let prompt = request.messages.last?.text ?? ""
            return GatewayLocalLLMResponse(
                text: "fallback: \(prompt)",
                model: self.model,
                provider: self.kind,
                usageInputTokens: 4,
                usageOutputTokens: 4)
        }

        func completeWithTools(_ request: GatewayLocalLLMToolRequest) async throws -> GatewayLocalLLMToolResponse {
            self.callCount += 1
            if self.callCount == 1 {
                return GatewayLocalLLMToolResponse(
                    text: "Fetching news from multiple sources now:",
                    toolCalls: [],
                    model: self.model,
                    provider: self.kind,
                    usageInputTokens: 9,
                    usageOutputTokens: 5)
            }
            if self.callCount == 2 {
                let sawNudge = request.messages.contains(where: { message in
                    message.role == .system
                        && (message.text ?? "").contains("Do not wait for user confirmation like 'proceed'")
                })
                return GatewayLocalLLMToolResponse(
                    text: sawNudge ? "" : "missing system nudge",
                    toolCalls: sawNudge
                        ? [
                            GatewayLocalLLMToolCall(
                                id: "tool-call-deferred-1",
                                name: "time.now",
                                argumentsJSON: "{}"),
                        ]
                        : [],
                    model: self.model,
                    provider: self.kind,
                    usageInputTokens: 9,
                    usageOutputTokens: 5)
            }
            let sawToolResult = request.messages.contains(where: { message in
                message.role == .tool
                    && (message.text ?? "").contains("time.now")
            })
            return GatewayLocalLLMToolResponse(
                text: sawToolResult ? "completed after tool execution" : "missing tool result",
                toolCalls: [],
                model: self.model,
                provider: self.kind,
                usageInputTokens: 9,
                usageOutputTokens: 5)
        }
    }

    private actor StubAdminBridge: GatewayLocalMethodRouterAdminBridge {
        private var config: GatewayJSONValue = .object([
            "authMode": .string("none"),
            "upstreamURL": .string(""),
            "localLLMProvider": .string("disabled"),
        ])
        private var pairingRequests: [GatewayJSONValue] = [
            .object([
                "id": .string("111"),
                "code": .string("ABCDEFGH"),
                "createdAt": .string("2026-01-01T00:00:00Z"),
                "lastSeenAt": .string("2026-01-01T00:00:00Z"),
                "meta": .object([
                    "username": .string("alex"),
                ]),
            ]),
        ]
        private var restartCount = 0

        func configGet(nowMs _: Int64) async throws -> GatewayJSONValue {
            self.config
        }

        func configSet(params: GatewayJSONValue, nowMs _: Int64) async throws -> GatewayJSONValue {
            guard let object = params.objectValue else {
                return .object([
                    "applied": .bool(false),
                    "error": .string("params must be object"),
                ])
            }
            self.config = .object(object)
            return .object([
                "applied": .bool(true),
            ])
        }

        func runtimeRestart(nowMs _: Int64) async throws -> GatewayJSONValue {
            self.restartCount += 1
            return .object([
                "restarted": .bool(true),
                "count": .integer(Int64(self.restartCount)),
            ])
        }

        func pairingList(params _: GatewayJSONValue, nowMs _: Int64) async throws -> GatewayJSONValue {
            .object([
                "channel": .string("telegram"),
                "requests": .array(self.pairingRequests),
                "requestCount": .integer(Int64(self.pairingRequests.count)),
            ])
        }

        func pairingApprove(params: GatewayJSONValue, nowMs _: Int64) async throws -> GatewayJSONValue {
            let code = params.objectValue?["code"]?.stringValue?.uppercased() ?? ""
            guard !code.isEmpty else {
                return .object([
                    "approved": .bool(false),
                    "error": .string("missing code"),
                ])
            }
            self.pairingRequests.removeAll { entry in
                entry.objectValue?["code"]?.stringValue?.uppercased() == code
            }
            return .object([
                "approved": .bool(true),
                "code": .string(code),
            ])
        }

        func backupExport(nowMs _: Int64) async throws -> GatewayJSONValue {
            .object([
                "ok": .bool(true),
                "fileName": .string("stub-backup.ocbackup"),
                "data": .string("c3R1Yg=="),
                "sizeBytes": .integer(4),
            ])
        }

        func backupImport(params: GatewayJSONValue, nowMs _: Int64) async throws -> GatewayJSONValue {
            let hasData = params.objectValue?["data"]?.stringValue?.isEmpty == false
            return .object([
                "ok": .bool(hasData),
                "restoredFileCount": .integer(0),
                "restoredDefaultsCount": .integer(0),
                "restoredKeychainCount": .integer(0),
            ])
        }
    }

    private actor ConcurrencyProbe {
        private var active = 0
        private var maxActive = 0

        func beginStep() {
            self.active += 1
            self.maxActive = max(self.maxActive, self.active)
        }

        func endStep() {
            self.active -= 1
        }

        func maxObserved() -> Int {
            self.maxActive
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

    func testSQLiteMemoryStoreSessionSummariesIncludePersistedSessions() async throws {
        let dbPath = self.temporaryMemoryStorePath()
        let store = try GatewaySQLiteMemoryStore(path: dbPath)
        _ = try await store.appendTurn(
            sessionKey: "thread-a",
            role: "user",
            text: "first",
            timestampMs: 1_700_000_000_100,
            runID: nil)
        _ = try await store.appendTurn(
            sessionKey: "thread-b",
            role: "user",
            text: "second",
            timestampMs: 1_700_000_000_200,
            runID: nil)
        _ = try await store.appendTurn(
            sessionKey: "thread-a",
            role: "assistant",
            text: "reply",
            timestampMs: 1_700_000_000_300,
            runID: nil)

        let reopenedStore = try GatewaySQLiteMemoryStore(path: dbPath)
        let summaries = try await reopenedStore.sessionSummaries(limit: 10)
        let keys = summaries.map(\.sessionKey)
        XCTAssertEqual(Array(keys.prefix(2)), ["thread-a", "thread-b"])
        XCTAssertEqual(summaries.first(where: { $0.sessionKey == "thread-a" })?.turnCount, 2)
        XCTAssertEqual(summaries.first(where: { $0.sessionKey == "thread-b" })?.turnCount, 1)
    }

    func testSessionsListIncludesPersistedSessionsAfterRouterRestart() async throws {
        let dbPath = self.temporaryMemoryStorePath()
        let store = try GatewaySQLiteMemoryStore(path: dbPath)
        _ = try await store.appendTurn(
            sessionKey: "persisted-one",
            role: "user",
            text: "hello",
            timestampMs: 1_700_000_000_100,
            runID: nil)
        _ = try await store.appendTurn(
            sessionKey: "persisted-two",
            role: "assistant",
            text: "world",
            timestampMs: 1_700_000_000_200,
            runID: nil)

        let router = try GatewayLocalMethodRouter(
            config: GatewayLocalMethodRouterConfig(
                hostLabel: "unit-test",
                upstreamConfigured: false,
                llmConfig: GatewayLocalLLMConfig(provider: .disabled),
                memoryStorePath: dbPath,
                enableLocalSafeTools: true))

        let sessionsRequest = GatewayRequestFrame(
            id: "sessions-persisted",
            method: "sessions.list",
            params: .object(["limit": .integer(10)]))
        let sessionsResponse = await router.handle(sessionsRequest, nowMs: 1_700_000_000_500)
        XCTAssertEqual(sessionsResponse?.ok, true)

        let payload = try self.decodePayload(sessionsResponse?.payload, as: SessionsListPayload.self)
        let keys = payload?.sessions.map(\.key) ?? []
        XCTAssertTrue(keys.contains("persisted-one"))
        XCTAssertTrue(keys.contains("persisted-two"))
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
        XCTAssertEqual(historyPayload?.thinkingLevel, "low")

        let providerCalls = await llmProvider.observedRequestCount()
        XCTAssertEqual(providerCalls, 1)
    }

    func testChatThinkingLevelPersistsInHistoryAndSessionsList() async throws {
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
            id: "chat-thinking-1",
            method: "chat.send",
            params: .object([
                "sessionKey": .string("session-thinking"),
                "message": .string("hello"),
                "thinking": .string("high"),
            ]))
        let chatResponse = await router.handle(chatSend, nowMs: 1_700_000_001_100)
        XCTAssertEqual(chatResponse?.ok, true)

        let historyRequest = GatewayRequestFrame(
            id: "history-thinking-1",
            method: "chat.history",
            params: .object([
                "sessionKey": .string("session-thinking"),
                "limit": .integer(10),
            ]))
        let historyResponse = await router.handle(historyRequest, nowMs: 1_700_000_001_150)
        XCTAssertEqual(historyResponse?.ok, true)
        let historyPayload = try self.decodePayload(historyResponse?.payload, as: ChatHistoryPayload.self)
        XCTAssertEqual(historyPayload?.thinkingLevel, "high")

        let sessionsRequest = GatewayRequestFrame(
            id: "sessions-thinking-1",
            method: "sessions.list",
            params: .object(["limit": .integer(10)]))
        let sessionsResponse = await router.handle(sessionsRequest, nowMs: 1_700_000_001_175)
        XCTAssertEqual(sessionsResponse?.ok, true)
        let sessionsPayload = try self.decodePayload(sessionsResponse?.payload, as: SessionsListPayload.self)
        let entry = sessionsPayload?.sessions.first(where: { $0.key == "session-thinking" })
        XCTAssertEqual(entry?.thinkingLevel, "high")
    }

    func testLocalRouterParsesChatDirectivesAndStripsPrompt() async throws {
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
            id: "chat-directive-1",
            method: "chat.send",
            params: .object([
                "sessionKey": .string("session-directive"),
                "message": .string("/reasoning high\nWhat is the weather?"),
            ]))
        let chatResponse = await router.handle(chatSend, nowMs: 1_700_000_001_200)
        XCTAssertEqual(chatResponse?.ok, true)

        let thinking = await llmProvider.observedLastThinkingLevel()
        XCTAssertEqual(thinking, "high")

        let messages = await llmProvider.observedLastMessageTexts()
        XCTAssertEqual(messages.last, "What is the weather?")
    }

    func testLocalRouterNormalizesXHighReasoningDirective() async throws {
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
            id: "chat-directive-xhigh-1",
            method: "chat.send",
            params: .object([
                "sessionKey": .string("session-directive-xhigh"),
                "message": .string("/reasoning x-high\nWhat is the weather?"),
            ]))
        let chatResponse = await router.handle(chatSend, nowMs: 1_700_000_001_210)
        XCTAssertEqual(chatResponse?.ok, true)

        let thinking = await llmProvider.observedLastThinkingLevel()
        XCTAssertEqual(thinking, "xhigh")

        let messages = await llmProvider.observedLastMessageTexts()
        XCTAssertEqual(messages.last, "What is the weather?")
    }

    func testLocalRouterInjectsBootstrapPromptWhenEnabled() async throws {
        let dbPath = self.temporaryMemoryStorePath()
        let llmProvider = StubLLMProvider()
        let workspacePath = FileManager.default.temporaryDirectory
            .appendingPathComponent("openclaw-bootstrap-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workspacePath, withIntermediateDirectories: true)
        try "agent policy".write(
            to: workspacePath.appendingPathComponent("AGENTS.md"),
            atomically: true,
            encoding: .utf8)
        try "friendly bot".write(
            to: workspacePath.appendingPathComponent("SOUL.md"),
            atomically: true,
            encoding: .utf8)

        let bootstrapConfig = GatewayBootstrapConfig(
            enabled: true,
            workspacePath: workspacePath.path,
            fileNames: ["AGENTS.md", "SOUL.md"],
            perFileMaxChars: 120,
            totalMaxChars: 200,
            includeMissingMarkers: false)

        let config = GatewayLocalMethodRouterConfig(
            hostLabel: "unit-test",
            upstreamConfigured: false,
            llmConfig: GatewayLocalLLMConfig(
                provider: .openAICompatible,
                baseURL: URL(string: "https://example.invalid"),
                apiKey: "test-key",
                model: "stub-model"),
            memoryStorePath: dbPath,
            bootstrapConfig: bootstrapConfig,
            enableLocalSafeTools: true)
        let router = try GatewayLocalMethodRouter(config: config, llmProvider: llmProvider)

        let chatSend = GatewayRequestFrame(
            id: "chat-bootstrap-1",
            method: "chat.send",
            params: .object([
                "sessionKey": .string("session-bootstrap"),
                "message": .string("hello"),
            ]))
        let chatResponse = await router.handle(chatSend, nowMs: 1_700_000_001_300)
        XCTAssertEqual(chatResponse?.ok, true)

        let systemPrompt = await llmProvider.observedLastSystemPrompt()
        XCTAssertNotNil(systemPrompt)
        let promptText = systemPrompt ?? ""
        XCTAssertTrue(promptText.contains("Project Context"))
        XCTAssertTrue(promptText.contains("AGENTS.md"))
        XCTAssertTrue(promptText.contains("agent policy"))
        XCTAssertTrue(promptText.contains("SOUL.md"))
        XCTAssertTrue(promptText.contains("friendly bot"))
    }

    func testMemorySearchAndGetIncludeWorkspaceMarkdown() async throws {
        let workspacePath = FileManager.default.temporaryDirectory
            .appendingPathComponent("openclaw-workspace-memory-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workspacePath, withIntermediateDirectories: true)
        try """
        Long-term project memory:
        - Gateway is in operational mode.
        """.write(
            to: workspacePath.appendingPathComponent("MEMORY.md"),
            atomically: true,
            encoding: .utf8)
        let memoryDirectory = workspacePath.appendingPathComponent("memory", isDirectory: true)
        try FileManager.default.createDirectory(at: memoryDirectory, withIntermediateDirectories: true)
        try """
        Daily note:
        Device readiness is green and LAN websocket checks pass.
        """.write(
            to: memoryDirectory.appendingPathComponent("2026-02-18.md"),
            atomically: true,
            encoding: .utf8)

        let bootstrapConfig = GatewayBootstrapConfig(
            enabled: true,
            workspacePath: workspacePath.path,
            fileNames: ["AGENTS.md", "MEMORY.md"],
            perFileMaxChars: 120,
            totalMaxChars: 240,
            includeMissingMarkers: false)
        let router = try GatewayLocalMethodRouter(
            config: GatewayLocalMethodRouterConfig(
                hostLabel: "unit-test",
                upstreamConfigured: false,
                llmConfig: GatewayLocalLLMConfig(provider: .disabled),
                memoryStorePath: self.temporaryMemoryStorePath(),
                bootstrapConfig: bootstrapConfig,
                enableLocalSafeTools: true))

        let searchRequest = GatewayRequestFrame(
            id: "memory-search-1",
            method: "memory.search",
            params: .object([
                "query": .string("readiness is green"),
                "limit": .integer(10),
            ]))
        let searchResponse = await router.handle(searchRequest, nowMs: 1_700_000_001_400)
        XCTAssertEqual(searchResponse?.ok, true)
        let payload = try self.decodePayload(searchResponse?.payload, as: MemorySearchPayload.self)
        let workspaceResult = payload?.results.first(where: { $0.source == "workspace-memory" })
        XCTAssertNotNil(workspaceResult)
        XCTAssertTrue(workspaceResult?.id.hasPrefix("filemem:") == true)
        XCTAssertEqual(workspaceResult?.file, "memory/2026-02-18.md")
        XCTAssertTrue(workspaceResult?.text.contains("Device readiness is green") == true)

        guard let workspaceID = workspaceResult?.id else {
            XCTFail("workspace memory id missing")
            return
        }

        let getRequest = GatewayRequestFrame(
            id: "memory-get-1",
            method: "memory.get",
            params: .object([
                "id": .string(workspaceID),
            ]))
        let getResponse = await router.handle(getRequest, nowMs: 1_700_000_001_450)
        XCTAssertEqual(getResponse?.ok, true)
        let getPayload = try self.decodePayload(getResponse?.payload, as: MemoryGetPayload.self)
        XCTAssertEqual(getPayload?.source, "workspace-memory")
        XCTAssertEqual(getPayload?.file, "memory/2026-02-18.md")
        XCTAssertTrue(getPayload?.text.contains("Device readiness is green") == true)
    }

    func testMemoryAppendWritesWorkspaceMemoryMarkdown() async throws {
        let workspacePath = FileManager.default.temporaryDirectory
            .appendingPathComponent("openclaw-workspace-memory-write-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workspacePath, withIntermediateDirectories: true)
        let bootstrapConfig = GatewayBootstrapConfig(
            enabled: true,
            workspacePath: workspacePath.path,
            fileNames: ["MEMORY.md"],
            perFileMaxChars: 200,
            totalMaxChars: 400,
            includeMissingMarkers: false)
        let router = try GatewayLocalMethodRouter(
            config: GatewayLocalMethodRouterConfig(
                hostLabel: "unit-test",
                upstreamConfigured: false,
                llmConfig: GatewayLocalLLMConfig(provider: .disabled),
                memoryStorePath: self.temporaryMemoryStorePath(),
                bootstrapConfig: bootstrapConfig,
                enableLocalSafeTools: true))

        let appendRequest = GatewayRequestFrame(
            id: "memory-append-1",
            method: "memory.append",
            params: .object([
                "path": .string("memory/2026-02-18.md"),
                "text": .string("Remember this operational fact."),
            ]))
        let appendResponse = await router.handle(appendRequest, nowMs: 1_700_000_001_500)
        XCTAssertEqual(appendResponse?.ok, true)

        let appendPayload = try self.decodePayload(appendResponse?.payload, as: MemoryWritePayload.self)
        XCTAssertEqual(appendPayload?.path, "memory/2026-02-18.md")
        XCTAssertEqual(appendPayload?.source, "workspace-memory")
        XCTAssertEqual(appendPayload?.append, true)

        let memoryFile = workspacePath
            .appendingPathComponent("memory", isDirectory: true)
            .appendingPathComponent("2026-02-18.md")
        let memoryText = try String(contentsOf: memoryFile, encoding: .utf8)
        XCTAssertTrue(memoryText.contains("Remember this operational fact."))
    }

    func testMemoryAppendRejectsNonMemoryPath() async throws {
        let workspacePath = FileManager.default.temporaryDirectory
            .appendingPathComponent("openclaw-workspace-memory-write-invalid-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workspacePath, withIntermediateDirectories: true)
        let bootstrapConfig = GatewayBootstrapConfig(
            enabled: true,
            workspacePath: workspacePath.path,
            fileNames: ["MEMORY.md"],
            perFileMaxChars: 200,
            totalMaxChars: 400,
            includeMissingMarkers: false)
        let router = try GatewayLocalMethodRouter(
            config: GatewayLocalMethodRouterConfig(
                hostLabel: "unit-test",
                upstreamConfigured: false,
                llmConfig: GatewayLocalLLMConfig(provider: .disabled),
                memoryStorePath: self.temporaryMemoryStorePath(),
                bootstrapConfig: bootstrapConfig,
                enableLocalSafeTools: true))

        let appendRequest = GatewayRequestFrame(
            id: "memory-append-invalid-1",
            method: "memory.append",
            params: .object([
                "path": .string("AGENTS.md"),
                "text": .string("This should fail."),
            ]))
        let appendResponse = await router.handle(appendRequest, nowMs: 1_700_000_001_550)
        XCTAssertEqual(appendResponse?.ok, false)
        XCTAssertEqual(appendResponse?.error?.code, GatewayCoreErrorCode.invalidRequest.rawValue)
    }

    func testChatSendDoesNotRewriteProfileByDefault() async throws {
        let dbPath = self.temporaryMemoryStorePath()
        let llmProvider = StubLLMProvider()
        let workspacePath = FileManager.default.temporaryDirectory
            .appendingPathComponent("openclaw-bootstrap-profile-default-off-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workspacePath, withIntermediateDirectories: true)
        let initialIdentity = """
        # IDENTITY.md - Who Am I?

        - **Name:**
        - **Creature:**
        - **Vibe:**
        - **Emoji:**
        """
        let initialUser = """
        # USER.md - About Your Human

        - **Name:**
        - **What to call them:**
        - **Timezone:**
        """
        try initialIdentity.write(
            to: workspacePath.appendingPathComponent("IDENTITY.md"),
            atomically: true,
            encoding: .utf8)
        try initialUser.write(
            to: workspacePath.appendingPathComponent("USER.md"),
            atomically: true,
            encoding: .utf8)

        let bootstrapConfig = GatewayBootstrapConfig(
            enabled: true,
            workspacePath: workspacePath.path,
            fileNames: ["IDENTITY.md", "USER.md"],
            perFileMaxChars: 500,
            totalMaxChars: 2_000,
            includeMissingMarkers: false)
        let router = try GatewayLocalMethodRouter(
            config: GatewayLocalMethodRouterConfig(
                hostLabel: "unit-test",
                upstreamConfigured: false,
                llmConfig: GatewayLocalLLMConfig(
                    provider: .openAICompatible,
                    baseURL: URL(string: "https://example.invalid"),
                    apiKey: "test-key",
                    model: "stub-model"),
                memoryStorePath: dbPath,
                bootstrapConfig: bootstrapConfig,
                enableLocalSafeTools: true),
            llmProvider: llmProvider)

        let chatSend = GatewayRequestFrame(
            id: "chat-profile-default-off-1",
            method: "chat.send",
            params: .object([
                "sessionKey": .string("session-profile-default-off"),
                "message": .string("Your name: Ane\nMy name: Alex\nTimezone: PST"),
            ]))
        let chatResponse = await router.handle(chatSend, nowMs: 1_700_000_002_900)
        XCTAssertEqual(chatResponse?.ok, true)

        let identity = try String(
            contentsOf: workspacePath.appendingPathComponent("IDENTITY.md"),
            encoding: .utf8)
        let user = try String(
            contentsOf: workspacePath.appendingPathComponent("USER.md"),
            encoding: .utf8)
        XCTAssertEqual(identity, initialIdentity)
        XCTAssertEqual(user, initialUser)
    }

    func testNodeInvokeSupportsWorkspaceFileTools() async throws {
        let workspacePath = FileManager.default.temporaryDirectory
            .appendingPathComponent("openclaw-node-file-tools-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workspacePath, withIntermediateDirectories: true)
        let bootstrapConfig = GatewayBootstrapConfig(
            enabled: true,
            workspacePath: workspacePath.path,
            fileNames: ["MEMORY.md", "memory.md"],
            perFileMaxChars: 500,
            totalMaxChars: 2_000,
            includeMissingMarkers: false)
        let router = try GatewayLocalMethodRouter(
            config: GatewayLocalMethodRouterConfig(
                hostLabel: "unit-test",
                upstreamConfigured: false,
                llmConfig: GatewayLocalLLMConfig(provider: .disabled),
                memoryStorePath: self.temporaryMemoryStorePath(),
                bootstrapConfig: bootstrapConfig,
                enableLocalSafeTools: true,
                enableLocalFileTools: true))

        let writeRequest = GatewayRequestFrame(
            id: "file-tool-write-1",
            method: "node.invoke",
            params: .object([
                "command": .string("write"),
                "params": .object([
                    "path": .string("memory/test.md"),
                    "content": .string("alpha"),
                ]),
            ]))
        let writeResponse = await router.handle(writeRequest, nowMs: 1_700_000_003_100)
        XCTAssertEqual(writeResponse?.ok, true)

        let readRequest = GatewayRequestFrame(
            id: "file-tool-read-1",
            method: "node.invoke",
            params: .object([
                "command": .string("read"),
                "params": .object([
                    "path": .string("memory/test.md"),
                ]),
            ]))
        let readResponse = await router.handle(readRequest, nowMs: 1_700_000_003_120)
        XCTAssertEqual(readResponse?.ok, true)
        XCTAssertEqual(readResponse?.payload?.objectValue?["text"]?.stringValue, "alpha")

        let editRequest = GatewayRequestFrame(
            id: "file-tool-edit-1",
            method: "node.invoke",
            params: .object([
                "command": .string("edit"),
                "params": .object([
                    "path": .string("memory/test.md"),
                    "oldText": .string("alpha"),
                    "newText": .string("beta"),
                ]),
            ]))
        let editResponse = await router.handle(editRequest, nowMs: 1_700_000_003_140)
        XCTAssertEqual(editResponse?.ok, true)

        let readResponseAfterEdit = await router.handle(readRequest, nowMs: 1_700_000_003_150)
        XCTAssertEqual(readResponseAfterEdit?.ok, true)
        XCTAssertEqual(readResponseAfterEdit?.payload?.objectValue?["text"]?.stringValue, "beta")
    }

    func testNodeInvokeResolvesCaseVariantWorkspaceFilePaths() async throws {
        let workspacePath = FileManager.default.temporaryDirectory
            .appendingPathComponent("openclaw-node-file-case-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workspacePath, withIntermediateDirectories: true)
        let bootstrapConfig = GatewayBootstrapConfig(
            enabled: true,
            workspacePath: workspacePath.path,
            fileNames: ["AGENTS.md"],
            perFileMaxChars: 500,
            totalMaxChars: 2_000,
            includeMissingMarkers: false)
        let router = try GatewayLocalMethodRouter(
            config: GatewayLocalMethodRouterConfig(
                hostLabel: "unit-test",
                upstreamConfigured: false,
                llmConfig: GatewayLocalLLMConfig(provider: .disabled),
                memoryStorePath: self.temporaryMemoryStorePath(),
                bootstrapConfig: bootstrapConfig,
                enableLocalSafeTools: true,
                enableLocalFileTools: true))

        let upperWrite = GatewayRequestFrame(
            id: "file-tool-case-write-upper",
            method: "node.invoke",
            params: .object([
                "command": .string("write"),
                "params": .object([
                    "path": .string("skills/GEEKBENCH_MONITOR.md"),
                    "content": .string("alpha"),
                ]),
            ]))
        let upperWriteResponse = await router.handle(upperWrite, nowMs: 1_700_000_003_160)
        XCTAssertEqual(upperWriteResponse?.ok, true)

        let lowerWrite = GatewayRequestFrame(
            id: "file-tool-case-write-lower",
            method: "node.invoke",
            params: .object([
                "command": .string("write"),
                "params": .object([
                    "path": .string("skills/geekbench_monitor.md"),
                    "content": .string("beta"),
                ]),
            ]))
        let lowerWriteResponse = await router.handle(lowerWrite, nowMs: 1_700_000_003_170)
        XCTAssertEqual(lowerWriteResponse?.ok, true)

        let lowerRead = GatewayRequestFrame(
            id: "file-tool-case-read-lower",
            method: "node.invoke",
            params: .object([
                "command": .string("read"),
                "params": .object([
                    "path": .string("skills/geekbench_monitor.md"),
                ]),
            ]))
        let lowerReadResponse = await router.handle(lowerRead, nowMs: 1_700_000_003_180)
        XCTAssertEqual(lowerReadResponse?.ok, true)
        XCTAssertEqual(lowerReadResponse?.payload?.objectValue?["text"]?.stringValue, "beta")

        let upperRead = GatewayRequestFrame(
            id: "file-tool-case-read-upper",
            method: "node.invoke",
            params: .object([
                "command": .string("read"),
                "params": .object([
                    "path": .string("skills/GEEKBENCH_MONITOR.md"),
                ]),
            ]))
        let upperReadResponse = await router.handle(upperRead, nowMs: 1_700_000_003_190)
        XCTAssertEqual(upperReadResponse?.ok, true)
        XCTAssertEqual(upperReadResponse?.payload?.objectValue?["text"]?.stringValue, "beta")

        let skillsDirectory = workspacePath.appendingPathComponent("skills", isDirectory: true)
        let skillURLs = try FileManager.default.contentsOfDirectory(
            at: skillsDirectory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles])
            .filter { $0.lastPathComponent.lowercased() == "geekbench_monitor.md" }
        XCTAssertEqual(skillURLs.count, 1)
    }

    func testChatSendExecutesToolLoopAndLogsAudit() async throws {
        let workspacePath = FileManager.default.temporaryDirectory
            .appendingPathComponent("openclaw-chat-tool-loop-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workspacePath, withIntermediateDirectories: true)

        let bootstrapConfig = GatewayBootstrapConfig(
            enabled: true,
            workspacePath: workspacePath.path,
            fileNames: ["AGENTS.md", "MEMORY.md"],
            perFileMaxChars: 300,
            totalMaxChars: 1_000,
            includeMissingMarkers: false)
        let provider = ToolCallingLLMProvider()
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
                bootstrapConfig: bootstrapConfig,
                enableLocalSafeTools: true,
                enableLocalFileTools: true),
            llmProvider: provider)

        let chatSend = GatewayRequestFrame(
            id: "chat-tool-loop-1",
            method: "chat.send",
            params: .object([
                "sessionKey": .string("session-tool-loop"),
                "message": .string("Create a memory file."),
            ]))
        let chatResponse = await router.handle(chatSend, nowMs: 1_700_000_003_300)
        XCTAssertEqual(chatResponse?.ok, true)
        XCTAssertEqual(chatResponse?.payload?.objectValue?["toolCalls"]?.int64Value, 1)

        let written = try String(
            contentsOf: workspacePath.appendingPathComponent("memory/tool-loop.md"),
            encoding: .utf8)
        XCTAssertEqual(written, "tool loop hello")

        let historyRequest = GatewayRequestFrame(
            id: "chat-tool-loop-history-1",
            method: "chat.history",
            params: .object([
                "sessionKey": .string("session-tool-loop"),
                "limit": .integer(30),
            ]))
        let historyResponse = await router.handle(historyRequest, nowMs: 1_700_000_003_350)
        XCTAssertEqual(historyResponse?.ok, true)
        let historyPayload = try self.decodePayload(historyResponse?.payload, as: ChatHistoryPayload.self)
        let messages = historyPayload?.messages ?? []
        let allText = messages.flatMap(\.content).map(\.text).joined(separator: "\n")
        XCTAssertTrue(allText.contains("tool.call write"))
        XCTAssertTrue(allText.contains("tool.result write"))
    }

    func testChatSendDisableToolsBypassesToolCallableProvider() async throws {
        let provider = ToolCallingLLMProvider()
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
                enableLocalSafeTools: true,
                enableLocalFileTools: true),
            llmProvider: provider)

        let chatSend = GatewayRequestFrame(
            id: "chat-tool-disable-1",
            method: "chat.send",
            params: .object([
                "sessionKey": .string("session-tool-disable"),
                "message": .string("Create a memory file."),
                "disableTools": .bool(true),
            ]))
        let chatResponse = await router.handle(chatSend, nowMs: 1_700_000_003_360)
        XCTAssertEqual(chatResponse?.ok, true)
        XCTAssertNil(chatResponse?.payload?.objectValue?["toolCalls"])

        let historyRequest = GatewayRequestFrame(
            id: "chat-tool-disable-history-1",
            method: "chat.history",
            params: .object([
                "sessionKey": .string("session-tool-disable"),
                "limit": .integer(10),
            ]))
        let historyResponse = await router.handle(historyRequest, nowMs: 1_700_000_003_370)
        XCTAssertEqual(historyResponse?.ok, true)
        let historyPayload = try self.decodePayload(historyResponse?.payload, as: ChatHistoryPayload.self)
        XCTAssertEqual(historyPayload?.messages.last?.content.first?.text, "fallback: Create a memory file.")
    }

    func testChatSendAutoNudgesDeferredToolPlanIntoToolExecution() async throws {
        let provider = DeferredPlanToolLLMProvider()
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
                enableLocalSafeTools: true,
                enableLocalFileTools: true),
            llmProvider: provider)

        let chatSend = GatewayRequestFrame(
            id: "chat-deferred-tool-plan-1",
            method: "chat.send",
            params: .object([
                "sessionKey": .string("session-deferred-tool-plan"),
                "message": .string("Fetch headlines from multiple sources."),
            ]))
        let chatResponse = await router.handle(chatSend, nowMs: 1_700_000_003_360)
        XCTAssertEqual(chatResponse?.ok, true)
        XCTAssertEqual(chatResponse?.payload?.objectValue?["toolCalls"]?.int64Value, 1)

        let historyRequest = GatewayRequestFrame(
            id: "chat-deferred-tool-plan-history-1",
            method: "chat.history",
            params: .object([
                "sessionKey": .string("session-deferred-tool-plan"),
                "limit": .integer(30),
            ]))
        let historyResponse = await router.handle(historyRequest, nowMs: 1_700_000_003_370)
        XCTAssertEqual(historyResponse?.ok, true)
        let historyPayload = try self.decodePayload(historyResponse?.payload, as: ChatHistoryPayload.self)
        let allText = (historyPayload?.messages ?? [])
            .flatMap(\.content)
            .map(\.text)
            .joined(separator: "\n")
        XCTAssertTrue(allText.contains("tool.call time.now"))
        XCTAssertTrue(allText.contains("completed after tool execution"))
    }

    func testChatSendPersistsBootstrapProfileFieldsIntoWorkspaceFiles() async throws {
        let dbPath = self.temporaryMemoryStorePath()
        let llmProvider = StubLLMProvider()
        let workspacePath = FileManager.default.temporaryDirectory
            .appendingPathComponent("openclaw-bootstrap-profile-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workspacePath, withIntermediateDirectories: true)
        try """
        # IDENTITY.md - Who Am I?

        - **Name:**
          _(pick something you like)_
        - **Creature:**
          _(AI? robot?)_
        - **Vibe:**
          _(sharp? warm?)_
        - **Emoji:**
          _(pick one)_
        """.write(
            to: workspacePath.appendingPathComponent("IDENTITY.md"),
            atomically: true,
            encoding: .utf8)
        try """
        # USER.md - About Your Human

        - **Name:**
        - **What to call them:**
        - **Pronouns:** _(optional)_
        - **Timezone:**
        - **Notes:**
        """.write(
            to: workspacePath.appendingPathComponent("USER.md"),
            atomically: true,
            encoding: .utf8)

        let bootstrapConfig = GatewayBootstrapConfig(
            enabled: true,
            workspacePath: workspacePath.path,
            fileNames: ["IDENTITY.md", "USER.md"],
            perFileMaxChars: 500,
            totalMaxChars: 2_000,
            includeMissingMarkers: false)
        let router = try GatewayLocalMethodRouter(
            config: GatewayLocalMethodRouterConfig(
                hostLabel: "unit-test",
                upstreamConfigured: false,
                llmConfig: GatewayLocalLLMConfig(
                    provider: .openAICompatible,
                    baseURL: URL(string: "https://example.invalid"),
                    apiKey: "test-key",
                    model: "stub-model"),
                memoryStorePath: dbPath,
                bootstrapConfig: bootstrapConfig,
                enableLocalSafeTools: true,
                enableAutoProfileRewrite: true),
            llmProvider: llmProvider)

        let profileMessage = """
        Your name: Ane
        My name: Alex
        Timezone: PST
        Creature: Helpful AI assistant
        Vibe: Helpful, friendly
        Emoji: 🦞
        """
        let chatSend = GatewayRequestFrame(
            id: "chat-profile-1",
            method: "chat.send",
            params: .object([
                "sessionKey": .string("session-profile"),
                "message": .string(profileMessage),
            ]))
        let chatResponse = await router.handle(chatSend, nowMs: 1_700_000_002_000)
        XCTAssertEqual(chatResponse?.ok, true)

        let identity = try String(
            contentsOf: workspacePath.appendingPathComponent("IDENTITY.md"),
            encoding: .utf8)
        XCTAssertTrue(identity.contains("- **Name:** Ane"))
        XCTAssertTrue(identity.contains("- **Creature:** Helpful AI assistant"))
        XCTAssertTrue(identity.contains("- **Vibe:** Helpful, friendly"))
        XCTAssertTrue(identity.contains("- **Emoji:** 🦞"))

        let user = try String(
            contentsOf: workspacePath.appendingPathComponent("USER.md"),
            encoding: .utf8)
        XCTAssertTrue(user.contains("- **Name:** Alex"))
        XCTAssertTrue(user.contains("- **What to call them:** Alex"))
        XCTAssertTrue(user.contains("- **Timezone:** PST"))

        let historyRequest = GatewayRequestFrame(
            id: "history-profile-1",
            method: "chat.history",
            params: .object([
                "sessionKey": .string("session-profile"),
                "limit": .integer(20),
            ]))
        let historyResponse = await router.handle(historyRequest, nowMs: 1_700_000_002_050)
        XCTAssertEqual(historyResponse?.ok, true)
        let historyPayload = try self.decodePayload(historyResponse?.payload, as: ChatHistoryPayload.self)
        XCTAssertTrue(historyPayload?.messages.contains(where: { message in
            message.role == "system"
                && message.content.contains(where: { $0.text.contains("workspace profile updated:") })
        }) == true)

        let llmMessages = await llmProvider.observedLastMessageTexts()
        XCTAssertTrue(llmMessages.contains(where: { $0.contains("workspace profile updated:") }))
    }

    func testChatSendParsesMarkdownProfileBlocksIntoWorkspaceFiles() async throws {
        let dbPath = self.temporaryMemoryStorePath()
        let llmProvider = StubLLMProvider()
        let workspacePath = FileManager.default.temporaryDirectory
            .appendingPathComponent("openclaw-bootstrap-profile-md-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workspacePath, withIntermediateDirectories: true)
        try """
        # IDENTITY.md - Who Am I?

        - **Name:**
        - **Creature:**
        - **Vibe:**
        - **Emoji:**
        - **Avatar:**
        """.write(
            to: workspacePath.appendingPathComponent("IDENTITY.md"),
            atomically: true,
            encoding: .utf8)
        try """
        # USER.md - About Your Human

        - **Name:**
        - **What to call them:**
        - **Timezone:**
        """.write(
            to: workspacePath.appendingPathComponent("USER.md"),
            atomically: true,
            encoding: .utf8)

        let bootstrapConfig = GatewayBootstrapConfig(
            enabled: true,
            workspacePath: workspacePath.path,
            fileNames: ["IDENTITY.md", "USER.md"],
            perFileMaxChars: 500,
            totalMaxChars: 2_000,
            includeMissingMarkers: false)
        let router = try GatewayLocalMethodRouter(
            config: GatewayLocalMethodRouterConfig(
                hostLabel: "unit-test",
                upstreamConfigured: false,
                llmConfig: GatewayLocalLLMConfig(
                    provider: .openAICompatible,
                    baseURL: URL(string: "https://example.invalid"),
                    apiKey: "test-key",
                    model: "stub-model"),
                memoryStorePath: dbPath,
                bootstrapConfig: bootstrapConfig,
                enableLocalSafeTools: true,
                enableAutoProfileRewrite: true),
            llmProvider: llmProvider)

        let profileMessage = """
        # IDENTITY.md - Who Am I?

        - **Name:** Ane
        - **Creature:** Helpful AI assistant
        - **Vibe:** Friendly, helpful
        - **Emoji:** 👋

        # USER.md - About Your Human

        - **Name:** Alex
        - **What to call them:** Alex
        - **Timezone:** PST
        """
        let chatSend = GatewayRequestFrame(
            id: "chat-profile-md-1",
            method: "chat.send",
            params: .object([
                "sessionKey": .string("session-profile-md"),
                "message": .string(profileMessage),
            ]))
        let chatResponse = await router.handle(chatSend, nowMs: 1_700_000_003_000)
        XCTAssertEqual(chatResponse?.ok, true)

        let identity = try String(
            contentsOf: workspacePath.appendingPathComponent("IDENTITY.md"),
            encoding: .utf8)
        XCTAssertTrue(identity.contains("- **Name:** Ane"))
        XCTAssertTrue(identity.contains("- **Creature:** Helpful AI assistant"))
        XCTAssertTrue(identity.contains("- **Vibe:** Friendly, helpful"))
        XCTAssertTrue(identity.contains("- **Emoji:** 👋"))

        let user = try String(
            contentsOf: workspacePath.appendingPathComponent("USER.md"),
            encoding: .utf8)
        XCTAssertTrue(user.contains("- **Name:** Alex"))
        XCTAssertTrue(user.contains("- **What to call them:** Alex"))
        XCTAssertTrue(user.contains("- **Timezone:** PST"))
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
        XCTAssertEqual(
            payload?.toolPolicy.localSafeCommands,
            ["time.now", "device.info", "network.fetch", "web.fetch", "web.render", "web.extract", "telegram.send"])
        XCTAssertTrue(payload?.toolPolicy.upstreamOnlyPrefixRules.contains("node.invoke") == true)
        XCTAssertEqual(payload?.methods.first(where: { $0.method == "chat.send" })?.route, "local")
        XCTAssertEqual(payload?.methods.first(where: { $0.method == "telegram.send" })?.route, "disabled")
        XCTAssertEqual(payload?.methods.first(where: { $0.method == "cron.add" })?.route, "local")
    }

    func testCronLifecycleAddRunListRunsAndRemove() async throws {
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

        let addRequest = GatewayRequestFrame(
            id: "cron-add-1",
            method: "cron.add",
            params: .object([
                "name": .string("Geekbench watcher"),
                "enabled": .bool(true),
                "schedule": .object([
                    "kind": .string("every"),
                    "everyMs": .integer(4 * 60 * 60 * 1_000),
                ]),
                "sessionTarget": .string("isolated"),
                "payload": .object([
                    "kind": .string("agentTurn"),
                    "message": .string("Use skills/GEEKBENCH_MONITOR.md and report new matches only."),
                    "thinking": .string("low"),
                ]),
            ]))
        let addResponse = await router.handle(addRequest, nowMs: 1_700_000_100_000)
        XCTAssertEqual(addResponse?.ok, true)
        let jobID = addResponse?.payload?.objectValue?["id"]?.stringValue
        XCTAssertNotNil(jobID)

        let listRequest = GatewayRequestFrame(
            id: "cron-list-1",
            method: "cron.list",
            params: .object(["includeDisabled": .bool(true)]))
        let listResponse = await router.handle(listRequest, nowMs: 1_700_000_100_050)
        XCTAssertEqual(listResponse?.ok, true)
        guard case let .array(jobs)? = listResponse?.payload?.objectValue?["jobs"] else {
            XCTFail("expected cron.list jobs")
            return
        }
        XCTAssertTrue(jobs.contains(where: { $0.objectValue?["id"]?.stringValue == jobID }))

        let runRequest = GatewayRequestFrame(
            id: "cron-run-1",
            method: "cron.run",
            params: .object([
                "id": .string(jobID ?? ""),
                "mode": .string("force"),
            ]))
        let runResponse = await router.handle(runRequest, nowMs: 1_700_000_100_100)
        XCTAssertEqual(runResponse?.ok, true)
        XCTAssertEqual(runResponse?.payload?.objectValue?["status"]?.stringValue, "ok")
        let requestCount = await llmProvider.observedRequestCount()
        XCTAssertEqual(requestCount, 1)

        let runsRequest = GatewayRequestFrame(
            id: "cron-runs-1",
            method: "cron.runs",
            params: .object([
                "id": .string(jobID ?? ""),
                "limit": .integer(10),
            ]))
        let runsResponse = await router.handle(runsRequest, nowMs: 1_700_000_100_150)
        XCTAssertEqual(runsResponse?.ok, true)
        guard case let .array(entries)? = runsResponse?.payload?.objectValue?["entries"] else {
            XCTFail("expected cron.runs entries")
            return
        }
        XCTAssertFalse(entries.isEmpty)
        XCTAssertEqual(entries.last?.objectValue?["status"]?.stringValue, "ok")

        let removeRequest = GatewayRequestFrame(
            id: "cron-remove-1",
            method: "cron.remove",
            params: .object(["id": .string(jobID ?? "")]))
        let removeResponse = await router.handle(removeRequest, nowMs: 1_700_000_100_200)
        XCTAssertEqual(removeResponse?.ok, true)
        XCTAssertEqual(removeResponse?.payload?.objectValue?["removed"]?.boolValue, true)
    }

    func testCronAddRejectsInvalidSchedule() async throws {
        let router = try GatewayLocalMethodRouter(
            config: GatewayLocalMethodRouterConfig(
                hostLabel: "unit-test",
                upstreamConfigured: false,
                llmConfig: GatewayLocalLLMConfig(provider: .disabled),
                memoryStorePath: self.temporaryMemoryStorePath(),
                enableLocalSafeTools: true))

        let addRequest = GatewayRequestFrame(
            id: "cron-add-invalid",
            method: "cron.add",
            params: .object([
                "name": .string("Bad schedule"),
                "schedule": .object([
                    "kind": .string("every"),
                    "everyMs": .integer(0),
                ]),
                "payload": .object([
                    "kind": .string("agentTurn"),
                    "message": .string("hello"),
                ]),
            ]))
        let response = await router.handle(addRequest, nowMs: 1_700_000_101_000)
        XCTAssertEqual(response?.ok, false)
        XCTAssertEqual(response?.error?.code, GatewayCoreErrorCode.invalidRequest.rawValue)
    }

    func testNodeInvokeWebExtractNormalizesHTML() async throws {
        let router = try GatewayLocalMethodRouter(
            config: GatewayLocalMethodRouterConfig(
                hostLabel: "unit-test",
                upstreamConfigured: false,
                llmConfig: GatewayLocalLLMConfig(provider: .disabled),
                memoryStorePath: self.temporaryMemoryStorePath(),
                enableLocalSafeTools: true))

        let request = GatewayRequestFrame(
            id: "web-extract-1",
            method: "node.invoke",
            params: .object([
                "command": .string("web.extract"),
                "params": .object([
                    "html": .string("""
                    <html><head><title>Example Title</title></head>
                    <body><h1>Hello</h1><p>World</p><a href="https://example.com/path">Example Link</a></body>
                    </html>
                    """),
                    "includeLinks": .bool(true),
                ]),
            ]))

        let response = await router.handle(request, nowMs: 1_700_000_003_700)
        XCTAssertEqual(response?.ok, true)
        XCTAssertEqual(response?.payload?.objectValue?["title"]?.stringValue, "Example Title")
        let extractedText = response?.payload?.objectValue?["text"]?.stringValue ?? ""
        XCTAssertTrue(extractedText.contains("Hello"))
        XCTAssertTrue(extractedText.contains("World"))
        guard case let .array(links)? = response?.payload?.objectValue?["links"] else {
            XCTFail("expected links array")
            return
        }
        XCTAssertEqual(links.count, 1)
        XCTAssertEqual(links.first?.objectValue?["href"]?.stringValue, "https://example.com/path")
    }

    func testNodeInvokeTelegramSendRequiresLocalTokenConfig() async throws {
        let router = try GatewayLocalMethodRouter(
            config: GatewayLocalMethodRouterConfig(
                hostLabel: "unit-test",
                upstreamConfigured: false,
                llmConfig: GatewayLocalLLMConfig(provider: .disabled),
                memoryStorePath: self.temporaryMemoryStorePath(),
                enableLocalSafeTools: true))

        let request = GatewayRequestFrame(
            id: "telegram-send-1",
            method: "node.invoke",
            params: .object([
                "command": .string("telegram.send"),
                "params": .object([
                    "text": .string("hello"),
                    "chatId": .string("123"),
                ]),
            ]))

        let response = await router.handle(request, nowMs: 1_700_000_003_900)
        XCTAssertEqual(response?.ok, false)
        XCTAssertEqual(response?.error?.code, GatewayCoreErrorCode.upstreamRequired.rawValue)
        XCTAssertTrue(
            response?.error?.message.contains("bot token is not configured") == true,
            "expected missing bot token hint")
    }

    func testDirectWebRenderUsesLocalFallbackWithoutForwarder() async throws {
        let router = try GatewayLocalMethodRouter(
            config: GatewayLocalMethodRouterConfig(
                hostLabel: "unit-test",
                upstreamConfigured: false,
                llmConfig: GatewayLocalLLMConfig(provider: .disabled),
                memoryStorePath: self.temporaryMemoryStorePath(),
                enableLocalSafeTools: true))

        let request = GatewayRequestFrame(
            id: "web-render-1",
            method: "web.render",
            params: .object([
                "html": .string("""
                <html><head><title>News</title></head><body><div id="__next"></div>
                <script>window.__NEXT_DATA__={"props":{"pageProps":{"headline":"Rendered headline from hydration payload","summary":"World market and policy updates from overnight sessions."}}};</script>
                </body></html>
                """),
            ]))
        let response = await router.handle(request, nowMs: 1_700_000_003_710)
        XCTAssertEqual(response?.ok, true)
        XCTAssertEqual(response?.payload?.objectValue?["source"]?.stringValue, "local-minimal-render")
        let text = response?.payload?.objectValue?["text"]?.stringValue ?? ""
        XCTAssertTrue(text.contains("Rendered headline from hydration payload"))
        XCTAssertTrue(text.contains("World market and policy updates from overnight sessions."))
    }

    func testAdminConfigAndRestartMethods() async throws {
        let adminBridge = StubAdminBridge()
        let router = try GatewayLocalMethodRouter(
            config: GatewayLocalMethodRouterConfig(
                hostLabel: "unit-test",
                upstreamConfigured: false,
                llmConfig: GatewayLocalLLMConfig(provider: .disabled),
                memoryStorePath: self.temporaryMemoryStorePath(),
                enableLocalSafeTools: true,
                adminBridge: adminBridge))

        let getRequest = GatewayRequestFrame(id: "cfg-get-1", method: "config.get")
        let getResponse = await router.handle(getRequest, nowMs: 1_700_000_001_600)
        XCTAssertEqual(getResponse?.ok, true)
        XCTAssertEqual(getResponse?.payload?.objectValue?["authMode"]?.stringValue, "none")

        let setRequest = GatewayRequestFrame(
            id: "cfg-set-1",
            method: "config.set",
            params: .object([
                "authMode": .string("token"),
                "authToken": .string("secret"),
                "upstreamURL": .string("ws://example:18789"),
            ]))
        let setResponse = await router.handle(setRequest, nowMs: 1_700_000_001_650)
        XCTAssertEqual(setResponse?.ok, true)
        XCTAssertEqual(setResponse?.payload?.objectValue?["applied"]?.boolValue, true)

        let getResponseAfterSet = await router.handle(getRequest, nowMs: 1_700_000_001_700)
        XCTAssertEqual(getResponseAfterSet?.ok, true)
        XCTAssertEqual(getResponseAfterSet?.payload?.objectValue?["authMode"]?.stringValue, "token")
        XCTAssertEqual(
            getResponseAfterSet?.payload?.objectValue?["upstreamURL"]?.stringValue,
            "ws://example:18789")

        let restartRequest = GatewayRequestFrame(id: "cfg-restart-1", method: "runtime.restart")
        let restartResponse = await router.handle(restartRequest, nowMs: 1_700_000_001_750)
        XCTAssertEqual(restartResponse?.ok, true)
        XCTAssertEqual(restartResponse?.payload?.objectValue?["restarted"]?.boolValue, true)

        let pairingListRequest = GatewayRequestFrame(
            id: "pair-list-1",
            method: "pairing.list",
            params: .object([
                "channel": .string("telegram"),
            ]))
        let pairingListResponse = await router.handle(pairingListRequest, nowMs: 1_700_000_001_760)
        XCTAssertEqual(pairingListResponse?.ok, true)
        XCTAssertEqual(pairingListResponse?.payload?.objectValue?["channel"]?.stringValue, "telegram")
        XCTAssertEqual(pairingListResponse?.payload?.objectValue?["requestCount"]?.int64Value, 1)

        let pairingApproveRequest = GatewayRequestFrame(
            id: "pair-approve-1",
            method: "pairing.approve",
            params: .object([
                "channel": .string("telegram"),
                "code": .string("ABCDEFGH"),
            ]))
        let pairingApproveResponse = await router.handle(pairingApproveRequest, nowMs: 1_700_000_001_770)
        XCTAssertEqual(pairingApproveResponse?.ok, true)
        XCTAssertEqual(pairingApproveResponse?.payload?.objectValue?["approved"]?.boolValue, true)
    }

    func testAgentsRunEmitsSnapshotAndCompletes() async throws {
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

        let runRequest = GatewayRequestFrame(
            id: "run-1",
            method: "agents.run",
            params: .object([
                "runId": .string("run-local-1"),
                "sessionKey": .string("agent-session"),
                "goal": .string("Summarize startup sequence"),
                "steps": .array([
                    .object([
                        "type": .string("llm"),
                        "prompt": .string("step one"),
                    ]),
                ]),
            ]))

        let runResponse = await router.handle(runRequest, nowMs: 1_700_000_000_100)
        XCTAssertEqual(runResponse?.ok, true)
        guard let started = try self.decodePayload(runResponse?.payload, as: GatewayAgentRunSnapshot.self) else {
            XCTFail("expected agents.run snapshot")
            return
        }
        XCTAssertEqual(started.runId, "run-local-1")
        XCTAssertEqual(started.status, .queued)

        let statusRequest = GatewayRequestFrame(
            id: "run-status-1",
            method: "agents.status",
            params: .object(["runId": .string(started.runId)]))

        var terminalStatus: GatewayAgentRunStatus?
        for _ in 0..<50 {
            if let statusResponse = await router.handle(statusRequest, nowMs: 1_700_000_000_200),
               statusResponse.ok,
               let status = try self.decodePayload(statusResponse.payload, as: GatewayAgentRunSnapshot.self)
            {
                terminalStatus = status.status
                if status.status == .completed || status.status == .failed || status.status == .aborted {
                    break
                }
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(terminalStatus, .completed)
        let providerCalls = await llmProvider.observedRequestCount()
        XCTAssertEqual(providerCalls, 1)
    }

    func testAgentsStatusAndAbortWorkflow() async throws {
        let probe = ConcurrencyProbe()
        let llmProvider = DelayedLLMProvider(delayMs: 250, concurrencyProbe: probe)
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

        let runRequest = GatewayRequestFrame(
            id: "run-abort-1",
            method: "agents.run",
            params: .object([
                "runId": .string("run-abort-1"),
                "sessionKey": .string("agent-session"),
                "goal": .string("Long run for abort"),
                "steps": .array([
                    .object([
                        "type": .string("llm"),
                        "prompt": .string("hold"),
                    ]),
                    .object([
                        "type": .string("llm"),
                        "prompt": .string("still running"),
                    ]),
                ]),
            ]))
        _ = await router.handle(runRequest, nowMs: 1_700_000_001_000)

        let abortRequest = GatewayRequestFrame(
            id: "run-abort-2",
            method: "agents.abort",
            params: .object(["runId": .string("run-abort-1")]))
        let abortResponse = await router.handle(abortRequest, nowMs: 1_700_000_001_010)
        XCTAssertEqual(abortResponse?.ok, true)

        try await Task.sleep(for: .milliseconds(20))
        let statusRequest = GatewayRequestFrame(
            id: "run-status-2",
            method: "agents.status",
            params: .object(["runId": .string("run-abort-1")]))
        let statusResponse = await router.handle(statusRequest, nowMs: 1_700_000_001_050)
        let status = try self.decodePayload(statusResponse?.payload, as: GatewayAgentRunSnapshot.self)
        XCTAssertEqual(status?.status, .aborted)
    }

    func testAgentsRunSerializesPerSessionWork() async throws {
        let probe = ConcurrencyProbe()
        let llmProvider = DelayedLLMProvider(delayMs: 120, concurrencyProbe: probe)
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

        let steps: GatewayJSONValue = .array([
            .object([
                "type": .string("llm"),
                "prompt": .string("first"),
            ]),
            .object([
                "type": .string("llm"),
                "prompt": .string("second"),
            ]),
        ])
        let runRequestA = GatewayRequestFrame(
            id: "run-serial-a",
            method: "agents.run",
            params: .object([
                "runId": .string("run-serial-a"),
                "sessionKey": .string("same-session"),
                "goal": .string("sequence one"),
                "steps": steps,
            ]))
        let runRequestB = GatewayRequestFrame(
            id: "run-serial-b",
            method: "agents.run",
            params: .object([
                "runId": .string("run-serial-b"),
                "sessionKey": .string("same-session"),
                "goal": .string("sequence two"),
                "steps": steps,
            ]))

        _ = await router.handle(runRequestA, nowMs: 1_700_000_001_100)
        _ = await router.handle(runRequestB, nowMs: 1_700_000_001_110)

        try await Task.sleep(for: .milliseconds(600))
        let maxActive = await probe.maxObserved()
        XCTAssertEqual(maxActive, 1)

        let requestA = GatewayRequestFrame(id: "run-status-a", method: "agents.status", params: .object(["runId": .string("run-serial-a")]))
        let requestB = GatewayRequestFrame(id: "run-status-b", method: "agents.status", params: .object(["runId": .string("run-serial-b")]))
        let statusA = await router.handle(requestA, nowMs: 1_700_000_001_200)
        let statusB = await router.handle(requestB, nowMs: 1_700_000_001_300)
        let snapshotA = try self.decodePayload(statusA?.payload, as: GatewayAgentRunSnapshot.self)
        let snapshotB = try self.decodePayload(statusB?.payload, as: GatewayAgentRunSnapshot.self)
        XCTAssertEqual(snapshotA?.status, .completed)
        XCTAssertEqual(snapshotB?.status, .completed)
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

    // MARK: - Device Tool Bridge Stub

    private actor StubDeviceToolBridge: GatewayDeviceToolBridge {
        nonisolated func supportedCommands() -> [String] {
            [
                "reminders.list", "reminders.add",
                "calendar.events", "calendar.add",
                "contacts.search", "contacts.add",
                "location.get", "photos.latest",
                "camera.snap",
                "motion.activity", "motion.pedometer",
            ]
        }

        private var callLog: [(command: String, params: GatewayJSONValue?)] = []

        func execute(
            command: String,
            params: GatewayJSONValue?) async -> GatewayLocalTooling.ToolResult
        {
            self.callLog.append((command, params))
            return GatewayLocalTooling.ToolResult(
                payload: .object([
                    "ok": .bool(true),
                    "command": .string(command),
                    "stub": .bool(true),
                ]),
                error: nil)
        }

        func observedCallLog() -> [(String, GatewayJSONValue?)] {
            self.callLog.map { ($0.command, $0.params) }
        }
    }

    // MARK: - Device Tool Tests

    func testDeviceToolExecutionRoutesThroughBridge() async {
        let bridge = StubDeviceToolBridge()
        let result = await GatewayLocalTooling.execute(
            command: "reminders.list",
            params: .object(["limit": .integer(5)]),
            hostLabel: "test",
            workspaceRoot: nil,
            urlSession: URLSession(
                configuration: .ephemeral),
            enableLocalSafeTools: true,
            enableLocalFileTools: false,
            enableLocalDeviceTools: true,
            deviceToolBridge: bridge)
        XCTAssertNil(result.error)
        XCTAssertEqual(
            result.payload.objectValue?["ok"]?.boolValue,
            true)
        XCTAssertEqual(
            result.payload.objectValue?["command"]?
                .stringValue,
            "reminders.list")
        let calls = await bridge.observedCallLog()
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls.first?.0, "reminders.list")
    }

    func testDeviceToolDisabledReturnsError() async {
        let bridge = StubDeviceToolBridge()
        let result = await GatewayLocalTooling.execute(
            command: "reminders.list",
            params: nil,
            hostLabel: "test",
            workspaceRoot: nil,
            urlSession: URLSession(
                configuration: .ephemeral),
            enableLocalSafeTools: true,
            enableLocalFileTools: false,
            enableLocalDeviceTools: false,
            deviceToolBridge: bridge)
        XCTAssertNotNil(result.error)
        let calls = await bridge.observedCallLog()
        XCTAssertEqual(calls.count, 0)
    }

    func testDeviceToolNoBridgeReturnsError() async {
        let result = await GatewayLocalTooling.execute(
            command: "reminders.list",
            params: nil,
            hostLabel: "test",
            workspaceRoot: nil,
            urlSession: URLSession(
                configuration: .ephemeral),
            enableLocalSafeTools: true,
            enableLocalFileTools: false,
            enableLocalDeviceTools: true,
            deviceToolBridge: nil)
        XCTAssertNotNil(result.error)
    }

    func testDeviceToolAllCommandsRecognized() {
        let expected: [String] = [
            "reminders.list", "reminders.add",
            "calendar.events", "calendar.add",
            "contacts.search", "contacts.add",
            "location.get", "photos.latest",
            "camera.snap",
            "motion.activity", "motion.pedometer",
        ]
        for command in expected {
            XCTAssertTrue(
                GatewayLocalTooling.deviceCommands
                    .contains(command),
                "\(command) not in deviceCommands")
        }
    }

    func testSkillRegistryFilterBootstrapFiles() {
        var registry = GatewaySkillRegistry(
            version: 1,
            skills: [
                GatewaySkillEntry(
                    id: "news",
                    fileName: "JS_NEWS.md",
                    enabled: true),
                GatewaySkillEntry(
                    id: "calc",
                    fileName: "CALCULATOR.md",
                    enabled: false),
            ])

        let input = [
            "SOUL.md", "JS_NEWS.md",
            "CALCULATOR.md", "TOOLS.md",
        ]
        let filtered = registry.filterFileNames(input)
        XCTAssertEqual(
            filtered,
            ["SOUL.md", "JS_NEWS.md", "TOOLS.md"])

        registry.setEnabled("calc", enabled: true)
        let filtered2 = registry.filterFileNames(input)
        XCTAssertEqual(filtered2, input)
    }

    func testSkillRegistryEnableDisable() {
        var registry = GatewaySkillRegistry(
            version: 1,
            skills: [
                GatewaySkillEntry(
                    id: "a", fileName: "A.md",
                    enabled: true),
                GatewaySkillEntry(
                    id: "b", fileName: "B.md",
                    enabled: true),
            ])
        XCTAssertEqual(
            registry.enabledFileNames,
            ["A.md", "B.md"])

        registry.setEnabled("a", enabled: false)
        XCTAssertEqual(registry.enabledFileNames, ["B.md"])

        registry.setEnabled("a", enabled: true)
        XCTAssertEqual(
            registry.enabledFileNames,
            ["A.md", "B.md"])
    }
}

private struct ChatHistoryPayload: Decodable {
    let sessionKey: String
    let thinkingLevel: String?
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

private struct SessionsListPayload: Decodable {
    let sessions: [SessionListEntry]
}

private struct SessionListEntry: Decodable {
    let key: String
    let thinkingLevel: String?
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
    let localFileCommands: [String]?
    let upstreamOnlyPrefixRules: [String]
}

private struct MemorySearchPayload: Decodable {
    let query: String
    let results: [MemorySearchResult]
}

private struct MemorySearchResult: Decodable {
    let id: String
    let source: String?
    let file: String?
    let text: String
}

private struct MemoryGetPayload: Decodable {
    let id: String
    let source: String?
    let file: String?
    let text: String
}

private struct MemoryWritePayload: Decodable {
    let path: String
    let source: String?
    let append: Bool?
}
