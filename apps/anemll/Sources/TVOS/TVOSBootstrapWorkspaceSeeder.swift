#if os(iOS) || os(tvOS)
import Foundation
import OpenClawGatewayCore

private struct TVOSWorkspaceOnboardingState: Codable, Sendable {
    var version: Int
    var bootstrapSeededAt: String?
    var onboardingCompletedAt: String?

    static let `default` = TVOSWorkspaceOnboardingState(
        version: TVOSBootstrapWorkspaceSeeder.workspaceStateVersion,
        bootstrapSeededAt: nil,
        onboardingCompletedAt: nil)
}

struct TVOSBootstrapWorkspaceStatus: Sendable {
    let workspacePath: String
    let statePath: String
    let bootstrapSeededAt: String?
    let onboardingCompletedAt: String?
    let bootstrapExists: Bool

    var bootstrapPending: Bool {
        self.onboardingCompletedAt == nil
    }
}

struct TVOSBootstrapSeedResult: Sendable {
    let workspacePath: String
    let createdFiles: [String]
    let existingFiles: [String]
    let missingTemplateFiles: [String]
    let failedFiles: [String: String]
    let status: TVOSBootstrapWorkspaceStatus?

    var createdCount: Int {
        self.createdFiles.count
    }

    var existingCount: Int {
        self.existingFiles.count
    }
}

enum TVOSBootstrapWorkspaceSeeder {
    static let workspaceStateVersion = 1
    private static let workspaceStateDirectoryName = ".openclaw"
    private static let workspaceStateFileName = "workspace-state.json"
    private static let bootstrapFileName = "BOOTSTRAP.md"
    private static let identityFileName = "IDENTITY.md"
    private static let userFileName = "USER.md"

    static func ensureSeeded(workspacePath: String) throws -> TVOSBootstrapSeedResult {
        let normalizedPath = workspacePath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedPath.isEmpty else {
            return TVOSBootstrapSeedResult(
                workspacePath: workspacePath,
                createdFiles: [],
                existingFiles: [],
                missingTemplateFiles: TVOSBootstrapTemplateStore.managedFileNames,
                failedFiles: [:],
                status: nil)
        }

        let workspaceURL = URL(fileURLWithPath: normalizedPath, isDirectory: true)
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: workspaceURL, withIntermediateDirectories: true)
        let statePath = self.workspaceStatePath(workspaceURL: workspaceURL)
        var state = self.readWorkspaceOnboardingState(statePath: statePath)
        var stateDirty = false

        var createdFiles: [String] = []
        var existingFiles: [String] = []
        var missingTemplateFiles: [String] = []
        var failedFiles: [String: String] = [:]

        for fileName in TVOSBootstrapTemplateStore.managedFileNames {
            if fileName == Self.bootstrapFileName {
                continue
            }
            guard let template = TVOSBootstrapTemplateStore.template(for: fileName) else {
                missingTemplateFiles.append(fileName)
                continue
            }

            let fileURL = workspaceURL.appendingPathComponent(fileName, isDirectory: false)
            if self.isRegularFile(fileURL) {
                existingFiles.append(fileName)
                continue
            }

            do {
                if try self.writeFileIfMissing(
                    self.normalizedTemplateContents(template),
                    to: fileURL)
                {
                    createdFiles.append(fileName)
                } else {
                    existingFiles.append(fileName)
                }
            } catch {
                failedFiles[fileName] = error.localizedDescription
            }
        }

        let bootstrapURL = workspaceURL.appendingPathComponent(Self.bootstrapFileName, isDirectory: false)
        var bootstrapExists = self.isRegularFile(bootstrapURL)
        if bootstrapExists {
            existingFiles.append(Self.bootstrapFileName)
        }

        func markState(_ mutation: (inout TVOSWorkspaceOnboardingState) -> Void) {
            mutation(&state)
            stateDirty = true
        }

        if state.bootstrapSeededAt == nil, bootstrapExists {
            markState { $0.bootstrapSeededAt = Self.nowISO8601() }
        }

