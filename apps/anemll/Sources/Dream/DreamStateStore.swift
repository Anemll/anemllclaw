import Foundation

// MARK: - Dream Run State

struct DreamRunState: Codable, Sendable {
    /// Epoch-seconds key of `lastInteractionAt` when dream was last triggered.
    var lastDreamForInteraction: String?

    /// Relative path to pending digest (e.g. "dream/digest.md"), or nil.
    var pendingDigestPath: String?

    /// Epoch-seconds key when digest was last delivered to user.
    var deliveredForInteraction: String?

    /// UUID of the most recent dream run.
    var lastRunId: String?

    /// ISO 8601 timestamp of the most recent dream run start.
    var lastRunAt: String?

    /// Deprecated — cooldown removed. Kept for JSON backwards compatibility.
    var cooldownUntil: String?
}

// MARK: - Dream State Store

/// Reads and writes `dream/state.json` atomically under the workspace root.
///
/// Accessed from both `@MainActor` (DreamModeManager) and non-isolated
/// contexts (DeviceToolBridgeImpl), so it uses `NSLock` internally.
final class DreamStateStore: @unchecked Sendable {
    private let fileURL: URL
    private let lock = NSLock()

    init(workspaceRoot: URL) {
        self.fileURL = workspaceRoot
            .appendingPathComponent("dream", isDirectory: true)
            .appendingPathComponent("state.json", isDirectory: false)
    }

    func load() -> DreamRunState {
        self.lock.lock()
        defer { self.lock.unlock() }
        guard let data = try? Data(contentsOf: self.fileURL),
              let decoded = try? JSONDecoder().decode(
                  DreamRunState.self, from: data)
        else {
            return DreamRunState()
        }
        return decoded
    }

    func save(_ state: DreamRunState) {
        self.lock.lock()
        defer { self.lock.unlock() }
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(state)
            let parent = self.fileURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(
                at: parent,
                withIntermediateDirectories: true)
            try data.write(to: self.fileURL, options: .atomic)
        } catch {
            // Best-effort persistence; file I/O errors are non-fatal.
        }
    }

    /// Atomically read-modify-write the state.
    func update(_ mutation: (inout DreamRunState) -> Void) {
        var state = self.load()
        mutation(&state)
        self.save(state)
    }
}

// MARK: - Dream Retention Cleaner

/// Age-based cleanup of dream artifacts.
enum DreamRetentionCleaner {
    /// Delete journal entries older than `retainDays` days.
    static func cleanJournals(
        workspaceRoot: URL,
        retainDays: Int)
    {
        let dir = workspaceRoot
            .appendingPathComponent(
                "dream/journal", isDirectory: true)
        self.cleanOldFiles(
            in: dir, olderThanDays: retainDays, ext: "md")
    }

    /// Delete patches older than `retainDays` days.
    static func cleanPatches(
        workspaceRoot: URL,
        retainDays: Int)
    {
        let dir = workspaceRoot
            .appendingPathComponent(
                "dream/patches", isDirectory: true)
        self.cleanOldFiles(
            in: dir, olderThanDays: retainDays, ext: "patch")
    }

    private static func cleanOldFiles(
        in directory: URL,
        olderThanDays: Int,
        ext: String)
    {
        let fm = FileManager.default
        guard let contents = try? fm.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [
                .contentModificationDateKey,
            ],
            options: .skipsHiddenFiles)
        else { return }

        let cutoff = Date().addingTimeInterval(
            -Double(olderThanDays) * 86400)

        for fileURL in contents {
            guard fileURL.pathExtension == ext else { continue }
            guard
                let values = try? fileURL.resourceValues(
                    forKeys: [.contentModificationDateKey]),
                let modDate = values.contentModificationDate,
                modDate < cutoff
            else { continue }
            try? fm.removeItem(at: fileURL)
        }
    }
}
