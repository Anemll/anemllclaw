import OpenClawChatUI
import OpenClawKit
import OpenClawProtocol
import Foundation
import OSLog

struct OpenAIWebSocketChatTransport: OpenClawChatTransport, Sendable {
    fileprivate static let logger = Logger(subsystem: "ai.openclaw", category: "ios.chat.openaiws")
    private let state: OpenAIWebSocketChatState

    init(apiKey: String, model: String) {
        self.state = OpenAIWebSocketChatState(
            apiKey: apiKey,
            model: model)
    }

    func requestHistory(sessionKey: String) async throws -> OpenClawChatHistoryPayload {
        try await self.state.requestHistory(sessionKey: sessionKey)
    }

    func sendMessage(
        sessionKey: String,
        message: String,
        thinking: String,
        idempotencyKey: String,
        attachments: [OpenClawChatAttachmentPayload]) async throws -> OpenClawChatSendResponse
    {
        try await self.state.sendMessage(
            sessionKey: sessionKey,
            message: message,
            thinking: thinking,
            idempotencyKey: idempotencyKey,
            attachments: attachments)
    }

    func abortRun(sessionKey: String, runId: String) async throws {
        await self.state.abortRun(sessionKey: sessionKey, runId: runId)
    }

    func listSessions(limit: Int?) async throws -> OpenClawChatSessionsListResponse {
        try await self.state.listSessions(limit: limit)
    }

    func requestHealth(timeoutMs _: Int) async throws -> Bool {
        // The transport is local; per-request failures are surfaced in sendMessage.
        true
    }

    func events() -> AsyncStream<OpenClawChatTransportEvent> {
        self.state.makeEventStream()
    }
}