        if state.onboardingCompletedAt == nil, state.bootstrapSeededAt != nil, !bootstrapExists {
            markState { $0.onboardingCompletedAt = Self.nowISO8601() }
        }

        if state.bootstrapSeededAt == nil, state.onboardingCompletedAt == nil, !bootstrapExists {
            let identityURL = workspaceURL.appendingPathComponent(Self.identityFileName, isDirectory: false)
            let userURL = workspaceURL.appendingPathComponent(Self.userFileName, isDirectory: false)
            let identityTemplate = TVOSBootstrapTemplateStore.template(for: Self.identityFileName)
                .map(self.normalizedTemplateContents)
            let userTemplate = TVOSBootstrapTemplateStore.template(for: Self.userFileName)
                .map(self.normalizedTemplateContents)
            let identityText = (try? String(contentsOf: identityURL, encoding: .utf8))
                .map { $0.replacingOccurrences(of: "\r\n", with: "\n") }
            let userText = (try? String(contentsOf: userURL, encoding: .utf8))
                .map { $0.replacingOccurrences(of: "\r\n", with: "\n") }

            let legacyOnboardingCompleted: Bool = {
                guard let identityTemplate, let userTemplate, let identityText, let userText else {
                    return false
                }
                return identityText != identityTemplate || userText != userTemplate
            }()

            if legacyOnboardingCompleted {
                markState { $0.onboardingCompletedAt = Self.nowISO8601() }
            } else if let bootstrapTemplate = TVOSBootstrapTemplateStore.template(for: Self.bootstrapFileName) {
                do {
                    if try self.writeFileIfMissing(
                        self.normalizedTemplateContents(bootstrapTemplate),
                        to: bootstrapURL)
                    {
                        createdFiles.append(Self.bootstrapFileName)
                        bootstrapExists = true
                    }
                } catch {
                    failedFiles[Self.bootstrapFileName] = error.localizedDescription
                }
                if bootstrapExists, state.bootstrapSeededAt == nil {
                    markState { $0.bootstrapSeededAt = Self.nowISO8601() }
                }
            } else {
                missingTemplateFiles.append(Self.bootstrapFileName)
            }
        }

        // Seed skills.json if it doesn't exist yet.
        let skillsJsonURL = workspaceURL.appendingPathComponent(
            "skills.json", isDirectory: false)
        if !self.isRegularFile(skillsJsonURL) {
            let defaultRegistry = GatewaySkillRegistry(
                version: 1,
                skills: Self.defaultSkillEntries())
            try? defaultRegistry.save(to: workspaceURL)
        }

        if stateDirty {
            try self.writeWorkspaceOnboardingState(state, statePath: statePath)
        }

        let status = TVOSBootstrapWorkspaceStatus(
            workspacePath: normalizedPath,
            statePath: statePath.path,
            bootstrapSeededAt: state.bootstrapSeededAt,
            onboardingCompletedAt: state.onboardingCompletedAt,
            bootstrapExists: bootstrapExists)

