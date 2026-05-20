import Observation
import SwiftUI

/// Lightweight provider option for the per-conversation model picker.
/// Populated by the host app from its own provider store.
public struct OpenClawProviderOption: Identifiable, Sendable {
    public let id: String
    public let displayName: String

    public init(id: String, displayName: String) {
        self.id = id
        self.displayName = displayName
    }
}

@MainActor
struct ChatSessionsSheet: View {
    @Bindable var viewModel: OpenClawChatViewModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openClawProviderOptions) private var providerOptions
    @State private var sessionToDelete: OpenClawChatSessionEntry?
    @State private var deleteError: String?
    @State private var sessionToRename: OpenClawChatSessionEntry?
    @State private var renameText: String = ""
    @State private var renameError: String?
    @State private var sessionToEdit: OpenClawChatSessionEntry?

    var body: some View {
        NavigationStack {
            self.sessionList
                .navigationTitle("Conversations")
                .toolbar { self.toolbarContent }
                .onAppear {
                    self.viewModel.refreshSessions(limit: 200)
                }
                .alert(
                    "Delete Conversation?",
                    isPresented: self.showDeleteConfirmation,
                    presenting: self.sessionToDelete)
                { session in
                    Button("Delete", role: .destructive) {
                        Task { await self.performDelete(key: session.key) }
                    }
                    Button("Cancel", role: .cancel) {}
                } message: { session in
                    Text("This will permanently delete \"\(session.displayName ?? session.key)\" and its transcript.")
                }
                .alert("Delete Failed", isPresented: self.showDeleteError) {
                        Button("OK", role: .cancel) {}
                    } message: {
                        Text(self.deleteError ?? "")
                    }
                    .alert(
                        "Rename Conversation",
                        isPresented: self.showRenameAlert)
                    {
                        TextField("Name", text: self.$renameText)
                        Button("Rename") {
                            let name = self.renameText
                            if let session = self.sessionToRename {
                                Task { await self.performRename(key: session.key, name: name) }
                            }
                        }
                        Button("Cancel", role: .cancel) {}
                    } message: {
                        Text("Enter a new name for this conversation.")
                    }
                    .alert("Rename Failed", isPresented: self.showRenameError) {
                            Button("OK", role: .cancel) {}
                        } message: {
                            Text(self.renameError ?? "")
                        }
                        .sheet(item: self.$sessionToEdit) { session in
                            SessionSettingsSheet(
                                viewModel: self.viewModel,
                                session: session,
                                providerOptions: self.providerOptions)
                        }
        }
    }

    private var showDeleteConfirmation: Binding<Bool> {
        Binding(
            get: { self.sessionToDelete != nil },
            set: { if !$0 { self.sessionToDelete = nil } })
    }

    private var showDeleteError: Binding<Bool> {
        Binding(
            get: { self.deleteError != nil },
            set: { if !$0 { self.deleteError = nil } })
    }

    private var showRenameAlert: Binding<Bool> {
        Binding(
            get: { self.sessionToRename != nil },
            set: { if !$0 { self.sessionToRename = nil } })
    }

    private var showRenameError: Binding<Bool> {
        Binding(
            get: { self.renameError != nil },
            set: { if !$0 { self.renameError = nil } })
    }

    private var sessionList: some View {
        List {
            ForEach(self.viewModel.sessions) { session in
                self.sessionRow(session)
            }
        }
    }

    private func sessionRow(_ session: OpenClawChatSessionEntry) -> some View {
        let hasCustomSettings = self.hasCustomSettings(session)
        return Button {
            self.viewModel.switchSession(to: session.key)
            self.dismiss()
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(session.displayName ?? session.key)
                            .font(.body)
                            .lineLimit(1)
                        if hasCustomSettings {
                            Image(systemName: "gearshape.fill")
                                .font(.caption2)
                                .foregroundStyle(.green)
                        }
                    }
                    HStack(spacing: 6) {
                        if let updatedAt = session.updatedAt, updatedAt > 0 {
                            Text(Date(timeIntervalSince1970: updatedAt / 1000).formatted(
                                date: .abbreviated,
                                time: .shortened))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        if let summary = self.sessionSettingsSummary(session) {
                            Text(summary)
                                .font(.caption)
                                .foregroundStyle(.green)
                        }
                    }
                }
                Spacer()
                if session.key == self.viewModel.sessionKey {
                    Image(systemName: "checkmark")
                        .foregroundStyle(Color.accentColor)
                        .font(.caption)
                }
            }
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            if self.canDelete(session) {
                Button(role: .destructive) {
                    self.sessionToDelete = session
                } label: {
                    Label("Delete", systemImage: "trash")
                }
            }
            Button {
                self.sessionToEdit = session
            } label: {
                Label("Settings", systemImage: "gearshape")
            }
            .tint(.gray)
            Button {
                self.renameText = session.displayName ?? session.key
                self.sessionToRename = session
            } label: {
                Label("Rename", systemImage: "pencil")
            }
            .tint(.blue)
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        #if os(macOS)
        ToolbarItem(placement: .automatic) {
            Button {
                self.viewModel.refreshSessions(limit: 200)
            } label: {
                Image(systemName: "arrow.clockwise")
            }
        }
        ToolbarItem(placement: .primaryAction) {
            Button {
                self.dismiss()
            } label: {
                Image(systemName: "xmark")
            }
        }
        #else
        ToolbarItem(placement: .topBarLeading) {
            Button {
                self.viewModel.refreshSessions(limit: 200)
            } label: {
                Image(systemName: "arrow.clockwise")
            }
        }
        ToolbarItem(placement: .topBarTrailing) {
            Button {
                self.dismiss()
            } label: {
                Image(systemName: "xmark")
            }
        }
        #endif
    }

    private func canDelete(_ session: OpenClawChatSessionEntry) -> Bool {
        session.key != "main" && session.key != "global"
    }

    private func hasCustomSettings(_ session: OpenClawChatSessionEntry) -> Bool {
        session.preferredProviderID != nil || self.hasCustomThinkingLevel(session)
    }

    private func hasCustomThinkingLevel(_ session: OpenClawChatSessionEntry) -> Bool {
        guard let level = session.thinkingLevel else { return false }
        return level != "low"
    }

    private func sessionSettingsSummary(_ session: OpenClawChatSessionEntry) -> String? {
        var parts: [String] = []
        if let providerID = session.preferredProviderID,
           let option = self.providerOptions.first(where: { $0.id == providerID })
        {
            parts.append(option.displayName)
        }
        if self.hasCustomThinkingLevel(session), let level = session.thinkingLevel {
            parts.append("R:\(level)")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private func performDelete(key: String) async {
        do {
            try await self.viewModel.deleteSession(key: key)
        } catch {
            self.deleteError = error.localizedDescription
        }
    }

    private func performRename(key: String, name: String) async {
        do {
            try await self.viewModel.renameSession(key: key, displayName: name)
        } catch {
            self.renameError = error.localizedDescription
        }
    }
}

// MARK: - Per-Conversation Settings Sheet

@MainActor
private struct SessionSettingsSheet: View {
    @Environment(\.dismiss) private var dismiss
    let viewModel: OpenClawChatViewModel
    let session: OpenClawChatSessionEntry
    let providerOptions: [OpenClawProviderOption]

    @State private var selectedProviderID: String = ""
    @State private var selectedThinkingLevel: String = "low"
    @State private var saveError: String?

    private static let autoProviderID = "__auto__"

    var body: some View {
        NavigationStack {
            Form {
                Section("Model") {
                    Picker("Provider", selection: self.$selectedProviderID) {
                        Text("Auto").tag(Self.autoProviderID)
                        ForEach(self.providerOptions) { option in
                            Text(option.displayName).tag(option.id)
                        }
                    }
                }
                Section("Reasoning Level") {
                    Picker("Level", selection: self.$selectedThinkingLevel) {
                        Text("Off").tag("off")
                        Text("Low").tag("low")
                        Text("Medium").tag("medium")
                        Text("High").tag("high")
                        Text("Extra High").tag("xhigh")
                    }
                }
            }
            .navigationTitle(self.session.displayName ?? self.session.key)
            #if !os(macOS)
                .navigationBarTitleDisplayMode(.inline)
            #endif
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Save") {
                            Task { await self.save() }
                        }
                    }
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") {
                            self.dismiss()
                        }
                    }
                }
                .alert("Save Failed", isPresented: self.showSaveError) {
                    Button("OK", role: .cancel) {}
                } message: {
                    Text(self.saveError ?? "")
                }
                .onAppear {
                    let bound = self.session.preferredProviderID
                    if let bound, self.providerOptions.contains(where: { $0.id == bound }) {
                        self.selectedProviderID = bound
                    } else {
                        // Provider was deleted or never present in this host — fall back to Auto.
                        self.selectedProviderID = Self.autoProviderID
                    }
                    self.selectedThinkingLevel = self.session.thinkingLevel ?? "low"
                }
        }
        #if !os(macOS)
        .presentationDetents([.medium])
        #endif
    }

    private var showSaveError: Binding<Bool> {
        Binding(
            get: { self.saveError != nil },
            set: { if !$0 { self.saveError = nil } })
    }

    private func save() async {
        let providerID = self.selectedProviderID == Self.autoProviderID ? nil : self.selectedProviderID
        do {
            try await self.viewModel.updateSessionSettings(
                key: self.session.key,
                preferredProviderID: providerID,
                thinkingLevel: self.selectedThinkingLevel)
            self.dismiss()
        } catch {
            self.saveError = error.localizedDescription
        }
    }
}
