import Foundation

public struct GatewaySessionSnapshot: Sendable, Equatable {
    public let sessionKey: String
    public let turnCount: Int
    public let lastActivityMs: Int64
    public let thinkingLevel: String?
    public let displayName: String?
    public let preferredProviderID: String?

    public init(
        sessionKey: String,
        turnCount: Int,
        lastActivityMs: Int64,
        thinkingLevel: String? = nil,
        displayName: String? = nil,
        preferredProviderID: String? = nil)
    {
        self.sessionKey = sessionKey
        self.turnCount = turnCount
        self.lastActivityMs = lastActivityMs
        self.thinkingLevel = thinkingLevel
        self.displayName = displayName
        self.preferredProviderID = preferredProviderID
    }
}

public actor GatewaySessionOperationQueue {
    private var running = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    public init() {}

    public func enqueue<T: Sendable>(
        _ operation: @escaping @Sendable () async throws -> T) async throws -> T
    {
        await self.acquireTurn()
        defer { self.releaseTurn() }
        return try await operation()
    }

    private func acquireTurn() async {
        guard self.running else {
            self.running = true
            return
        }
        await withCheckedContinuation { continuation in
            self.waiters.append(continuation)
        }
    }

    private func releaseTurn() {
        guard !self.waiters.isEmpty else {
            self.running = false
            return
        }
        let continuation = self.waiters.removeFirst()
        continuation.resume()
    }
}

public actor GatewaySessionStore {
    private struct SessionState: Sendable {
        var turnCount: Int
        var lastActivityMs: Int64
        var thinkingLevel: String?
        var displayName: String?
        var preferredProviderID: String?
        let queue: GatewaySessionOperationQueue
    }

    private var sessions: [String: SessionState] = [:]

    public init() {}

    public func queue(for sessionKey: String) -> GatewaySessionOperationQueue {
        let key = Self.normalizedSessionKey(sessionKey)
        if let existing = self.sessions[key] {
            return existing.queue
        }
        let queue = GatewaySessionOperationQueue()
        self.sessions[key] = SessionState(
            turnCount: 0,
            lastActivityMs: GatewayCore.currentTimestampMs(),
            thinkingLevel: nil,
            displayName: nil,
            preferredProviderID: nil,
            queue: queue)
        return queue
    }

    public func runQueued<T: Sendable>(
        sessionKey: String,
        operation: @escaping @Sendable () async throws -> T) async throws -> T
    {
        let queue = self.queue(for: sessionKey)
        return try await queue.enqueue(operation)
    }

    public func recordTurn(sessionKey: String, nowMs: Int64, thinkingLevel: String? = nil) {
        let key = Self.normalizedSessionKey(sessionKey)
        let normalizedThinkingLevel = Self.normalizedThinkingLevel(thinkingLevel)
        if let current = self.sessions[key] {
            self.sessions[key] = SessionState(
                turnCount: current.turnCount + 1,
                lastActivityMs: nowMs,
                thinkingLevel: normalizedThinkingLevel ?? current.thinkingLevel,
                displayName: current.displayName,
                preferredProviderID: current.preferredProviderID,
                queue: current.queue)
            return
        }

        self.sessions[key] = SessionState(
            turnCount: 1,
            lastActivityMs: nowMs,
            thinkingLevel: normalizedThinkingLevel,
            displayName: nil,
            preferredProviderID: nil,
            queue: GatewaySessionOperationQueue())
    }

    public func updateDisplayName(sessionKey: String, name: String?) {
        let key = Self.normalizedSessionKey(sessionKey)
        if let current = self.sessions[key] {
            self.sessions[key] = SessionState(
                turnCount: current.turnCount,
                lastActivityMs: current.lastActivityMs,
                thinkingLevel: current.thinkingLevel,
                displayName: name,
                preferredProviderID: current.preferredProviderID,
                queue: current.queue)
        } else {
            self.sessions[key] = SessionState(
                turnCount: 0,
                lastActivityMs: GatewayCore.currentTimestampMs(),
                thinkingLevel: nil,
                displayName: name,
                preferredProviderID: nil,
                queue: GatewaySessionOperationQueue())
        }
    }

    public func updatePreferredProvider(sessionKey: String, providerID: String?) {
        let key = Self.normalizedSessionKey(sessionKey)
        if let current = self.sessions[key] {
            self.sessions[key] = SessionState(
                turnCount: current.turnCount,
                lastActivityMs: current.lastActivityMs,
                thinkingLevel: current.thinkingLevel,
                displayName: current.displayName,
                preferredProviderID: providerID,
                queue: current.queue)
        } else {
            self.sessions[key] = SessionState(
                turnCount: 0,
                lastActivityMs: GatewayCore.currentTimestampMs(),
                thinkingLevel: nil,
                displayName: nil,
                preferredProviderID: providerID,
                queue: GatewaySessionOperationQueue())
        }
    }

    public func updateSessionSettings(
        sessionKey: String,
        preferredProviderID: String?,
        thinkingLevel: String?)
    {
        let key = Self.normalizedSessionKey(sessionKey)
        let normalizedThinkingLevel = Self.normalizedThinkingLevel(thinkingLevel)
        if let current = self.sessions[key] {
            self.sessions[key] = SessionState(
                turnCount: current.turnCount,
                lastActivityMs: current.lastActivityMs,
                thinkingLevel: normalizedThinkingLevel ?? current.thinkingLevel,
                displayName: current.displayName,
                preferredProviderID: preferredProviderID,
                queue: current.queue)
        } else {
            self.sessions[key] = SessionState(
                turnCount: 0,
                lastActivityMs: GatewayCore.currentTimestampMs(),
                thinkingLevel: normalizedThinkingLevel,
                displayName: nil,
                preferredProviderID: preferredProviderID,
                queue: GatewaySessionOperationQueue())
        }
    }

    public func removeSession(sessionKey: String) {
        let key = Self.normalizedSessionKey(sessionKey)
        self.sessions.removeValue(forKey: key)
    }

    public func sessionCount() -> Int {
        self.sessions.count
    }

    public func snapshot(sessionKey: String) -> GatewaySessionSnapshot {
        let key = Self.normalizedSessionKey(sessionKey)
        if let current = self.sessions[key] {
            return GatewaySessionSnapshot(
                sessionKey: key,
                turnCount: current.turnCount,
                lastActivityMs: current.lastActivityMs,
                thinkingLevel: current.thinkingLevel,
                displayName: current.displayName,
                preferredProviderID: current.preferredProviderID)
        }
        return GatewaySessionSnapshot(
            sessionKey: key,
            turnCount: 0,
            lastActivityMs: GatewayCore.currentTimestampMs(),
            thinkingLevel: nil)
    }

    public func snapshots() -> [GatewaySessionSnapshot] {
        self.sessions.keys.sorted().map { key in
            if let current = self.sessions[key] {
                return GatewaySessionSnapshot(
                    sessionKey: key,
                    turnCount: current.turnCount,
                    lastActivityMs: current.lastActivityMs,
                    thinkingLevel: current.thinkingLevel,
                    displayName: current.displayName,
                    preferredProviderID: current.preferredProviderID)
            }
            return GatewaySessionSnapshot(
                sessionKey: key,
                turnCount: 0,
                lastActivityMs: GatewayCore.currentTimestampMs(),
                thinkingLevel: nil)
        }
    }

    private static func normalizedSessionKey(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "main" : trimmed
    }

    private static func normalizedThinkingLevel(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let normalized = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalized.isEmpty else { return nil }
        return normalized
    }
}