        return TVOSBootstrapSeedResult(
            workspacePath: normalizedPath,
            createdFiles: createdFiles,
            existingFiles: existingFiles,
            missingTemplateFiles: missingTemplateFiles,
            failedFiles: failedFiles,
            status: status)
    }

    static func loadStatus(workspacePath: String) -> TVOSBootstrapWorkspaceStatus? {
        let normalizedPath = workspacePath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedPath.isEmpty else {
            return nil
        }
        let workspaceURL = URL(fileURLWithPath: normalizedPath, isDirectory: true)
        let statePath = self.workspaceStatePath(workspaceURL: workspaceURL)
        let state = self.readWorkspaceOnboardingState(statePath: statePath)
        let bootstrapURL = workspaceURL.appendingPathComponent(Self.bootstrapFileName, isDirectory: false)
        return TVOSBootstrapWorkspaceStatus(
            workspacePath: normalizedPath,
            statePath: statePath.path,
            bootstrapSeededAt: state.bootstrapSeededAt,
            onboardingCompletedAt: state.onboardingCompletedAt,
            bootstrapExists: self.isRegularFile(bootstrapURL))
    }

    private static func workspaceStatePath(workspaceURL: URL) -> URL {
        workspaceURL
            .appendingPathComponent(self.workspaceStateDirectoryName, isDirectory: true)
            .appendingPathComponent(self.workspaceStateFileName, isDirectory: false)
    }

    private static func readWorkspaceOnboardingState(statePath: URL) -> TVOSWorkspaceOnboardingState {
        guard let data = try? Data(contentsOf: statePath) else {
            return .default
        }
        guard let decoded = try? JSONDecoder().decode(TVOSWorkspaceOnboardingState.self, from: data) else {
            return .default
        }
        return TVOSWorkspaceOnboardingState(
            version: Self.workspaceStateVersion,
            bootstrapSeededAt: decoded.bootstrapSeededAt,
            onboardingCompletedAt: decoded.onboardingCompletedAt)
    }

    private static func writeWorkspaceOnboardingState(
        _ state: TVOSWorkspaceOnboardingState,
        statePath: URL) throws
    {
        let fileManager = FileManager.default
        try fileManager.createDirectory(
            at: statePath.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        var normalized = state
        normalized.version = Self.workspaceStateVersion
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(normalized)
        let tempURL = statePath
            .deletingLastPathComponent()
            .appendingPathComponent(
                statePath.lastPathComponent + ".tmp-\(UUID().uuidString)",
                isDirectory: false)
        try data.write(to: tempURL, options: .atomic)
        do {
            if fileManager.fileExists(atPath: statePath.path) {
                try fileManager.removeItem(at: statePath)
            }
            try fileManager.moveItem(at: tempURL, to: statePath)
        } catch {
            try? fileManager.removeItem(at: tempURL)
            throw error
        }
    }

    private static func writeFileIfMissing(_ contents: String, to fileURL: URL) throws -> Bool {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = Data(contents.utf8)
        do {
            // `withoutOverwriting` cannot be combined with `atomic` on Apple platforms.
            // For bootstrap seeding we want "create-if-missing" behavior, so no atomic flag here.
            try data.write(to: fileURL, options: .withoutOverwriting)
            return true
        } catch {
            if (error as NSError).code == NSFileWriteFileExistsError {
                return false
            }
            throw error
        }
    }

    private static func isRegularFile(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), !isDirectory.boolValue {
            return true
        }
        return false
    }

    private static func normalizedTemplateContents(_ raw: String) -> String {
        let normalized = raw.replacingOccurrences(of: "\r\n", with: "\n")
        return normalized.hasSuffix("\n") ? normalized : normalized + "\n"
    }

    private static func nowISO8601() -> String {
        ISO8601DateFormatter().string(from: Date())
    }

    // MARK: - Default Skill Registry

    private static let skillDescriptions: [String: String] = [
        "JS_NEWS": "Fetch and parse JavaScript-rendered news sites using web.render",
        "weather": "Weather forecasts via wttr.in and Open-Meteo (no API key needed)",
        "summarize": "Summarize or extract text from URLs, articles, and web pages",
        "notion": "Create and manage Notion pages, databases, and blocks via API",
        "trello": "Manage Trello boards, lists, and cards via REST API",
        "x-twitter-api-search": "Search recent tweets and user profiles on X (Twitter) via API",
        "github": "Browse GitHub repos, issues, PRs, and notifications via API",
        "blogwatcher": "Monitor blogs and RSS/Atom feeds for updates",
    ]

    private static func defaultSkillEntries() -> [GatewaySkillEntry] {
        TVOSBootstrapTemplateStore.managedFileNames
            .filter { $0.hasPrefix("skills/") }
            .map { fileName in
                let id = fileName
                    .replacingOccurrences(of: "skills/", with: "")
                    .replacingOccurrences(of: "/SKILL.md", with: "")
                    .replacingOccurrences(of: ".md", with: "")
                return GatewaySkillEntry(
                    id: id,
                    fileName: fileName,
                    enabled: true,
                    description: self.skillDescriptions[id])
            }
    }
}
#endif
