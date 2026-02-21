import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct RootCanvas: View {
    @Environment(NodeAppModel.self) private var appModel
    @Environment(GatewayConnectionController.self) private var gatewayController
    @Environment(TVOSLocalGatewayRuntime.self) private var localGatewayRuntime
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("screen.preventSleep") private var preventSleep: Bool = true
    @AppStorage("canvas.debugStatusEnabled") private var canvasDebugStatusEnabled: Bool = false
    @AppStorage("onboarding.requestID") private var onboardingRequestID: Int = 0
    @AppStorage("gateway.onboardingComplete") private var onboardingComplete: Bool = false
    @AppStorage("gateway.hasConnectedOnce") private var hasConnectedOnce: Bool = false
    @AppStorage("onboarding.quickSetupDismissed") private var quickSetupDismissed: Bool = false
    @AppStorage("llm.setupPrompt.suppressed") private var llmSetupPromptSuppressed: Bool = false
    @State private var presentedSheet: PresentedSheet?
    @State private var showOnboarding: Bool = false
    @State private var onboardingAllowSkip: Bool = true
    @State private var didEvaluateOnboarding: Bool = false
    @State private var didEvaluateLLMSetupPromptOnLaunch: Bool = false
    @State private var showLLMSetupPrompt: Bool = false
    @State private var llmSetupPromptDontShowAgain: Bool = false
    @State private var showBackupRestoreActions: Bool = false
    @State private var showBackupConfirmAlert: Bool = false
    @State private var showRestoreImporter: Bool = false
    @State private var pendingRestoreFileURL: URL?
    @State private var showRestoreConfirmAlert: Bool = false
    @State private var backupOperationInFlight: Bool = false
    @State private var backupExportDocument = OpenClawBackupExportDocument(data: Data())
    @State private var backupExportFileName: String = "OpenClaw-Backup.ocbackup"
    @State private var showBackupExporter: Bool = false
    @State private var backupStatusAlert: BackupStatusAlert?

    private enum PresentedSheet: Identifiable {
        case quickSetup

        var id: Int {
            switch self {
            case .quickSetup: 0
            }
        }
    }

    private struct BackupStatusAlert: Identifiable {
        let id = UUID()
        let title: String
        let message: String
    }

    var body: some View {
        self.backupRestoreWrapped(
            Group {
                if self.localGatewayRuntime.host != nil {
                    ChatSheet(
                        transport: LocalGatewayChatTransport(runtime: self.localGatewayRuntime),
                        sessionKey: self.localGatewayRuntime.chatSessionKey,
                        agentName: self.localGatewayRuntime.chatAssistantName,
                        userAccent: self.appModel.seamColor,
                        allowDismiss: false)
                        .ignoresSafeArea()
                } else {
                    ChatSheet(
                        gateway: self.appModel.gatewaySession,
                        sessionKey: self.appModel.mainSessionKey,
                        agentName: self.appModel.activeAgentName,
                        userAccent: self.appModel.seamColor,
                        allowDismiss: false)
                        .ignoresSafeArea()
                }
            }
            .preferredColorScheme(.dark)
            .gatewayTrustPromptAlert()
            .fullScreenCover(isPresented: self.$showOnboarding) {
                OnboardingWizardView(
                    allowSkip: self.onboardingAllowSkip,
                    onClose: {
                        self.showOnboarding = false
                    })
                    .environment(self.appModel)
                    .environment(self.appModel.voiceWake)
                    .environment(self.gatewayController)
            }
            .sheet(item: self.$presentedSheet) { sheet in
                switch sheet {
                case .quickSetup:
                    GatewayQuickSetupSheet()
                        .environment(self.appModel)
                        .environment(self.gatewayController)
                }
            }
            .onAppear { self.updateIdleTimer() }
            .onAppear { self.evaluateOnboardingPresentation(force: false) }
            .onAppear { self.maybePromptForLLMSetupOnLaunch() }
            .onChange(of: self.preventSleep) { _, _ in self.updateIdleTimer() }
            .onChange(of: self.scenePhase) { _, _ in self.updateIdleTimer() }
            .onChange(of: self.localGatewayRuntime.state) { _, _ in
                self.maybePromptForLLMSetupOnLaunch()
            }
            .onChange(of: self.localGatewayRuntime.localLLMConfigured) { _, newValue in
                if newValue {
                    self.showLLMSetupPrompt = false
                }
            }
            .onAppear { self.maybeShowQuickSetup() }
            .onChange(of: self.gatewayController.gateways.count) { _, _ in self.maybeShowQuickSetup() }
            .onAppear { self.updateCanvasDebugStatus() }
            .onChange(of: self.canvasDebugStatusEnabled) { _, _ in self.updateCanvasDebugStatus() }
            .onChange(of: self.appModel.gatewayStatusText) { _, _ in self.updateCanvasDebugStatus() }
            .onChange(of: self.appModel.gatewayServerName) { _, _ in self.updateCanvasDebugStatus() }
            .onChange(of: self.appModel.gatewayServerName) { _, newValue in
                if newValue != nil {
                    self.showOnboarding = false
                }
            }
            .onChange(of: self.onboardingRequestID) { _, _ in
                self.evaluateOnboardingPresentation(force: true)
            }
            .onChange(of: self.showOnboarding) { _, newValue in
                if !newValue {
                    self.maybePromptForLLMSetupOnLaunch()
                }
            }
            .onChange(of: self.appModel.gatewayRemoteAddress) { _, _ in self.updateCanvasDebugStatus() }
            .onChange(of: self.appModel.gatewayServerName) { _, newValue in
                if newValue != nil {
                    self.onboardingComplete = true
                    self.hasConnectedOnce = true
                    OnboardingStateStore.markCompleted(mode: nil)
                }
            }
            .onDisappear {
                UIApplication.shared.isIdleTimerDisabled = false
            }
        )
    }

    @ViewBuilder
    private func backupRestoreWrapped<Content: View>(_ content: Content) -> some View {
        content
            .overlay(alignment: .topTrailing) {
                if self.backupOperationInFlight {
                    ProgressView()
                        .controlSize(.small)
                        .padding(10)
                        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .padding(.top, 10)
                        .padding(.trailing, 10)
                        .allowsHitTesting(false)
                }
            }
            .confirmationDialog(
                "Backup / Restore",
                isPresented: self.$showBackupRestoreActions,
                titleVisibility: .visible)
            {
                Button("Backup to Files…") {
                    self.showBackupConfirmAlert = true
                }
                Button("Restore from Backup…", role: .destructive) {
                    self.showRestoreImporter = true
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Export or import local OpenClaw data.")
            }
            .alert("Create Backup?", isPresented: self.$showBackupConfirmAlert) {
                Button("Backup") {
                    Task { await self.performBackupExport() }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Backup includes chats, workspace files, settings, and saved credentials.")
            }
            .fileImporter(
                isPresented: self.$showRestoreImporter,
                allowedContentTypes: [.data],
                allowsMultipleSelection: false)
            { result in
                self.handleRestoreSelection(result)
            }
            .alert("Restore Backup?", isPresented: self.$showRestoreConfirmAlert) {
                Button("Restore", role: .destructive) {
                    Task { await self.performRestoreFromPendingFile() }
                }
                Button("Cancel", role: .cancel) {
                    self.pendingRestoreFileURL = nil
                }
            } message: {
                Text("This replaces current local chats, workspace files, settings, and saved credentials.")
            }
            .fileExporter(
                isPresented: self.$showBackupExporter,
                document: self.backupExportDocument,
                contentType: .data,
                defaultFilename: self.backupExportFileName)
            { result in
                switch result {
                case let .success(url):
                    self.backupStatusAlert = BackupStatusAlert(
                        title: "Backup Saved",
                        message: "Saved to \(url.lastPathComponent).")
                case let .failure(error):
                    self.backupStatusAlert = BackupStatusAlert(
                        title: "Backup Export Failed",
                        message: error.localizedDescription)
                }
            }
            .alert(item: self.$backupStatusAlert) { status in
                Alert(title: Text(status.title), message: Text(status.message), dismissButton: .default(Text("OK")))
            }
            .sheet(
                isPresented: self.$showLLMSetupPrompt,
                onDismiss: {
                    self.persistLLMSetupPromptPreferenceIfNeeded()
                },
                content: {
                    LLMSetupPromptSheet(
                        dontShowAgain: self.$llmSetupPromptDontShowAgain,
                        onSkip: {
                            self.handleLLMSetupPromptSkip()
                        },
                        onOpenSettings: {
                            self.handleLLMSetupPromptOpenSettings()
                        })
                })
    }

    private func updateIdleTimer() {
        UIApplication.shared.isIdleTimerDisabled = (self.scenePhase == .active && self.preventSleep)
    }

    private func updateCanvasDebugStatus() {
        self.appModel.screen.setDebugStatusEnabled(self.canvasDebugStatusEnabled)
        guard self.canvasDebugStatusEnabled else { return }
        let title = self.appModel.gatewayStatusText.trimmingCharacters(in: .whitespacesAndNewlines)
        let subtitle = self.appModel.gatewayServerName ?? self.appModel.gatewayRemoteAddress
        self.appModel.screen.updateDebugStatus(title: title, subtitle: subtitle)
    }

    private func evaluateOnboardingPresentation(force: Bool) {
        if force {
            self.onboardingAllowSkip = true
            self.showOnboarding = true
            return
        }

        guard !self.didEvaluateOnboarding else { return }
        self.didEvaluateOnboarding = true
        // Local server is primary — skip remote gateway onboarding.
        if self.localGatewayRuntime.state == .running || self.localGatewayRuntime.host != nil {
            return
        }
        if self.appModel.gatewayServerName != nil {
            return
        }
        if OnboardingStateStore.shouldPresentOnLaunch(appModel: self.appModel) || !self.hasConnectedOnce || !self.onboardingComplete {
            self.onboardingAllowSkip = true
            self.showOnboarding = true
        }
    }

    private func handleRestoreSelection(_ result: Result<[URL], any Error>) {
        switch result {
        case let .success(urls):
            guard let first = urls.first else { return }
            self.pendingRestoreFileURL = first
            self.showRestoreConfirmAlert = true
        case let .failure(error):
            self.backupStatusAlert = BackupStatusAlert(
                title: "Restore File Error",
                message: error.localizedDescription)
        }
    }

    private func performBackupExport() async {
        guard !self.backupOperationInFlight else { return }
        self.backupOperationInFlight = true
        let wasRunning = self.localGatewayRuntime.state == .running
        if wasRunning {
            await self.localGatewayRuntime.stop()
        }

        do {
            let artifact = try await Task.detached(priority: .userInitiated) {
                try OpenClawBackupManager.createBackupArtifact()
            }.value

            if wasRunning {
                await self.localGatewayRuntime.start()
                await self.localGatewayRuntime.probeHealth()
            }

            self.backupOperationInFlight = false
            self.backupExportDocument = OpenClawBackupExportDocument(data: artifact.data)
            self.backupExportFileName = artifact.defaultFileName
            self.showBackupExporter = true
        } catch {
            if wasRunning {
                await self.localGatewayRuntime.start()
                await self.localGatewayRuntime.probeHealth()
            }
            self.backupOperationInFlight = false
            self.backupStatusAlert = BackupStatusAlert(
                title: "Backup Failed",
                message: error.localizedDescription)
        }
    }

    private func performRestoreFromPendingFile() async {
        guard !self.backupOperationInFlight else { return }
        guard let url = self.pendingRestoreFileURL else { return }

        self.pendingRestoreFileURL = nil
        self.backupOperationInFlight = true

        let hasSecurityScope = url.startAccessingSecurityScopedResource()
        defer {
            if hasSecurityScope {
                url.stopAccessingSecurityScopedResource()
            }
        }

        do {
            let archiveData = try await Task.detached(priority: .userInitiated) {
                try Data(contentsOf: url, options: [.mappedIfSafe])
            }.value

            let wasRunning = self.localGatewayRuntime.state == .running
            if wasRunning {
                await self.localGatewayRuntime.stop()
            }

            do {
                let restored = try await Task.detached(priority: .userInitiated) {
                    try OpenClawBackupManager.restoreBackupArchive(from: archiveData)
                }.value

                await self.localGatewayRuntime.reloadPersistedControlPlaneSettings(startIfStopped: wasRunning)
                self.applyRestoredLocalPreferences()
                self.backupOperationInFlight = false
                let skippedNote = restored.skippedFileTokens.isEmpty
                    ? ""
                    : "\nSkipped \(restored.skippedFileTokens.count) file(s): "
                        + restored.skippedFileTokens.prefix(10).joined(separator: ", ")
                        + (restored.skippedFileTokens.count > 10 ? "…" : "")
                self.backupStatusAlert = BackupStatusAlert(
                    title: "Restore Complete",
                    message:
                    "Restored \(restored.restoredFileCount) files, "
                        + "\(restored.restoredDefaultsCount) settings, "
                        + "\(restored.restoredKeychainCount) keychain entries."
                        + skippedNote)
            } catch {
                await self.localGatewayRuntime.reloadPersistedControlPlaneSettings(startIfStopped: wasRunning)
                self.backupOperationInFlight = false
                self.backupStatusAlert = BackupStatusAlert(
                    title: "Restore Failed",
                    message: error.localizedDescription)
            }
        } catch {
            self.backupOperationInFlight = false
            self.backupStatusAlert = BackupStatusAlert(
                title: "Restore Failed",
                message: error.localizedDescription)
        }
    }

    private func applyRestoredLocalPreferences() {
        let voiceWake = UserDefaults.standard.bool(forKey: VoiceWakePreferences.enabledKey)
        self.appModel.setVoiceWakeEnabled(voiceWake)

        let talkEnabled = UserDefaults.standard.bool(forKey: "talk.enabled")
        self.appModel.setTalkEnabled(talkEnabled)
    }

    private func maybePromptForLLMSetupOnLaunch() {
        guard !self.didEvaluateLLMSetupPromptOnLaunch else { return }
        guard self.localGatewayRuntime.state == .running else { return }
        guard !self.showOnboarding else { return }

        self.didEvaluateLLMSetupPromptOnLaunch = true
        guard !self.llmSetupPromptSuppressed else { return }
        guard !self.localGatewayRuntime.localLLMConfigured else { return }

        self.llmSetupPromptDontShowAgain = false
        self.showLLMSetupPrompt = true
    }

    private func persistLLMSetupPromptPreferenceIfNeeded() {
        if self.llmSetupPromptDontShowAgain {
            self.llmSetupPromptSuppressed = true
        }
    }

    private func handleLLMSetupPromptSkip() {
        self.persistLLMSetupPromptPreferenceIfNeeded()
        self.showLLMSetupPrompt = false
    }

    private func handleLLMSetupPromptOpenSettings() {
        self.persistLLMSetupPromptPreferenceIfNeeded()
        self.showLLMSetupPrompt = false
    }

    private func maybeShowQuickSetup() {
        // Local server is primary — don't auto-prompt for remote gateway discovery.
        guard self.localGatewayRuntime.host == nil else { return }
        guard !self.quickSetupDismissed else { return }
        guard !self.showOnboarding else { return }
        guard self.presentedSheet == nil else { return }
        guard self.appModel.gatewayServerName == nil else { return }
        guard !self.gatewayController.gateways.isEmpty else { return }
        self.presentedSheet = .quickSetup
    }
}

private struct LLMSetupPromptSheet: View {
    @Binding var dontShowAgain: Bool
    var onSkip: () -> Void
    var onOpenSettings: () -> Void

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 16) {
                Label("Set up your LLM provider", systemImage: "sparkles.rectangle.stack.fill")
                    .font(.title3.weight(.semibold))
                Text(
                    "OpenClaw chat needs an LLM provider. "
                        + "Tap the gear icon in the top bar to open Settings, then choose provider, "
                        + "base URL, API key, and model, and tap Apply, Restart & Test."
                )
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                Toggle("Don't show again", isOn: self.$dontShowAgain)

                Spacer(minLength: 0)

                HStack(spacing: 12) {
                    Button("Skip", role: .cancel) {
                        self.onSkip()
                    }
                    .buttonStyle(.bordered)

                    Button("Open Settings") {
                        self.onOpenSettings()
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
            .padding(20)
            .navigationTitle("LLM Setup")
            .navigationBarTitleDisplayMode(.inline)
        }
        .presentationDetents([.medium])
        .presentationDragIndicator(.visible)
    }
}

// OpenClawBackupExportDocument, OpenClawBackupArtifact, OpenClawBackupRestoreResult,
// OpenClawBackupError, and OpenClawBackupManager are defined in
// Settings/OpenClawBackupManager.swift (shared between iOS and tvOS targets).
