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
    var onDelete: ((SkillEntryViewModel) -> Void)?

    @State private var fileContent: String?
    @State private var credentialStatuses: [CredentialStatus] = []
    @State private var showingSetToken: CredentialStatus?
    @State private var newTokenValue: String = ""
    @State private var showCopied: Bool = false
    @State private var showDeleteConfirmation: Bool = false
    @State private var showDisableFirst: Bool = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(
                    alignment: .leading, spacing: 12)
                {
                    ForEach(self.credentialStatuses) { cred in
                        self.credentialRow(cred)
                    }
                    Text(self.displayContent)
                        .font(.system(
                            .body, design: .monospaced))
                        .frame(
                            maxWidth: .infinity,
                            alignment: .leading)
                }
                .padding()
            }
            .navigationTitle(self.entry.displayName)
            .toolbar {
                ToolbarItem(
                    placement: .topBarLeading)
                {
                    HStack(spacing: 12) {
                        Button {
                            UIPasteboard.general.string =
                                self.displayContent
                            self.showCopied = true
                            Task {
                                try? await Task.sleep(
                                    nanoseconds: 1_500_000_000)
                                self.showCopied = false
                            }
                        } label: {
                            Image(
                                systemName: self.showCopied
                                    ? "checkmark"
                                    : "doc.on.doc")
                        }
                        .accessibilityLabel("Copy skill")

                        if self.onDelete != nil {
                            Button(role: .destructive) {
                                if self.entry.enabled {
                                    self.showDisableFirst = true
                                } else {
                                    self.showDeleteConfirmation =
                                        true
                                }
                            } label: {
                                Image(systemName: "trash")
                                    .foregroundStyle(.red)
                            }
                            .accessibilityLabel(
                                "Delete skill")
                        }
                    }
                }
                ToolbarItem(
                    placement: .topBarTrailing)
                {
                    Button("Done") { self.onDismiss() }
                }
            }
            .sheet(item: self.$showingSetToken) { cred in
                self.setTokenSheet(cred)
            }
            .alert(
                "Delete Skill?",
                isPresented: self.$showDeleteConfirmation)
            {
                Button("Delete", role: .destructive) {
                    self.performDelete()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text(
                    "This will remove \"\(self.entry.displayName)\""
                        + " and any stored API keys.")
            }
            .alert(
                    "Skill is Enabled",
                    isPresented: self.$showDisableFirst)
            {
                Button("OK", role: .cancel) {}
                } message: {
                    Text(
                        "Disable this skill first before deleting.")
                }
        }
        .onAppear {
            self.loadFileContent()
            self.scanCredentials()
        }
    }

    private func performDelete() {
        // Remove stored credentials
        for cred in self.credentialStatuses {
            _ = KeychainStore.delete(
                service: "ai.openclaw.skill.\(cred.service)",
                account: "api_key")
        }
        // Delete the skill file from disk
        if !self.workspacePath.isEmpty {
            let fileURL = URL(
                fileURLWithPath: self.workspacePath,
                isDirectory: true)
                .appendingPathComponent(
                    self.entry.fileName,
                    isDirectory: false)
            try? FileManager.default.removeItem(at: fileURL)
        }
        self.onDelete?(self.entry)
        self.onDismiss()
    }

    // MARK: - Credential Row

    private func credentialRow(
        _ cred: CredentialStatus) -> some View
    {
        HStack(spacing: 8) {
            Image(
                systemName: cred.hasKey
                    ? "key.fill" : "key")
                .foregroundStyle(
                    cred.hasKey ? .green : .secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(
                    cred.hasKey
                        ? "API key configured"
                        : "No API key set")
                Text(cred.service)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if cred.hasKey {
                Button("Remove", role: .destructive) {
                    _ = KeychainStore.delete(
                        service: "ai.openclaw.skill.\(cred.service)",
                        account: "api_key")
                    self.updateStatus(
                        service: cred.service, hasKey: false)
                }
                .font(.footnote)
            } else {
                Button("Set Token") {
                    self.newTokenValue = ""
                    self.showingSetToken = cred
                }
                .font(.footnote)
            }
        }
        .padding(10)
        .background(.ultraThinMaterial)
        .clipShape(
            RoundedRectangle(cornerRadius: 8))
    }

    // MARK: - Set Token Sheet

    private func setTokenSheet(
        _ cred: CredentialStatus) -> some View
    {
        NavigationStack {
            Form {
                Section {
                    SecureField(
                        "API Key",
                        text: self.$newTokenValue)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } header: {
                    Text("Enter API key for \(cred.service)")
                } footer: {
                    Text("Stored securely in the device keychain.")
                }
                Section {
                    Button {
                        let trimmed = self.newTokenValue
                            .trimmingCharacters(
                                in: .whitespacesAndNewlines)
                        guard !trimmed.isEmpty else { return }
                        let saved = KeychainStore.saveString(
                            trimmed,
                            service: "ai.openclaw.skill.\(cred.service)",
                            account: "api_key")
                        if saved {
                            self.updateStatus(
                                service: cred.service,
                                hasKey: true)
                            self.showingSetToken = nil
                        }
                    } label: {
                        HStack {
                            Spacer()
                            Text("Save API Key")
                                .fontWeight(.semibold)
                            Spacer()
                        }
                    }
                    .disabled(
                        self.newTokenValue
                            .trimmingCharacters(
                                in: .whitespacesAndNewlines)
                            .isEmpty)
                }
            }
            .navigationTitle("API Key")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Cancel") {
                        self.showingSetToken = nil
                    }
                }
            }
        }
        .presentationDetents([.medium])
    }

    // MARK: - Helpers

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

    private func updateStatus(
        service: String, hasKey: Bool)
    {
        guard let idx = self.credentialStatuses.firstIndex(
            where: { $0.service == service })
        else { return }
        self.credentialStatuses[idx].hasKey = hasKey
    }

    // MARK: - Credential Scanning

    /// Scan the skill template content for credentials.get service names.
    private func scanCredentials() {
        // First try known mappings
        let known = Self.knownServiceNames(
            for: self.entry)
        if !known.isEmpty {
            self.credentialStatuses = known.map { service in
                let exists = KeychainStore.loadString(
                    service: "ai.openclaw.skill.\(service)",
                    account: "api_key") != nil
                return CredentialStatus(
                    service: service, hasKey: exists)
            }
            return
        }

        // Fall back to parsing the skill template for
        // credentials.get references
        let content = self.fileContent
            ?? TVOSBootstrapTemplateStore.template(
                for: self.entry.fileName)
            ?? ""
        let services = Self.parseCredentialServices(
            from: content)
        self.credentialStatuses = services.map { service in
            let exists = KeychainStore.loadString(
                service: "ai.openclaw.skill.\(service)",
                account: "api_key") != nil
            return CredentialStatus(
                service: service, hasKey: exists)
        }
    }

    /// Known skill → service name mappings.
    private static func knownServiceNames(
        for entry: SkillEntryViewModel) -> [String]
    {
        let id = entry.id.lowercased()
        switch id {
        case "notion": return ["notion"]
        case "trello": return ["trello.key", "trello.token"]
        case "x-twitter-api-search": return ["x"]
        case "github": return ["github"]
        default: return []
        }
    }

    /// Parse credentials.get({ "service": "..." }) from template text.
    private static func parseCredentialServices(
        from content: String) -> [String]
    {
        var services: [String] = []
        var seen = Set<String>()
        // Match: credentials.get({ "service": "xxx" })
        // Also match unquoted key: credentials.get({service: "xxx"})
        let pattern = #"credentials\.get\(\{[^}]*"?service"?\s*:\s*"([^"]+)""#
        guard let regex = try? NSRegularExpression(
            pattern: pattern)
        else { return [] }
        let range = NSRange(
            content.startIndex..., in: content)
        let matches = regex.matches(
            in: content, range: range)
        for match in matches {
            guard match.numberOfRanges > 1,
                  let serviceRange = Range(
                      match.range(at: 1), in: content)
            else { continue }
            let service = String(content[serviceRange])
            if !service.isEmpty, !seen.contains(service) {
                services.append(service)
                seen.insert(service)
            }
        }
        return services
    }
}

// MARK: - Credential Status Model

struct CredentialStatus: Identifiable, Equatable {
    let service: String
    var hasKey: Bool

    var id: String {
        self.service
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
