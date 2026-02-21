import Observation
import SwiftUI

@MainActor
struct ChatSessionsSheet: View {
    @Bindable var viewModel: OpenClawChatViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var sessionToDelete: OpenClawChatSessionEntry?
    @State private var deleteError: String?

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

    private var sessionList: some View {
        List {
            ForEach(self.viewModel.sessions) { session in
                self.sessionRow(session)
            }
        }
    }

    private func sessionRow(_ session: OpenClawChatSessionEntry) -> some View {
        Button {
            self.viewModel.switchSession(to: session.key)
            self.dismiss()
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(session.displayName ?? session.key)
                        .font(.body)
                        .lineLimit(1)
                    if let updatedAt = session.updatedAt, updatedAt > 0 {
                        Text(Date(timeIntervalSince1970: updatedAt / 1000).formatted(
                            date: .abbreviated,
                            time: .shortened))
                            .font(.caption)
                            .foregroundStyle(.secondary)
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

    private func performDelete(key: String) async {
        do {
            try await self.viewModel.deleteSession(key: key)
        } catch {
            self.deleteError = error.localizedDescription
        }
    }
}
