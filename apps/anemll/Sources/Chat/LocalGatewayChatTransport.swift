#if os(iOS) || os(tvOS)
import Foundation
import OpenClawChatUI
import OpenClawGatewayCore
import OSLog

struct LocalGatewayChatTransport: OpenClawChatTransport, Sendable {
    private static let logger = Logger(subsystem: "ai.openclaw", category: "local.chat.transport")
    private let resolveHost: @Sendable () async -> GatewayLoopbackHost?
    private let refreshOAuthIfNeeded: @Sendable () async -> Void
    var supportsRealtimeRunEvents: Bool {
        false
    }

    init(host: GatewayLoopbackHost) {
        let captured = host
        self.resolveHost = { captured }
        self.refreshOAuthIfNeeded = {}
    }

    init(runtime: TVOSLocalGatewayRuntime) {
        self.resolveHost = { @MainActor in runtime.host }
        self.refreshOAuthIfNeeded = { @MainActor in
            await runtime.refreshActiveProviderOAuthIfNeeded()
        }
    }

    // MARK: - OpenClawChatTransport

    func requestHistory(sessionKey: String) async throws -> OpenClawChatHistoryPayload {
        let request = GatewayRequestFrame(
            id: UUID().uuidString,
            method: "chat.history",
            params: .object(["sessionKey": .string(sessionKey)]))
        let response = try await self.currentHost().invoke(request)
        return try Self.decode(response)
    }

    func sendMessage(
        sessionKey: String,
        message: String,
        thinking: String,
        idempotencyKey: String,
        attachments: [OpenClawChatAttachmentPayload]) async throws -> OpenClawChatSendResponse
    {
        Self.logger.info(
            "chat.send start sessionKey=\(sessionKey, privacy: .public) len=\(message.count, privacy: .public) attachments=\(attachments.count, privacy: .public)")

        // Refresh active OAuth token if it is near expiry. Fast no-op when the
        // token is still valid; transparently rotates the local LLM apiKey and
        // re-applies the gateway config when a refresh actually fires.
        await self.refreshOAuthIfNeeded()

        var paramsDict: [String: GatewayJSONValue] = [
            "sessionKey": .string(sessionKey),
            "message": .string(message),
            "thinking": .string(thinking),
            "idempotencyKey": .string(idempotencyKey),
            "timeoutMs": .integer(30000),
        ]

        if !attachments.isEmpty {
            let attachmentData = try JSONEncoder().encode(attachments)
            let attachmentJSON = try JSONDecoder().decode(GatewayJSONValue.self, from: attachmentData)
            paramsDict["attachments"] = attachmentJSON
        }

        let request = GatewayRequestFrame(
            id: UUID().uuidString,
            method: "chat.send",
            params: .object(paramsDict))
        do {
            let response = try await self.currentHost().invoke(request)
            let decoded: OpenClawChatSendResponse = try Self.decode(response)
            Self.logger.info("chat.send ok runId=\(decoded.runId, privacy: .public)")
            return decoded
        } catch {
            Self.logger.error("chat.send failed \(error.localizedDescription, privacy: .public)")
            throw error
        }
    }

    func abortRun(sessionKey: String, runId: String) async throws {
        let request = GatewayRequestFrame(
            id: UUID().uuidString,
            method: "chat.abort",
            params: .object([
                "sessionKey": .string(sessionKey),
                "runId": .string(runId),
            ]))
        _ = try await self.currentHost().invoke(request)
    }

    func listSessions(limit: Int?) async throws -> OpenClawChatSessionsListResponse {
        var paramsDict: [String: GatewayJSONValue] = [
            "includeGlobal": .bool(true),
            "includeUnknown": .bool(false),
        ]
        if let limit {
            paramsDict["limit"] = .integer(Int64(limit))
        }
        let request = GatewayRequestFrame(
            id: UUID().uuidString,
            method: "sessions.list",
            params: .object(paramsDict))
        let response = try await self.currentHost().invoke(request)
        return try Self.decode(response)
    }

    func deleteSession(sessionKey: String) async throws {
        let request = GatewayRequestFrame(
            id: UUID().uuidString,
            method: "sessions.delete",
            params: .object([
                "key": .string(sessionKey),
                "deleteTranscript": .bool(true),
            ]))
        let response = try await self.currentHost().invoke(request)
        guard response.ok else {
            let message = response.error?.message ?? "sessions.delete failed"
            throw NSError(
                domain: "LocalGatewayChatTransport",
                code: 0,
                userInfo: [NSLocalizedDescriptionKey: message])
        }
    }

    func renameSession(sessionKey: String, displayName: String) async throws {
        let request = GatewayRequestFrame(
            id: UUID().uuidString,
            method: "sessions.rename",
            params: .object([
                "key": .string(sessionKey),
                "displayName": .string(displayName),
            ]))
        let response = try await self.currentHost().invoke(request)
        guard response.ok else {
            let message = response.error?.message ?? "sessions.rename failed"
            throw NSError(
                domain: "LocalGatewayChatTransport",
                code: 0,
                userInfo: [NSLocalizedDescriptionKey: message])
        }
    }

    func updateSessionSettings(
        sessionKey: String, preferredProviderID: String?, thinkingLevel: String?) async throws
    {
        var paramsDict: [String: GatewayJSONValue] = [
            "key": .string(sessionKey),
        ]
        if let providerID = preferredProviderID {
            paramsDict["preferredProviderID"] = .string(providerID)
        }
        if let level = thinkingLevel {
            paramsDict["thinkingLevel"] = .string(level)
        }
        let request = GatewayRequestFrame(
            id: UUID().uuidString,
            method: "sessions.update",
            params: .object(paramsDict))
        let response = try await self.currentHost().invoke(request)
        guard response.ok else {
            let message = response.error?.message ?? "sessions.update failed"
            throw NSError(
                domain: "LocalGatewayChatTransport",
                code: 0,
                userInfo: [NSLocalizedDescriptionKey: message])
        }
    }

    func requestHealth(timeoutMs: Int) async throws -> Bool {
        let request = GatewayRequestFrame(
            id: UUID().uuidString,
            method: "health")
        let response = try await self.currentHost().invoke(request)
        guard response.ok else { return false }
        if let okValue = response.payload?.objectValue?["ok"]?.boolValue {
            return okValue
        }
        return true
    }

    func setActiveSessionKey(_ sessionKey: String) async throws {
        // Local transport does not need subscription management.
    }

    func events() -> AsyncStream<OpenClawChatTransportEvent> {
        // The local runtime does not emit server-sent events via this path.
        // The view model polls health and refreshes history after sends.
        AsyncStream { continuation in
            // Keep the stream alive; no events are produced.
            continuation.onTermination = { @Sendable _ in }
        }
    }

    // MARK: - Private

    private func currentHost() async throws -> GatewayLoopbackHost {
        guard let host = await self.resolveHost() else {
            throw GatewayLoopbackHostError.notRunning
        }
        return host
    }

    private static func decode<T: Decodable>(_ response: GatewayResponseFrame) throws -> T {
        guard response.ok else {
            let message = response.error?.message ?? "RPC failed"
            throw NSError(
                domain: "LocalGatewayChatTransport",
                code: 0,
                userInfo: [NSLocalizedDescriptionKey: "[\(response.error?.code ?? "ERR")] \(message)"])
        }
        guard let payload = response.payload else {
            throw NSError(
                domain: "LocalGatewayChatTransport",
                code: 0,
                userInfo: [NSLocalizedDescriptionKey: "No payload in response"])
        }
        let data = try JSONEncoder().encode(payload)
        return try JSONDecoder().decode(T.self, from: data)
    }
}
#endif
