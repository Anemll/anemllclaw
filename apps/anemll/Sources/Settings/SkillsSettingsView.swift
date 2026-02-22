import Foundation
import OpenClawGatewayCore
import os
import SwiftUI

struct SkillEntryViewModel: Identifiable, Equatable {
    let id: String
    let fileName: String
    let displayName: String
    let skillDescription: String?
    var enabled: Bool
}

// MARK: - Skill Info Sheet

struct SkillInfoSheet: View {
    let entry: SkillEntryViewModel
    let workspacePath: String
    let onDismiss: () -> Void

    @State private var fileContent: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                Text(self.displayContent)
                    .font(.system(.body, design: .monospaced))
                    .padding()
                    .frame(
                        maxWidth: .infinity,
                        alignment: .leading)
            }
            .navigationTitle(self.entry.displayName)
            .toolbar {
                ToolbarItem(
                    placement: .topBarTrailing)
                {
                    Button("Done") { self.onDismiss() }
                }
            }
        }
        .onAppear { self.loadFileContent() }
    }

    private var displayContent: String {
        if let content = self.fileContent,
           !content.isEmpty
        {
            return content
        }
        return self.entry.skillDescription
            ?? "No description available."
    }

    private func loadFileContent() {
        guard !self.workspacePath.isEmpty else { return }
        let fileURL = URL(
            fileURLWithPath: self.workspacePath,
            isDirectory: true)
            .appendingPathComponent(
                self.entry.fileName,
                isDirectory: false)
        if let data = try? Data(contentsOf: fileURL),
           let text = String(data: data, encoding: .utf8)
        {
            self.fileContent = text
        }
    }
}

// MARK: - Skills Settings

struct SkillsSettingsView: View {
    let localGatewayRuntime: TVOSLocalGatewayRuntime
    @Binding var selectedSkillInfo: SkillEntryViewModel?

    @State private var skillEntries: [SkillEntryViewModel] = []

