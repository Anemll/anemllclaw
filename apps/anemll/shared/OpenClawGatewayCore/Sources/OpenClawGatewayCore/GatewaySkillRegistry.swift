import Foundation

public struct GatewaySkillEntry: Sendable, Codable, Equatable {
    public let id: String
    public let fileName: String
    public var enabled: Bool
    public var description: String?

    public init(
        id: String,
        fileName: String,
        enabled: Bool = true,
        description: String? = nil)
    {
        self.id = id
        self.fileName = fileName
        self.enabled = enabled
        self.description = description
    }
}

public struct GatewaySkillRegistry: Sendable, Codable, Equatable {
    public var version: Int
    public var skills: [GatewaySkillEntry]

    public init(
        version: Int = 1,
        skills: [GatewaySkillEntry] = [])
    {
        self.version = version
        self.skills = skills
    }

    public var enabledFileNames: [String] {
        self.skills
            .filter(\.enabled)
            .map(\.fileName)
    }

    public mutating func setEnabled(
        _ skillID: String,
        enabled: Bool)
    {
        guard let idx = self.skills.firstIndex(
            where: { $0.id == skillID })
        else { return }
        self.skills[idx].enabled = enabled
    }

    public mutating func removeSkill(
        _ skillID: String)
    {
        self.skills.removeAll { $0.id == skillID }
    }

    // MARK: - Persistence

    public static func load(
        from workspaceRoot: URL) -> GatewaySkillRegistry?
    {
        let fileURL = workspaceRoot
            .appendingPathComponent("skills.json")
        guard let data = try? Data(
            contentsOf: fileURL)
        else { return nil }
        return try? JSONDecoder().decode(
            GatewaySkillRegistry.self,
            from: data)
    }

    public func save(
        to workspaceRoot: URL) throws
    {
        let fileURL = workspaceRoot
            .appendingPathComponent("skills.json")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [
            .prettyPrinted,
            .sortedKeys,
        ]
        let data = try encoder.encode(self)
        try data.write(to: fileURL, options: .atomic)
    }

    /// Filter a list of file names, removing any that
    /// are registered in this registry and disabled.
    public func filterFileNames(
        _ fileNames: [String]) -> [String]
    {
        let disabled = Set(
            self.skills
                .filter { !$0.enabled }
                .map(\.fileName))
        return fileNames.filter { !disabled.contains($0) }
    }
}
