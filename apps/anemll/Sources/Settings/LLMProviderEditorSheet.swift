#if os(iOS) || os(tvOS)
import OpenClawGatewayCore
import SwiftUI

struct LLMProviderEditorSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(TVOSLocalGatewayRuntime.self) private var localGatewayRuntime: TVOSLocalGatewayRuntime
    @State private var name: String
    @State private var provider: GatewayLocalLLMProviderKind
    @State private var baseURL: String
    @State private var apiKey: String
    @State private var model: String
    @State private var toolCallingMode: GatewayLocalLLMToolCallingMode
    @State private var isApplyingChanges = false
    @State private var statusText: String?
    @State private var statusIsError = false
    @State private var statusResponsePreview: String?
    @State private var operationStartedAt: Date?
    @State private var operationElapsedSeconds = 0
    @State private var operationIsTest = false
    @State private var progressTickerTask: Task<Void, Never>?
    @State private var saveOperationTask: Task<Void, Never>?
    @State private var operationToken = UUID()
    @State private var statusScrollTrigger = UUID()
    private let providerID: String
    private let isNew: Bool
    private let onSave: @MainActor (SavedLLMProvider, Bool) async -> Void
    private static let statusSectionID = "llm-provider-editor-status"
    private static let statusCancelButtonID = "llm-provider-editor-status-cancel"

    init(
        provider: SavedLLMProvider,
        isNew: Bool,
        onSave: @escaping @MainActor (SavedLLMProvider, Bool) async -> Void)
    {
        self.providerID = provider.id
        self.isNew = isNew
        self._name = State(initialValue: provider.name)
        self._provider = State(initialValue: isNew ? .disabled : provider.provider)
        self._baseURL = State(initialValue: provider.baseURL)
        self._apiKey = State(initialValue: provider.apiKey)
        self._model = State(initialValue: provider.model)
        self._toolCallingMode = State(initialValue: provider.toolCallingMode)
        self.onSave = onSave
    }

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                Form {
                    Section("Provider") {
                        TextField("Name (optional)", text: self.$name)
                            .textInputAutocapitalization(.words)

                        Picker("Type", selection: self.$provider) {
                            Text("None").tag(GatewayLocalLLMProviderKind.disabled)
                            Text("Grok-compatible").tag(GatewayLocalLLMProviderKind.grokCompatible)
                            Text("OpenAI-compatible").tag(GatewayLocalLLMProviderKind.openAICompatible)
                            Text("Anthropic-compatible").tag(GatewayLocalLLMProviderKind.anthropicCompatible)
                            Text("MiniMax-compatible").tag(GatewayLocalLLMProviderKind.minimaxCompatible)
                        }
                    }

                    Section("Connection") {
                        TextField("Base URL", text: self.$baseURL)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .keyboardType(.URL)

                        SecureField("API Key", text: self.$apiKey)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()

                        TextField("Model", text: self.$model)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()

                        Picker("Tool Calling", selection: self.$toolCallingMode) {
                            Text("Auto").tag(GatewayLocalLLMToolCallingMode.auto)
                            Text("On").tag(GatewayLocalLLMToolCallingMode.on)
                            Text("Off").tag(GatewayLocalLLMToolCallingMode.off)
                        }
                        Text(self.toolCallingMode.helpText)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }

                    if !self.canSave {
                        Section {
                            Text("Model is required.")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }

                    if self.canSave {
                        Section {
                            Button {
                                self.applyAndOptionallyDismiss(test: false, dismissAfterSave: false)
                            } label: {
                                Label(
                                    "Save & Restart",
                                    systemImage: "arrow.clockwise")
                            }
                            .disabled(self.isApplyingChanges)

                            Button {
                                self.applyAndOptionallyDismiss(test: true, dismissAfterSave: false)
                            } label: {
                                Label(
                                    "Save, Restart & Test",
                                    systemImage: "arrow.clockwise.circle")
                            }
                            .disabled(self.isApplyingChanges)
                        }
                    }

                    if self.isApplyingChanges || self.statusText != nil {
                        Section("Status") {
                            if self.isApplyingChanges {
                                HStack(spacing: 8) {
                                    ProgressView()
                                        .progressViewStyle(.circular)
                                    Text(self.inFlightStatusText)
                                }
                                Button("Cancel", role: .destructive) {
                                    self.cancelCurrentOperation()
                                }
                                .id(Self.statusCancelButtonID)
                            }
                            if let statusText = self.statusText {
                                HStack(spacing: 8) {
                                    Image(systemName: self
                                        .statusIsError ? "xmark.circle.fill" : "checkmark.circle.fill")
                                        .foregroundStyle(self.statusIsError ? .red : .green)
                                    Text(statusText)
                                        .foregroundStyle(self.statusIsError ? .red : .primary)
                                }
                            }
                            if let preview = self.statusResponsePreview,
                               !preview.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            {
                                Text(preview)
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(3)
                            }
                        }
                        .id(Self.statusSectionID)
                    }
                }
                .navigationTitle(self.isNew ? "Add Provider" : "Edit Provider")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") {
                            self.dismiss()
                        }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Save & Exit") {
                            self.applyAndOptionallyDismiss(test: false, dismissAfterSave: true)
                        }
                        .disabled(!self.canSave || self.isApplyingChanges)
                    }
                }
                .onChange(of: self.provider) { _, newValue in
                    self.applyDefaults(for: newValue)
                }
                .onChange(of: self.statusScrollTrigger) { _, _ in
                    withAnimation(.easeInOut(duration: 0.2)) {
                        let targetID = self.isApplyingChanges
                            ? Self.statusCancelButtonID
                            : Self.statusSectionID
                        proxy.scrollTo(targetID, anchor: .center)
                    }
                }
                .onDisappear {
                    self.saveOperationTask?.cancel()
                    self.saveOperationTask = nil
                    self.stopProgressTicker()
                }
            }
        }
    }

    private var canSave: Bool {
        !self.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var inFlightStatusText: String {
        let suffix = " \(self.operationElapsedSeconds)s"
        if self.operationIsTest {
            return "Running test…\(suffix)"
        }
        return "Applying changes…\(suffix)"
    }

    private func applyDefaults(for kind: GatewayLocalLLMProviderKind) {
        if self.baseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           let url = TVOSLocalGatewayRuntime.defaultLocalLLMBaseURL(for: kind)
        {
            self.baseURL = url
        }
        if self.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           let m = TVOSLocalGatewayRuntime.defaultLocalLLMModel(for: kind)
        {
            self.model = m
        }
    }

    private func applyAndOptionallyDismiss(test: Bool, dismissAfterSave: Bool) {
        guard !self.isApplyingChanges else { return }
        guard self.canSave else { return }
        let token = UUID()
        self.operationToken = token
        self.isApplyingChanges = true
        self.statusText = nil
        self.statusIsError = false
        self.statusResponsePreview = nil
        self.startProgressTicker(isTest: test)
        self.statusScrollTrigger = UUID()
        let saved = SavedLLMProvider(
            id: self.providerID,
            name: self.name.trimmingCharacters(in: .whitespacesAndNewlines),
            provider: self.provider,
            baseURL: self.baseURL.trimmingCharacters(in: .whitespacesAndNewlines),
            apiKey: self.apiKey.trimmingCharacters(in: .whitespacesAndNewlines),
            model: self.model.trimmingCharacters(in: .whitespacesAndNewlines),
            toolCallingMode: self.toolCallingMode)
        let task = Task { @MainActor in
            defer {
                if self.operationToken == token {
                    self.saveOperationTask = nil
                    self.isApplyingChanges = false
                    self.stopProgressTicker()
                    if dismissAfterSave, !Task.isCancelled {
                        self.dismiss()
                    }
                }
            }

            await self.onSave(saved, test)
            guard self.operationToken == token, !Task.isCancelled else { return }

            if test {
                let passed = self.localGatewayRuntime.lastLocalLLMProbeSucceeded == true
                self.statusIsError = !passed
                if passed {
                    self.statusText = "Quick test passed."
                    self.statusResponsePreview = self.localGatewayRuntime.lastLocalLLMProbeResponseText
                } else {
                    self.statusText = self.localGatewayRuntime.lastLocalLLMProbeErrorText ?? "Quick test failed."
                    self.statusResponsePreview = nil
                }
            } else if !dismissAfterSave {
                self.statusText = "Saved and restarted."
                self.statusIsError = false
            }
            self.statusScrollTrigger = UUID()
        }
        self.saveOperationTask = task
    }

    private func startProgressTicker(isTest: Bool) {
        self.stopProgressTicker()
        self.operationIsTest = isTest
        self.operationStartedAt = Date()
        self.operationElapsedSeconds = 0
        self.progressTickerTask = Task { @MainActor in
            while !Task.isCancelled, self.isApplyingChanges {
                if let startedAt = self.operationStartedAt {
                    self.operationElapsedSeconds = max(0, Int(Date().timeIntervalSince(startedAt)))
                }
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
    }

    private func stopProgressTicker() {
        self.progressTickerTask?.cancel()
        self.progressTickerTask = nil
        self.operationStartedAt = nil
        self.operationElapsedSeconds = 0
    }

    private func cancelCurrentOperation() {
        self.saveOperationTask?.cancel()
        self.saveOperationTask = nil
        self.operationToken = UUID()
        self.isApplyingChanges = false
        self.stopProgressTicker()
        self.statusIsError = true
        self.statusResponsePreview = nil
        self.statusText = self.operationIsTest ? "Test canceled." : "Operation canceled."
        self.statusScrollTrigger = UUID()
    }
}
#endif