actor OpenAIWebSocketChatState {
    private static let websocketURL = URL(string: "wss://api.openai.com/v1/responses")!
    private static let responsesURL = URL(string: "https://api.openai.com/v1/responses")!
    private static let websocketBetaHeader = "responses_websockets=2026-02-06"

    private let apiKey: String
    private let model: String
    private var historiesBySessionKey: [String: [AnyCodable]] = [:]
    private var thinkingBySessionKey: [String: String] = [:]
    private var sessionIdsByKey: [String: String] = [:]
    private var sessionUpdatedAtByKey: [String: Double] = [:]
    private var continuations: [UUID: AsyncStream<OpenClawChatTransportEvent>.Continuation] = [:]
    private var runTasks: [String: Task<Void, Never>] = [:]

    init(apiKey: String, model: String) {
        self.apiKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedModel = model.trimmingCharacters(in: .whitespacesAndNewlines)
        self.model = trimmedModel.isEmpty ? ChatTransportPreferences.defaultOpenAIModel : trimmedModel
    }

    nonisolated func makeEventStream() -> AsyncStream<OpenClawChatTransportEvent> {
        AsyncStream { continuation in
            let streamID = UUID()
            Task { await self.registerContinuation(id: streamID, continuation: continuation) }
            continuation.onTermination = { @Sendable _ in
                Task { await self.unregisterContinuation(id: streamID) }
            }
        }
    }

    func requestHistory(sessionKey: String) throws -> OpenClawChatHistoryPayload {
        let sessionID = self.resolveSessionId(for: sessionKey)
        let messages = self.historiesBySessionKey[sessionKey] ?? []
        let thinking = self.thinkingBySessionKey[sessionKey] ?? "off"
        let payload = ChatHistoryPayloadEnvelope(
            sessionKey: sessionKey,
            sessionId: sessionID,
            messages: messages,
            thinkingLevel: thinking)
        return try Self.decodeEnvelope(payload, as: OpenClawChatHistoryPayload.self)
    }

    func listSessions(limit: Int?) throws -> OpenClawChatSessionsListResponse {
        let now = Date().timeIntervalSince1970 * 1000
        var entries = self.sessionUpdatedAtByKey
            .map { key, updatedAt in
                ChatSessionEntryEnvelope(
                    key: key,
                    updatedAt: updatedAt,
                    sessionId: self.sessionIdsByKey[key],
                    thinkingLevel: self.thinkingBySessionKey[key],
                    model: self.model)
            }
            .sorted { ($0.updatedAt ?? 0) > ($1.updatedAt ?? 0) }

        if entries.isEmpty {
            entries = [
                ChatSessionEntryEnvelope(
                    key: "main",
                    updatedAt: now,
                    sessionId: self.resolveSessionId(for: "main"),
                    thinkingLevel: self.thinkingBySessionKey["main"] ?? "off",
                    model: self.model),
            ]
        }

        if let limit, limit > 0, entries.count > limit {
            entries = Array(entries.prefix(limit))
        }

        let payload = ChatSessionsListPayloadEnvelope(
            ts: now,
            path: "openai-websocket",
            count: entries.count,
            defaults: nil,
            sessions: entries)
        return try Self.decodeEnvelope(payload, as: OpenClawChatSessionsListResponse.self)
    }

    func sendMessage(
        sessionKey: String,
        message: String,
        thinking: String,
        idempotencyKey: String,
        attachments: [OpenClawChatAttachmentPayload]) throws -> OpenClawChatSendResponse
    {
        let trimmedMessage = message.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedMessage.isEmpty {
            throw Self.chatError("message cannot be empty")
        }
        if !attachments.isEmpty {
            throw Self.chatError("OpenAI WebSocket mode currently supports text messages only.")
        }
        if self.apiKey.isEmpty {
            throw Self.chatError("OpenAI API key is missing. Set it in Settings > Device > Features.")
        }

        self.appendTextMessage(sessionKey: sessionKey, role: "user", text: trimmedMessage)
        self.thinkingBySessionKey[sessionKey] = thinking
        self.resolveSessionId(for: sessionKey)

        let runId = idempotencyKey
        let apiKey = self.apiKey
        let model = self.model
        let thinkingForRun = thinking

        let runTask = Task {
            do {
                let reply = try await Self.generateAssistantReply(
                    apiKey: apiKey,
                    model: model,
                    prompt: trimmedMessage,
                    thinking: thinkingForRun)
                if Task.isCancelled {
                    await self.emitChatState(runId: runId, sessionKey: sessionKey, state: "aborted")
                } else {
                    await self.appendTextMessage(sessionKey: sessionKey, role: "assistant", text: reply)
                    await self.emitChatState(runId: runId, sessionKey: sessionKey, state: "final")
                }
            } catch is CancellationError {
                await self.emitChatState(runId: runId, sessionKey: sessionKey, state: "aborted")
            } catch {
                await self.emitChatState(
                    runId: runId,
                    sessionKey: sessionKey,
                    state: "error",
                    errorMessage: error.localizedDescription)
            }
            await self.finishRun(runId: runId)
        }
        self.runTasks[runId] = runTask

        let ack = ChatSendResponseEnvelope(runId: runId, status: "started")
        return try Self.decodeEnvelope(ack, as: OpenClawChatSendResponse.self)
    }

    func abortRun(sessionKey: String, runId: String) {
        self.runTasks[runId]?.cancel()
        self.runTasks[runId] = nil
        self.emitChatState(runId: runId, sessionKey: sessionKey, state: "aborted")
    }

    private func resolveSessionId(for sessionKey: String) -> String {
        if let existing = self.sessionIdsByKey[sessionKey] {
            return existing
        }
        let fresh = "openaiws-\(UUID().uuidString.lowercased())"
        self.sessionIdsByKey[sessionKey] = fresh
        return fresh
    }

    private func appendTextMessage(sessionKey: String, role: String, text: String) {
        let now = Date().timeIntervalSince1970 * 1000
        let message: [String: Any] = [
            "role": role,
            "content": [
                [
                    "type": "text",
                    "text": text,
                ],
            ],
            "timestamp": now,
        ]
        var history = self.historiesBySessionKey[sessionKey] ?? []
        history.append(AnyCodable(message))
        self.historiesBySessionKey[sessionKey] = history
        self.sessionUpdatedAtByKey[sessionKey] = now
    }

    private func emitChatState(
        runId: String,
        sessionKey: String,
        state: String,
        errorMessage: String? = nil)
    {
        let payload = ChatEventPayloadEnvelope(
            runId: runId,
            sessionKey: sessionKey,
            state: state,
            message: nil,
            errorMessage: errorMessage)
        guard let chatPayload = try? Self.decodeEnvelope(payload, as: OpenClawChatEventPayload.self) else {
            return
        }
        self.broadcast(.chat(chatPayload))
    }

    private func registerContinuation(
        id: UUID,
        continuation: AsyncStream<OpenClawChatTransportEvent>.Continuation)
    {
        self.continuations[id] = continuation
        continuation.yield(.health(ok: true))
        continuation.yield(.tick)
    }

    private func unregisterContinuation(id: UUID) {
        self.continuations[id] = nil
    }

    private func broadcast(_ event: OpenClawChatTransportEvent) {
        for continuation in self.continuations.values {
            continuation.yield(event)
        }
    }

    private func finishRun(runId: String) {
        self.runTasks[runId] = nil
    }

    private nonisolated static func generateAssistantReply(
        apiKey: String,
        model: String,
        prompt: String,
        thinking: String) async throws -> String
    {
        do {
            return try await self.requestViaWebSocket(
                apiKey: apiKey,
                model: model,
                prompt: prompt,
                thinking: thinking)
        } catch {
            OpenAIWebSocketChatTransport.logger.warning(
                "openai websocket failed, falling back to HTTP: \(error.localizedDescription, privacy: .public)")
            return try await self.requestViaHTTP(
                apiKey: apiKey,
                model: model,
                prompt: prompt,
                thinking: thinking)
        }
    }

    private nonisolated static func requestViaWebSocket(
        apiKey: String,
        model: String,
        prompt: String,
        thinking: String) async throws -> String
    {
        var request = URLRequest(url: self.websocketURL)
        request.timeoutInterval = 60
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(self.websocketBetaHeader, forHTTPHeaderField: "OpenAI-Beta")

        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 120
        let session = URLSession(configuration: config)
        let socket = session.webSocketTask(with: request)
        socket.resume()

        defer {
            socket.cancel(with: .normalClosure, reason: nil)
            session.invalidateAndCancel()
        }

        let responsePayload = self.buildResponsesPayload(
            model: model,
            prompt: prompt,
            thinking: thinking,
            stream: true)
        let wsPayload: [String: Any] = [
            "type": "response.create",
            "response": responsePayload,
        ]
        let payloadData = try JSONSerialization.data(withJSONObject: wsPayload, options: [])
        guard let payloadText = String(data: payloadData, encoding: .utf8) else {
            throw self.chatError("failed to encode websocket payload")
        }
        try await socket.send(.string(payloadText))

        var accumulated = ""
        var completedResponse: [String: Any]?
        var sawCompletion = false

        do {
            while true {
                if Task.isCancelled {
                    socket.cancel(with: .goingAway, reason: nil)
                    throw CancellationError()
                }

                let frame = try await socket.receive()
                let text: String
                switch frame {
                case let .string(value):
                    text = value
                case let .data(data):
                    text = String(data: data, encoding: .utf8) ?? ""
                @unknown default:
                    continue
                }
                guard !text.isEmpty else { continue }
                guard let event = self.decodeJSONObject(from: text) else { continue }

                switch self.handleWebSocketEvent(
                    event,
                    accumulated: &accumulated,
                    completedResponse: &completedResponse)
                {
                case .none:
                    break
                case let .completed(text):
                    sawCompletion = true
                    if let text {
                        return text
                    }
                    throw self.chatError("OpenAI completed without output text")
                case let .failed(message):
                    throw self.chatError(message)
                }
            }
        } catch {
            if sawCompletion {
                let trimmed = accumulated.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    return trimmed
                }
            }
            throw error
        }
    }

    private nonisolated static func handleWebSocketEvent(
        _ event: [String: Any],
        accumulated: inout String,
        completedResponse: inout [String: Any]?) -> WebSocketEventOutcome
    {
        let type = (event["type"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        switch type {
        case "response.output_text.delta":
            if let delta = event["delta"] as? String {
                accumulated += delta
            }
            return .none
        case "response.output_text.done":
            if accumulated.isEmpty, let textChunk = event["text"] as? String {
                accumulated = textChunk
            }
            return .none
        case "response.completed", "response.done":
            if let response = event["response"] as? [String: Any] {
                completedResponse = response
            }
            if accumulated.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                if let response = completedResponse {
                    accumulated = self.extractResponseText(from: response)
                }
                if accumulated.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    accumulated = self.extractResponseText(from: event)
                }
            }
            let trimmed = accumulated.trimmingCharacters(in: .whitespacesAndNewlines)
            return .completed(trimmed.isEmpty ? nil : trimmed)
        case "error", "response.failed":
            return .failed(self.extractErrorMessage(from: event) ?? "OpenAI WebSocket request failed")
        default:
            if type.hasSuffix(".delta"), let delta = event["delta"] as? String {
                accumulated += delta
            }
            return .none
        }
    }

    private nonisolated static func requestViaHTTP(
        apiKey: String,
        model: String,
        prompt: String,
        thinking: String) async throws -> String
    {
        var request = URLRequest(url: self.responsesURL)
        request.httpMethod = "POST"
        request.timeoutInterval = 60
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let payload = self.buildResponsesPayload(
            model: model,
            prompt: prompt,
            thinking: thinking,
            stream: false)
        request.httpBody = try JSONSerialization.data(withJSONObject: payload, options: [])

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw self.chatError("OpenAI HTTP response was invalid")
        }

        if !(200...299).contains(http.statusCode) {
            let message = self.extractErrorMessage(from: data) ??
                "OpenAI HTTP request failed with status \(http.statusCode)"
            throw self.chatError(message)
        }

        guard
            let root = try JSONSerialization.jsonObject(with: data, options: []) as? [String: Any]
        else {
            throw self.chatError("OpenAI HTTP response was not valid JSON")
        }

        let text = self.extractResponseText(from: root).trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty {
            throw self.chatError("OpenAI HTTP response did not include output text")
        }
        return text
    }

    private nonisolated static func buildResponsesPayload(
        model: String,
        prompt: String,
        thinking: String,
        stream: Bool) -> [String: Any]
    {
        var payload: [String: Any] = [
            "model": model,
            "input": [
                [
                    "role": "user",
                    "content": [
                        [
                            "type": "input_text",
                            "text": prompt,
                        ],
                    ],
                ],
            ],
        ]
        if stream {
            payload["stream"] = true
        }
        if let effort = self.resolveReasoningEffort(from: thinking) {
            payload["reasoning"] = ["effort": effort]
        }
        return payload
    }

    private nonisolated static func resolveReasoningEffort(from thinking: String) -> String? {
        switch thinking.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "minimal":
            "minimal"
        case "low":
            "low"
        case "medium":
            "medium"
        case "high", "xhigh":
            "high"
        default:
            nil
        }
    }

    private nonisolated static func decodeJSONObject(from text: String) -> [String: Any]? {
        guard let data = text.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any]
    }

    private nonisolated static func extractResponseText(from object: [String: Any]) -> String {
        if let direct = object["output_text"] as? String, !direct.isEmpty {
            return direct
        }
        if let texts = object["output_text"] as? [String], !texts.isEmpty {
            return texts.joined()
        }
        if let response = object["response"] as? [String: Any] {
            let nested = self.extractResponseText(from: response)
            if !nested.isEmpty { return nested }
        }

        guard let output = object["output"] as? [Any] else { return "" }
        var chunks: [String] = []
        for entry in output {
            guard let item = entry as? [String: Any] else { continue }
            let itemType = (item["type"] as? String)?.lowercased() ?? ""
            let role = (item["role"] as? String)?.lowercased() ?? ""
            guard itemType == "message" || role == "assistant" else { continue }

            if let text = item["text"] as? String, !text.isEmpty {
                chunks.append(text)
            }
            guard let content = item["content"] as? [Any] else { continue }
            for contentItem in content {
                guard let block = contentItem as? [String: Any] else { continue }
                let blockType = (block["type"] as? String)?.lowercased() ?? ""
                if blockType == "output_text" || blockType == "text",
                   let blockText = block["text"] as? String,
                   !blockText.isEmpty
                {
                    chunks.append(blockText)
                }
            }
        }
        return chunks.joined()
    }

    private nonisolated static func extractErrorMessage(from event: [String: Any]) -> String? {
        if let message = event["message"] as? String, !message.isEmpty {
            return message
        }
        if let error = event["error"] as? String, !error.isEmpty {
            return error
        }
        if let error = event["error"] as? [String: Any] {
            if let message = error["message"] as? String, !message.isEmpty {
                return message
            }
            if let code = error["code"] as? String, !code.isEmpty {
                return code
            }
        }
        if let response = event["response"] as? [String: Any],
           let error = response["error"] as? [String: Any],
           let message = error["message"] as? String,
           !message.isEmpty
        {
            return message
        }
        return nil
    }

    private nonisolated static func extractErrorMessage(from data: Data) -> String? {
        guard let root = try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any] else {
            let plain = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
            return plain?.isEmpty == false ? plain : nil
        }
        return self.extractErrorMessage(from: root)
    }

    private nonisolated static func chatError(_ message: String) -> NSError {
        NSError(
            domain: "OpenAIWebSocketChatTransport",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: message])
    }

    private nonisolated static func decodeEnvelope<Envelope: Encodable, Decoded: Decodable>(
        _ envelope: Envelope,
        as decoded: Decoded.Type) throws -> Decoded
    {
        let data = try JSONEncoder().encode(envelope)
        return try JSONDecoder().decode(decoded, from: data)
    }
}

private struct ChatSendResponseEnvelope: Encodable {
    let runId: String
    let status: String
}

private struct ChatEventPayloadEnvelope: Encodable {
    let runId: String?
    let sessionKey: String?
    let state: String?
    let message: AnyCodable?
    let errorMessage: String?
}

private struct ChatHistoryPayloadEnvelope: Encodable {
    let sessionKey: String
    let sessionId: String?
    let messages: [AnyCodable]?
    let thinkingLevel: String?
}

private struct ChatSessionsListPayloadEnvelope: Encodable {
    let ts: Double?
    let path: String?
    let count: Int?
    let defaults: ChatSessionsDefaultsEnvelope?
    let sessions: [ChatSessionEntryEnvelope]
}

private struct ChatSessionsDefaultsEnvelope: Encodable {
    let model: String?
    let contextTokens: Int?
}

private struct ChatSessionEntryEnvelope: Encodable {
    let key: String
    let updatedAt: Double?
    let sessionId: String?
    let thinkingLevel: String?
    let model: String?
}

private enum WebSocketEventOutcome {
    case none
    case completed(String?)
    case failed(String)
}
