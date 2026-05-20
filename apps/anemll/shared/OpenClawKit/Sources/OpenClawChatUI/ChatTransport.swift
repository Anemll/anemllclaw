import Foundation

public enum OpenClawChatTransportEvent: Sendable {
    case health(ok: Bool)
    case tick
    case chat(OpenClawChatEventPayload)
    case agent(OpenClawAgentEventPayload)
    case seqGap
}

public protocol OpenClawChatTransport: Sendable {
    var supportsRealtimeRunEvents: Bool { get }

    func requestHistory(sessionKey: String) async throws -> OpenClawChatHistoryPayload
    func sendMessage(
        sessionKey: String,
        message: String,
        thinking: String,
        idempotencyKey: String,
        attachments: [OpenClawChatAttachmentPayload]) async throws -> OpenClawChatSendResponse

    func abortRun(sessionKey: String, runId: String) async throws
    func listSessions(limit: Int?) async throws -> OpenClawChatSessionsListResponse

    func requestHealth(timeoutMs: Int) async throws -> Bool
    func events() -> AsyncStream<OpenClawChatTransportEvent>

    func setActiveSessionKey(_ sessionKey: String) async throws

    func deleteSession(sessionKey: String) async throws
    func renameSession(sessionKey: String, displayName: String) async throws
    func updateSessionSettings(sessionKey: String, preferredProviderID: String?, thinkingLevel: String?) async throws
}

extension OpenClawChatTransport {
    public var supportsRealtimeRunEvents: Bool {
        true
    }

    public func setActiveSessionKey(_: String) async throws {}

    public func abortRun(sessionKey _: String, runId _: String) async throws {
        throw NSError(
            domain: "OpenClawChatTransport",
            code: 0,
            userInfo: [NSLocalizedDescriptionKey: "chat.abort not supported by this transport"])
    }

    public func listSessions(limit _: Int?) async throws -> OpenClawChatSessionsListResponse {
        throw NSError(
            domain: "OpenClawChatTransport",
            code: 0,
            userInfo: [NSLocalizedDescriptionKey: "sessions.list not supported by this transport"])
    }

    public func deleteSession(sessionKey _: String) async throws {
        throw NSError(
            domain: "OpenClawChatTransport",
            code: 0,
            userInfo: [NSLocalizedDescriptionKey: "sessions.delete not supported by this transport"])
    }

    public func renameSession(sessionKey _: String, displayName _: String) async throws {
        throw NSError(
            domain: "OpenClawChatTransport",
            code: 0,
            userInfo: [NSLocalizedDescriptionKey: "sessions.rename not supported by this transport"])
    }

    public func updateSessionSettings(
        sessionKey _: String, preferredProviderID _: String?, thinkingLevel _: String?) async throws
    {
        throw NSError(
            domain: "OpenClawChatTransport",
            code: 0,
            userInfo: [NSLocalizedDescriptionKey: "sessions.update not supported by this transport"])
    }
}
