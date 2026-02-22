import OpenClawGatewayCore
import SwiftUI

struct ToolEntryViewModel: Identifiable, Equatable {
    let id: String
    let displayName: String
    let description: String
    let category: String
    var enabled: Bool
}

// MARK: - Tool Info Sheet

struct ToolInfoSheet: View {
    let entry: ToolEntryViewModel
    let onDismiss: () -> Void

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(
                    alignment: .leading, spacing: 12)
                {
                    HStack(spacing: 8) {
                        Text(self.entry.category)
                            .font(.caption)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(.ultraThinMaterial)
                            .clipShape(Capsule())
                        Spacer()
                    }
                    Text(self.entry.description)
                        .frame(
                            maxWidth: .infinity,
                            alignment: .leading)
                }
                .padding()
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
    }
}

// MARK: - Tools Settings

struct ToolsSettingsView: View {
    let localGatewayRuntime: TVOSLocalGatewayRuntime
    @Binding var selectedToolInfo: ToolEntryViewModel?

    @State private var toolEntries: [ToolEntryViewModel] = []

    var body: some View {
        Group {
            if self.toolEntries.isEmpty {
                Text("No tools available.")
                    .foregroundStyle(.secondary)
            } else {
                self.toolRows(
                    excluding: "Device")
                Text(
                    "Disable tools the AI doesn't need"
                        + " to reduce noise and improve"
                        + " response quality.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                Divider()
                    .padding(.vertical, 4)
                Text("Device (requires permissions)")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(
                        maxWidth: .infinity,
                        alignment: .leading)
                self.toolRows(
                    category: "Device")
                Text(
                    "These tools access iOS features"
                        + " that require permission prompts."
                        + " Disabled by default.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .onAppear { self.loadToolEntries() }
    }

    @ViewBuilder
    private func toolRows(
        category: String? = nil,
        excluding: String? = nil) -> some View
    {
        let filtered = self.toolEntries.filter { entry in
            if let cat = category {
                return entry.category == cat
            }
            if let excl = excluding {
                return entry.category != excl
            }
            return true
        }
        ForEach(filtered) { entry in
            HStack {
                Toggle(
                    entry.displayName,
                    isOn: self.toolBinding(
                        for: entry))
                Button {
                    self.selectedToolInfo = entry
                } label: {
                    Image(
                        systemName: "info.circle")
                        .foregroundStyle(
                            .secondary)
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: - Data

    private static let disabledToolNamesKey =
        "gateway.tvos.disabledToolNames"

    private func loadToolEntries() {
        var disabled = self.localGatewayRuntime
            .controlPlaneSettings.disabledToolNames

        // On first launch the key is absent — seed with
        // permission-requiring tools disabled by default.
        if UserDefaults.standard.stringArray(
            forKey: Self.disabledToolNamesKey) == nil
        {
            disabled = Self.defaultDisabledToolIDs
            self.applyDefaultDisabledTools(disabled)
        }

        self.toolEntries = Self.orderedTools.map { tool in
            var entry = tool
            entry.enabled = !disabled.contains(tool.id)
            return entry
        }
    }

    /// Persist the initial disabled set so the runtime picks
    /// it up immediately and future loads are consistent.
    private func applyDefaultDisabledTools(
        _ disabled: Set<String>)
    {
        var settings = self.localGatewayRuntime
            .controlPlaneSettings
        settings.disabledToolNames = disabled
        Task {
            await self.localGatewayRuntime
                .applyControlPlaneSettings(settings)
        }
    }

    private func toolBinding(
        for entry: ToolEntryViewModel) -> Binding<Bool>
    {
        Binding(
            get: {
                self.toolEntries.first {
                    $0.id == entry.id
                }?.enabled ?? true
            },
            set: { newValue in
                guard let idx = self.toolEntries
                    .firstIndex(
                        where: { $0.id == entry.id })
                else { return }
                self.toolEntries[idx].enabled = newValue
                self.persistToolSettings()
            })
    }

    private func persistToolSettings() {
        let disabled = Set(
            self.toolEntries
                .filter { !$0.enabled }
                .map(\.id))
        var settings = self.localGatewayRuntime
            .controlPlaneSettings
        settings.disabledToolNames = disabled
        Task {
            await self.localGatewayRuntime
                .applyControlPlaneSettings(settings)
        }
    }

    // MARK: - Tool Catalog

    private static let allTools: [ToolEntryViewModel] = [
        // Safe tools
        ToolEntryViewModel(
            id: "time.now",
            displayName: "Current Time",
            description: "Returns the current date, time, timezone, and Unix timestamp for this device.",
            category: "Safe",
            enabled: true),
        ToolEntryViewModel(
            id: "device.info",
            displayName: "Device Info",
            description: "Returns device metadata: model, OS version, screen size, battery level, and storage.",
            category: "Safe",
            enabled: true),
        ToolEntryViewModel(
            id: "network.fetch",
            displayName: "Network Fetch",
            description: "Performs HTTP GET requests to APIs and plain-text endpoints. Used by skills that need web APIs (weather, Notion, Trello). Supports custom headers for authentication.",
            category: "Safe",
            enabled: true),
        ToolEntryViewModel(
            id: "web.fetch",
            displayName: "Web Fetch",
            description: "Fetches plain web page content (HTML). Does not execute JavaScript — use Web Render for JS-heavy pages.",
            category: "Safe",
            enabled: true),
        ToolEntryViewModel(
            id: "web.render",
            displayName: "Web Render",
            description: "Renders JavaScript-heavy web pages and returns the fully-rendered content. Essential for modern news sites and SPAs.",
            category: "Safe",
            enabled: true),
        ToolEntryViewModel(
            id: "web.extract",
            displayName: "Web Extract",
            description: "Extracts structured data from web pages: title, main text, links, and metadata. Good for summarizing articles.",
            category: "Safe",
            enabled: true),
        ToolEntryViewModel(
            id: "telegram.send",
            displayName: "Telegram Send",
            description: "Sends a message to a Telegram chat. Requires Telegram bot token and chat ID to be configured.",
            category: "Safe",
            enabled: true),
        // File tools
        ToolEntryViewModel(
            id: "read",
            displayName: "Read File",
            description: "Reads a UTF-8 text file from the workspace. The AI uses this to read skill files, memory, and configuration.",
            category: "File",
            enabled: true),
        ToolEntryViewModel(
            id: "write",
            displayName: "Write File",
            description: "Writes or creates a UTF-8 text file in the workspace. Used for saving notes, memory, and configuration changes.",
            category: "File",
            enabled: true),
        ToolEntryViewModel(
            id: "edit",
            displayName: "Edit File",
            description: "Replaces specific text in a workspace file. Safer than full write — only changes the targeted section.",
            category: "File",
            enabled: true),
        ToolEntryViewModel(
            id: "apply_patch",
            displayName: "Apply Patch",
            description: "Applies a unified diff patch to workspace files. Used for multi-file changes in a single operation.",
            category: "File",
            enabled: true),
        ToolEntryViewModel(
            id: "ls",
            displayName: "List Files",
            description: "Lists files and directories in the workspace. Supports recursive listing.",
            category: "File",
            enabled: true),
        // Device tools
        ToolEntryViewModel(
            id: "reminders.list",
            displayName: "List Reminders",
            description: "Lists iOS reminders with title, due date, and completion status. Can filter by status (incomplete, completed, all).",
            category: "Device",
            enabled: true),
        ToolEntryViewModel(
            id: "reminders.add",
            displayName: "Add Reminder",
            description: "Creates a new iOS reminder with title, optional due date, notes, and list name.",
            category: "Device",
            enabled: true),
        ToolEntryViewModel(
            id: "calendar.events",
            displayName: "Calendar Events",
            description: "Queries iOS calendar events in a date range. Defaults to the next 7 days if no range specified.",
            category: "Device",
            enabled: true),
        ToolEntryViewModel(
            id: "calendar.add",
            displayName: "Add Calendar Event",
            description: "Creates a new iOS calendar event with title, start/end time, location, and notes.",
            category: "Device",
            enabled: true),
        ToolEntryViewModel(
            id: "contacts.search",
            displayName: "Search Contacts",
            description: "Searches iOS contacts by name. Returns matching names, phone numbers, and email addresses.",
            category: "Device",
            enabled: true),
        ToolEntryViewModel(
            id: "contacts.add",
            displayName: "Add Contact",
            description: "Adds a new contact to the iOS address book with name, phone, email, and other fields.",
            category: "Device",
            enabled: true),
        ToolEntryViewModel(
            id: "location.get",
            displayName: "Get Location",
            description: "Gets the current GPS coordinates, altitude, speed, and heading of this device. Requires location permission.",
            category: "Device",
            enabled: true),
        ToolEntryViewModel(
            id: "photos.latest",
            displayName: "Latest Photos",
            description: "Retrieves recent photos from the device photo library as base64-encoded JPEG images.",
            category: "Device",
            enabled: true),
        ToolEntryViewModel(
            id: "camera.snap",
            displayName: "Camera Snap",
            description: "Takes a photo with the device camera and returns it as a base64-encoded image. Requires the app to be in the foreground.",
            category: "Device",
            enabled: true),
        ToolEntryViewModel(
            id: "motion.activity",
            displayName: "Motion Activity",
            description: "Queries device motion activity history — walking, running, driving, cycling, and stationary states.",
            category: "Device",
            enabled: true),
        ToolEntryViewModel(
            id: "motion.pedometer",
            displayName: "Pedometer",
            description: "Queries step count, distance walked, and floors climbed from the device pedometer.",
            category: "Device",
            enabled: true),
        // Credential tools
        ToolEntryViewModel(
            id: "credentials.get",
            displayName: "Get Credential",
            description: "Retrieves a stored API key from the device keychain. Used by skills like Notion and Trello to securely access stored keys.",
            category: "Credentials",
            enabled: true),
        ToolEntryViewModel(
            id: "credentials.set",
            displayName: "Store Credential",
            description: "Stores an API key securely in the device keychain. Keys persist across sessions and are never exposed in chat logs.",
            category: "Credentials",
            enabled: true),
        ToolEntryViewModel(
            id: "credentials.delete",
            displayName: "Delete Credential",
            description: "Removes a stored API key from the device keychain.",
            category: "Credentials",
            enabled: true),
    ]

    /// Ordered tool catalog for display: Safe, File, Credentials,
    /// then Device (permission-required, disabled by default).
    static var orderedTools: [ToolEntryViewModel] {
        let order: [String] = [
            "Safe", "File", "Credentials", "Device",
        ]
        return self.allTools.sorted { a, b in
            let ai = order.firstIndex(of: a.category) ?? 99
            let bi = order.firstIndex(of: b.category) ?? 99
            return ai < bi
        }
    }

    /// Tool IDs that require iOS permissions and should be
    /// disabled by default until the user opts in.
    static let defaultDisabledToolIDs: Set<String> = [
        "reminders.list",
        "reminders.add",
        "calendar.events",
        "calendar.add",
        "contacts.search",
        "contacts.add",
        "location.get",
        "photos.latest",
        "camera.snap",
        "motion.activity",
        "motion.pedometer",
    ]
}