    var body: some View {
        Group {
            if self.skillEntries.isEmpty {
                Text("No skills installed.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(self.skillEntries) { entry in
                    HStack {
                        Toggle(
                            entry.displayName,
                            isOn: self.skillBinding(for: entry))
                        Button {
                            self.selectedSkillInfo = entry
                        } label: {
                            Image(systemName: "info.circle")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            Text(
                "Skills inject context into the AI's"
                    + " system prompt. Disable unused"
                    + " skills to save context budget.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .onAppear { self.loadSkillEntries() }
    }

    // MARK: - Data Loading

    private static let log = Logger(
        subsystem: "ai.openclaw.ios",
        category: "SkillsSettings")

    private func loadSkillEntries() {
        let workspacePath = self.localGatewayRuntime
            .bootstrapWorkspacePath
        guard !workspacePath.isEmpty else {
            Self.log.warning(
                "skills: empty workspace path")
            return
        }
        let workspaceURL = URL(
            fileURLWithPath: workspacePath,
            isDirectory: true)
        var registry = GatewaySkillRegistry.load(
            from: workspaceURL)
            ?? GatewaySkillRegistry()
        Self.log.info(
            "skills: registry has \(registry.skills.count) entries, workspace=\(workspacePath)")

        // Discover skill files on disk that are not yet
        // in the registry (e.g. created by the LLM).
        let registeredFileNames = Set(
            registry.skills.map(\.fileName))
        let discovered = Self.discoverSkillFileNames(
            workspaceURL: workspaceURL)
        let discoveredList = discovered.joined(separator: ", ")
        Self.log.info(
            "skills: discovered \(discovered.count) files on disk: \(discoveredList)")
        var didAddNew = false
        for fileName in discovered
            where !registeredFileNames.contains(fileName)
        {
            let id = Self.skillID(from: fileName)
            registry.skills.append(
                GatewaySkillEntry(
                    id: id,
                    fileName: fileName,
                    enabled: true))
            Self.log.info(
                "skills: added new entry: \(fileName)")
            didAddNew = true
        }
        if didAddNew {
            try? registry.save(to: workspaceURL)
        }

        self.skillEntries = registry.skills.map { entry in
            SkillEntryViewModel(
                id: entry.id,
                fileName: entry.fileName,
                displayName: Self.skillDisplayName(
                    from: entry.fileName),
                skillDescription: entry.description,
                enabled: entry.enabled)
        }
        Self.log.info(
            "skills: showing \(self.skillEntries.count) entries in UI")
    }

    // MARK: - Skill Discovery

    /// Scan the workspace skills/ directory for .md files,
    /// returning relative paths like "skills/hn_search.md".
    private static func discoverSkillFileNames(
        workspaceURL: URL) -> [String]
    {
        let skillsRoot = workspaceURL
            .appendingPathComponent(
                "skills", isDirectory: true)
        let fm = FileManager.default
        guard fm.fileExists(atPath: skillsRoot.path)
        else {
            Self.log.warning(
                "skills: directory not found: \(skillsRoot.path)")
            return []
        }
        guard let enumerator = fm.enumerator(
            at: skillsRoot,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [
                .skipsHiddenFiles,
                .skipsPackageDescendants,
            ])
        else {
            Self.log.warning(
                "skills: enumerator failed for \(skillsRoot.path)")
            return []
        }

        // Use standardized paths to avoid /private
        // prefix mismatches on iOS.
        let rootPath: String
        let stdRoot = workspaceURL.standardizedFileURL.path
        if stdRoot.hasSuffix("/") {
            rootPath = stdRoot
        } else {
            rootPath = stdRoot + "/"
        }
        var results: [String] = []
        for case let fileURL as URL in enumerator {
            let values = try? fileURL.resourceValues(
                forKeys: [.isRegularFileKey])
            guard values?.isRegularFile == true else {
                continue
            }
            let name = fileURL.lastPathComponent.lowercased()
            guard name.hasSuffix(".md") else { continue }
            let full = fileURL.standardizedFileURL.path
            if full.hasPrefix(rootPath) {
                results.append(
                    String(full.dropFirst(rootPath.count)))
            }
        }
        results.sort()
        return results
    }

    private static func skillID(
        from fileName: String) -> String
    {
        fileName
            .replacingOccurrences(of: "skills/", with: "")
            .replacingOccurrences(of: "/SKILL.md", with: "")
            .replacingOccurrences(of: ".md", with: "")
    }

    private func skillBinding(
        for entry: SkillEntryViewModel) -> Binding<Bool>
    {
        Binding(
            get: {
                self.skillEntries.first {
                    $0.id == entry.id
                }?.enabled ?? entry.enabled
            },
            set: { newValue in
                guard let idx = self.skillEntries.firstIndex(
                    where: { $0.id == entry.id })
                else { return }
                self.skillEntries[idx].enabled = newValue
                self.persistSkillRegistry()
            })
    }

    private func persistSkillRegistry() {
        let workspacePath = self.localGatewayRuntime
            .bootstrapWorkspacePath
        guard !workspacePath.isEmpty else { return }
        let workspaceURL = URL(
            fileURLWithPath: workspacePath,
            isDirectory: true)
        var registry = GatewaySkillRegistry.load(
            from: workspaceURL)
            ?? GatewaySkillRegistry()
        for entry in self.skillEntries {
            registry.setEnabled(
                entry.id, enabled: entry.enabled)
        }
        try? registry.save(to: workspaceURL)
        Task {
            await self.localGatewayRuntime.reloadSkills()
        }
    }

    // MARK: - Display Name

    private static func skillDisplayName(
        from fileName: String) -> String
    {
        // "skills/weather/SKILL.md" → "Weather"
        // "skills/JS_NEWS.md" → "JS News"
        var name = fileName
            .replacingOccurrences(of: "skills/", with: "")
            .replacingOccurrences(of: "/SKILL.md", with: "")
            .replacingOccurrences(of: ".md", with: "")
        name = name
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
        return name.split(separator: " ")
            .map { word in
                let lower = word.lowercased()
                if lower == "js" || lower == "api" {
                    return word.uppercased()
                }
                return word.prefix(1).uppercased()
                    + word.dropFirst().lowercased()
            }
            .joined(separator: " ")
    }
}
