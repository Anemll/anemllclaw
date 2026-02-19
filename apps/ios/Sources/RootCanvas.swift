import Security
import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct RootCanvas: View {
    @Environment(NodeAppModel.self) private var appModel
    @Environment(GatewayConnectionController.self) private var gatewayController
    @Environment(TVOSLocalGatewayRuntime.self) private var localGatewayRuntime
    @Environment(VoiceWakeManager.self) private var voiceWake
    @Environment(\.colorScheme) private var systemColorScheme
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage(VoiceWakePreferences.enabledKey) private var voiceWakeEnabled: Bool = false
    @AppStorage("screen.preventSleep") private var preventSleep: Bool = true
    @AppStorage("canvas.debugStatusEnabled") private var canvasDebugStatusEnabled: Bool = false
    @AppStorage("onboarding.requestID") private var onboardingRequestID: Int = 0
    @AppStorage("gateway.onboardingComplete") private var onboardingComplete: Bool = false
    @AppStorage("gateway.hasConnectedOnce") private var hasConnectedOnce: Bool = false
    @AppStorage("gateway.preferredStableID") private var preferredGatewayStableID: String = ""
    @AppStorage("gateway.manual.enabled") private var manualGatewayEnabled: Bool = false
    @AppStorage("gateway.manual.host") private var manualGatewayHost: String = ""
    @AppStorage("onboarding.quickSetupDismissed") private var quickSetupDismissed: Bool = false
    @AppStorage("llm.setupPrompt.suppressed") private var llmSetupPromptSuppressed: Bool = false
    @State private var presentedSheet: PresentedSheet?
    @State private var voiceWakeToastText: String?
    @State private var toastDismissTask: Task<Void, Never>?
    @State private var showOnboarding: Bool = false
    @State private var onboardingAllowSkip: Bool = true
    @State private var didEvaluateOnboarding: Bool = false
    @State private var didAutoOpenSettings: Bool = false
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
        case settings
        case chat
        case quickSetup

        var id: Int {
            switch self {
            case .settings: 0
            case .chat: 1
            case .quickSetup: 2
            }
        }
    }

    enum StartupPresentationRoute: Equatable {
        case none
        case onboarding
        case settings
    }

    private struct BackupStatusAlert: Identifiable {
        let id = UUID()
        let title: String
        let message: String
    }

    static func startupPresentationRoute(
        gatewayConnected: Bool,
        hasConnectedOnce: Bool,
        onboardingComplete: Bool,
        hasExistingGatewayConfig: Bool,
        shouldPresentOnLaunch: Bool) -> StartupPresentationRoute
    {
        if gatewayConnected {
            return .none
        }
        // On first run or explicit launch onboarding state, onboarding always wins.
        if shouldPresentOnLaunch || !hasConnectedOnce || !onboardingComplete {
            return .onboarding
        }
        // Settings auto-open is a recovery path for previously-connected installs only.
        if !hasExistingGatewayConfig {
            return .settings
        }
        return .none
    }

    var body: some View {
        self.backupRestoreWrapped(
            ZStack {
                CanvasContent(
                    systemColorScheme: self.systemColorScheme,
                    gatewayStatus: self.gatewayStatus,
                    voiceWakeEnabled: self.voiceWakeEnabled,
                    voiceWakeToastText: self.voiceWakeToastText,
                    cameraHUDText: self.appModel.cameraHUDText,
                    cameraHUDKind: self.appModel.cameraHUDKind,
                    openChat: {
                        self.presentedSheet = .chat
                    },
                    openSettings: {
                        self.presentedSheet = .settings
                    },
                    openBackupRestore: {
                        self.showBackupRestoreActions = true
                    })
                    .preferredColorScheme(.dark)

                if self.appModel.cameraFlashNonce != 0 {
                    CameraFlashOverlay(nonce: self.appModel.cameraFlashNonce)
                }
            }
            .gatewayTrustPromptAlert()
            .sheet(item: self.$presentedSheet) { sheet in
                switch sheet {
                case .settings:
                    SettingsTab()
                        .environment(self.appModel)
                        .environment(self.appModel.voiceWake)
                        .environment(self.gatewayController)
                        .environment(self.localGatewayRuntime)
                case .chat:
                    if let host = self.localGatewayRuntime.host {
                        ChatSheet(
                            transport: LocalGatewayChatTransport(host: host),
                            sessionKey: self.localGatewayRuntime.chatSessionKey,
                            agentName: self.localGatewayRuntime.chatAssistantName,
                            userAccent: self.appModel.seamColor)
                    } else {
                        ChatSheet(
                            gateway: self.appModel.gatewaySession,
                            sessionKey: self.appModel.mainSessionKey,
                            agentName: self.appModel.activeAgentName,
                            userAccent: self.appModel.seamColor)
                    }
                case .quickSetup:
                    GatewayQuickSetupSheet()
                        .environment(self.appModel)
                        .environment(self.gatewayController)
                }
            }
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
            .onAppear { self.updateIdleTimer() }
            .onAppear { self.evaluateOnboardingPresentation(force: false) }
            .onAppear { self.maybeAutoOpenSettings() }
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
                self.maybeAutoOpenSettings()
            }
            .onChange(of: self.voiceWake.lastTriggeredCommand) { _, newValue in
                guard let newValue else { return }
                let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { return }

                self.toastDismissTask?.cancel()
                withAnimation(.spring(response: 0.25, dampingFraction: 0.85)) {
                    self.voiceWakeToastText = trimmed
                }

                self.toastDismissTask = Task {
                    try? await Task.sleep(nanoseconds: 2_300_000_000)
                    await MainActor.run {
                        withAnimation(.easeOut(duration: 0.25)) {
                            self.voiceWakeToastText = nil
                        }
                    }
                }
            }
            .onDisappear {
                UIApplication.shared.isIdleTimerDisabled = false
                self.toastDismissTask?.cancel()
                self.toastDismissTask = nil
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

    private var gatewayStatus: StatusPill.GatewayState {
        // Local server is primary — show connected when running.
        if self.localGatewayRuntime.state == .running && self.localGatewayRuntime.host != nil {
            return .connected
        }
        if self.appModel.gatewayServerName != nil { return .connected }

        let text = self.appModel.gatewayStatusText.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.localizedCaseInsensitiveContains("connecting") ||
            text.localizedCaseInsensitiveContains("reconnecting")
        {
            return .connecting
        }

        if text.localizedCaseInsensitiveContains("error") {
            return .error
        }

        return .disconnected
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
        let route = Self.startupPresentationRoute(
            gatewayConnected: self.appModel.gatewayServerName != nil,
            hasConnectedOnce: self.hasConnectedOnce,
            onboardingComplete: self.onboardingComplete,
            hasExistingGatewayConfig: self.hasExistingGatewayConfig(),
            shouldPresentOnLaunch: OnboardingStateStore.shouldPresentOnLaunch(appModel: self.appModel))
        switch route {
        case .none:
            break
        case .onboarding:
            self.onboardingAllowSkip = true
            self.showOnboarding = true
        case .settings:
            self.didAutoOpenSettings = true
            self.presentedSheet = .settings
        }
    }

    private func hasExistingGatewayConfig() -> Bool {
        if GatewaySettingsStore.loadLastGatewayConnection() != nil { return true }
        let manualHost = self.manualGatewayHost.trimmingCharacters(in: .whitespacesAndNewlines)
        return self.manualGatewayEnabled && !manualHost.isEmpty
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
                self.backupStatusAlert = BackupStatusAlert(
                    title: "Restore Complete",
                    message:
                    "Restored \(restored.restoredFileCount) files, "
                        + "\(restored.restoredDefaultsCount) settings, "
                        + "\(restored.restoredKeychainCount) keychain entries.")
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

    private func maybeAutoOpenSettings() {
        guard !self.didAutoOpenSettings else { return }
        guard !self.showOnboarding else { return }
        // Local server is primary — don't auto-open settings for remote gateway.
        if self.localGatewayRuntime.state == .running || self.localGatewayRuntime.host != nil {
            return
        }
        let route = Self.startupPresentationRoute(
            gatewayConnected: self.appModel.gatewayServerName != nil,
            hasConnectedOnce: self.hasConnectedOnce,
            onboardingComplete: self.onboardingComplete,
            hasExistingGatewayConfig: self.hasExistingGatewayConfig(),
            shouldPresentOnLaunch: false)
        guard route == .settings else { return }
        self.didAutoOpenSettings = true
        self.presentedSheet = .settings
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
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 200_000_000)
            self.presentedSheet = .settings
        }
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

private struct CanvasContent: View {
    @Environment(NodeAppModel.self) private var appModel
    @AppStorage("talk.enabled") private var talkEnabled: Bool = false
    @AppStorage("talk.button.enabled") private var talkButtonEnabled: Bool = true
    @State private var showGatewayActions: Bool = false
    var systemColorScheme: ColorScheme
    var gatewayStatus: StatusPill.GatewayState
    var voiceWakeEnabled: Bool
    var voiceWakeToastText: String?
    var cameraHUDText: String?
    var cameraHUDKind: NodeAppModel.CameraHUDKind?
    var openChat: () -> Void
    var openSettings: () -> Void
    var openBackupRestore: () -> Void

    private var brightenButtons: Bool { self.systemColorScheme == .light }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            ScreenTab()

            VStack(spacing: 10) {
                OverlayButton(systemImage: "text.bubble.fill", brighten: self.brightenButtons) {
                    self.openChat()
                }
                .accessibilityLabel("Chat")

                if self.talkButtonEnabled {
                    // Talk mode lives on a side bubble so it doesn't get buried in settings.
                    OverlayButton(
                        systemImage: self.appModel.talkMode.isEnabled ? "waveform.circle.fill" : "waveform.circle",
                        brighten: self.brightenButtons,
                        tint: self.appModel.seamColor,
                        isActive: self.appModel.talkMode.isEnabled)
                    {
                        let next = !self.appModel.talkMode.isEnabled
                        self.talkEnabled = next
                        self.appModel.setTalkEnabled(next)
                    }
                    .accessibilityLabel("Talk Mode")
                }

                OverlayButton(systemImage: "gearshape.fill", brighten: self.brightenButtons) {
                    self.openSettings()
                }
                .accessibilityLabel("Settings")

                OverlayButton(systemImage: "archivebox.fill", brighten: self.brightenButtons) {
                    self.openBackupRestore()
                }
                .accessibilityLabel("Backup and Restore")
            }
            .padding(.top, 10)
            .padding(.trailing, 10)
        }
        .overlay(alignment: .center) {
            if self.appModel.talkMode.isEnabled {
                TalkOrbOverlay()
                    .transition(.opacity)
            }
        }
        .overlay(alignment: .topLeading) {
            StatusPill(
                gateway: self.gatewayStatus,
                voiceWakeEnabled: self.voiceWakeEnabled,
                activity: self.statusActivity,
                brighten: self.brightenButtons,
                onTap: {
                    if self.appModel.gatewayServerName != nil {
                        self.showGatewayActions = true
                    } else {
                        self.openSettings()
                    }
                })
                .padding(.leading, 10)
                .safeAreaPadding(.top, 10)
        }
        .overlay(alignment: .topLeading) {
            if let voiceWakeToastText, !voiceWakeToastText.isEmpty {
                VoiceWakeToast(
                    command: voiceWakeToastText,
                    brighten: self.brightenButtons)
                    .padding(.leading, 10)
                    .safeAreaPadding(.top, 58)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .confirmationDialog(
            "Gateway",
            isPresented: self.$showGatewayActions,
            titleVisibility: .visible)
        {
            Button("Disconnect", role: .destructive) {
                self.appModel.disconnectGateway()
            }
            Button("Open Settings") {
                self.openSettings()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Disconnect from the gateway?")
        }
    }

    private var statusActivity: StatusPill.Activity? {
        // Status pill owns transient activity state so it doesn't overlap the connection indicator.
        if self.appModel.isBackgrounded {
            return StatusPill.Activity(
                title: "Foreground required",
                systemImage: "exclamationmark.triangle.fill",
                tint: .orange)
        }

        let gatewayStatus = self.appModel.gatewayStatusText.trimmingCharacters(in: .whitespacesAndNewlines)
        let gatewayLower = gatewayStatus.lowercased()
        if gatewayLower.contains("repair") {
            return StatusPill.Activity(title: "Repairing…", systemImage: "wrench.and.screwdriver", tint: .orange)
        }
        if gatewayLower.contains("approval") || gatewayLower.contains("pairing") {
            return StatusPill.Activity(title: "Approval pending", systemImage: "person.crop.circle.badge.clock")
        }
        // Avoid duplicating the primary gateway status ("Connecting…") in the activity slot.

        if self.appModel.screenRecordActive {
            return StatusPill.Activity(title: "Recording screen…", systemImage: "record.circle.fill", tint: .red)
        }

        if let cameraHUDText, !cameraHUDText.isEmpty, let cameraHUDKind {
            let systemImage: String
            let tint: Color?
            switch cameraHUDKind {
            case .photo:
                systemImage = "camera.fill"
                tint = nil
            case .recording:
                systemImage = "video.fill"
                tint = .red
            case .success:
                systemImage = "checkmark.circle.fill"
                tint = .green
            case .error:
                systemImage = "exclamationmark.triangle.fill"
                tint = .red
            }
            return StatusPill.Activity(title: cameraHUDText, systemImage: systemImage, tint: tint)
        }

        if self.voiceWakeEnabled {
            let voiceStatus = self.appModel.voiceWake.statusText
            if voiceStatus.localizedCaseInsensitiveContains("microphone permission") {
                return StatusPill.Activity(title: "Mic permission", systemImage: "mic.slash", tint: .orange)
            }
            if voiceStatus == "Paused" {
                // Talk mode intentionally pauses voice wake to release the mic. Don't spam the HUD for that case.
                if self.appModel.talkMode.isEnabled {
                    return nil
                }
                let suffix = self.appModel.isBackgrounded ? " (background)" : ""
                return StatusPill.Activity(title: "Voice Wake paused\(suffix)", systemImage: "pause.circle.fill")
            }
        }

        return nil
    }
}

private struct OverlayButton: View {
    let systemImage: String
    let brighten: Bool
    var tint: Color?
    var isActive: Bool = false
    let action: () -> Void

    var body: some View {
        Button(action: self.action) {
            Image(systemName: self.systemImage)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(self.isActive ? (self.tint ?? .primary) : .primary)
                .padding(10)
                .background {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(.ultraThinMaterial)
                        .overlay {
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .fill(
                                    LinearGradient(
                                        colors: [
                                            .white.opacity(self.brighten ? 0.26 : 0.18),
                                            .white.opacity(self.brighten ? 0.08 : 0.04),
                                            .clear,
                                        ],
                                        startPoint: .topLeading,
                                        endPoint: .bottomTrailing))
                                .blendMode(.overlay)
                        }
                        .overlay {
                            if let tint {
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .fill(
                                        LinearGradient(
                                            colors: [
                                                tint.opacity(self.isActive ? 0.22 : 0.14),
                                                tint.opacity(self.isActive ? 0.10 : 0.06),
                                                .clear,
                                            ],
                                            startPoint: .topLeading,
                                            endPoint: .bottomTrailing))
                                    .blendMode(.overlay)
                            }
                        }
                        .overlay {
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .strokeBorder(
                                    (self.tint ?? .white).opacity(self.isActive ? 0.34 : (self.brighten ? 0.24 : 0.18)),
                                    lineWidth: self.isActive ? 0.7 : 0.5)
                        }
                        .shadow(color: .black.opacity(0.35), radius: 12, y: 6)
                }
        }
        .buttonStyle(.plain)
    }
}

private struct CameraFlashOverlay: View {
    var nonce: Int

    @State private var opacity: CGFloat = 0
    @State private var task: Task<Void, Never>?

    var body: some View {
        Color.white
            .opacity(self.opacity)
            .ignoresSafeArea()
            .allowsHitTesting(false)
            .onChange(of: self.nonce) { _, _ in
                self.task?.cancel()
                self.task = Task { @MainActor in
                    withAnimation(.easeOut(duration: 0.08)) {
                        self.opacity = 0.85
                    }
                    try? await Task.sleep(nanoseconds: 110_000_000)
                    withAnimation(.easeOut(duration: 0.32)) {
                        self.opacity = 0
                    }
                }
            }
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
                        + "In Settings, choose provider, base URL, API key, and model, "
                        + "then tap Apply, Restart & Test."
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

private struct OpenClawBackupExportDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.data] }

    var data: Data

    init(data: Data) {
        self.data = data
    }

    init(configuration: ReadConfiguration) throws {
        self.data = configuration.file.regularFileContents ?? Data()
    }

    func fileWrapper(configuration _: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: self.data)
    }
}

private struct OpenClawBackupArtifact: Sendable {
    let data: Data
    let defaultFileName: String
    let fileCount: Int
    let defaultsCount: Int
    let keychainCount: Int
}

private struct OpenClawBackupRestoreResult: Sendable {
    let restoredFileCount: Int
    let restoredDefaultsCount: Int
    let restoredKeychainCount: Int
}

private enum OpenClawBackupError: LocalizedError {
    case invalidArchive
    case unsupportedArchiveVersion(Int)
    case unsupportedApp(String)
    case userDefaultsSerializationFailed
    case userDefaultsDeserializationFailed
    case keychainReadFailed(OSStatus)
    case compressionFailed
    case decompressionFailed

    var errorDescription: String? {
        switch self {
        case .invalidArchive:
            return "Invalid backup file."
        case let .unsupportedArchiveVersion(version):
            return "Unsupported backup version: \(version)."
        case let .unsupportedApp(app):
            return "Backup belongs to another app target (\(app))."
        case .userDefaultsSerializationFailed:
            return "Could not export settings."
        case .userDefaultsDeserializationFailed:
            return "Could not restore settings."
        case let .keychainReadFailed(status):
            return "Could not read keychain items (status \(status))."
        case .compressionFailed:
            return "Could not compress backup data."
        case .decompressionFailed:
            return "Could not decompress backup data."
        }
    }
}

private enum OpenClawBackupManager {
    private static let archiveMagic = Data("OCB1".utf8)
    private static let archiveVersion = 1
    private static let keychainServices = [
        "ai.openclaw.gateway",
        "ai.openclaw.node",
        "ai.openclaw.talk",
    ]

    private struct Archive: Codable {
        let version: Int
        let createdAtISO8601: String
        let appBundleIdentifier: String
        let appVersion: String
        let defaultsDomainPlist: Data
        let files: [ArchivedFile]
        let keychainItems: [KeychainItem]
    }

    private struct ArchivedFile: Codable, Hashable {
        let pathToken: String
        let data: Data
    }

    private struct KeychainItem: Codable, Hashable {
        let service: String
        let account: String
        let value: String
    }

    private struct RootAlias {
        let alias: String
        let url: URL
    }

    static func createBackupArtifact(now: Date = Date()) throws -> OpenClawBackupArtifact {
        let fileManager = FileManager.default
        let roots = self.roots(fileManager: fileManager)
        let files = try self.captureFiles(fileManager: fileManager, roots: roots)
        let defaultsData = try self.captureDefaults()
        let keychainItems = try self.captureKeychainItems()

        let archive = Archive(
            version: self.archiveVersion,
            createdAtISO8601: ISO8601DateFormatter().string(from: now),
            appBundleIdentifier: Bundle.main.bundleIdentifier ?? "ai.openclaw.ios",
            appVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev",
            defaultsDomainPlist: defaultsData,
            files: files,
            keychainItems: keychainItems)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let encoded = try encoder.encode(archive)
        let compressed = try self.compress(encoded)

        var payload = Data()
        payload.append(self.archiveMagic)
        payload.append(compressed)

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let fileName = "OpenClaw-Backup-\(formatter.string(from: now)).ocbackup"

        let defaultsCount = (try? self.decodeDefaultsDomain(defaultsData).count) ?? 0
        return OpenClawBackupArtifact(
            data: payload,
            defaultFileName: fileName,
            fileCount: files.count,
            defaultsCount: defaultsCount,
            keychainCount: keychainItems.count)
    }

    static func restoreBackupArchive(from payload: Data) throws -> OpenClawBackupRestoreResult {
        let archive = try self.decodeArchive(payload)
        guard archive.version == self.archiveVersion else {
            throw OpenClawBackupError.unsupportedArchiveVersion(archive.version)
        }

        let currentBundleId = Bundle.main.bundleIdentifier ?? "ai.openclaw.ios"
        guard archive.appBundleIdentifier == currentBundleId else {
            throw OpenClawBackupError.unsupportedApp(archive.appBundleIdentifier)
        }

        let fileManager = FileManager.default
        try self.clearKnownPersistentStorage(fileManager: fileManager)

        let roots = self.roots(fileManager: fileManager)
        let rootsByAlias = Dictionary(uniqueKeysWithValues: roots.map { ($0.alias, $0.url) })

        var restoredFiles = 0
        for entry in archive.files {
            guard let destination = self.url(fromToken: entry.pathToken, rootsByAlias: rootsByAlias) else {
                continue
            }
            try fileManager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try entry.data.write(to: destination, options: .atomic)
            restoredFiles += 1
        }

        let defaultsDomain = try self.decodeDefaultsDomain(archive.defaultsDomainPlist)
        UserDefaults.standard.setPersistentDomain(defaultsDomain, forName: currentBundleId)
        UserDefaults.standard.synchronize()

        for service in self.keychainServices {
            self.deleteAllKeychainEntries(service: service)
        }

        var restoredKeychain = 0
        for item in archive.keychainItems {
            guard self.keychainServices.contains(item.service) else { continue }
            if KeychainStore.saveString(item.value, service: item.service, account: item.account) {
                restoredKeychain += 1
            }
        }

        return OpenClawBackupRestoreResult(
            restoredFileCount: restoredFiles,
            restoredDefaultsCount: defaultsDomain.count,
            restoredKeychainCount: restoredKeychain)
    }

    private static func decodeArchive(_ payload: Data) throws -> Archive {
        let archiveData: Data
        if payload.starts(with: self.archiveMagic) {
            archiveData = try self.decompress(Data(payload.dropFirst(self.archiveMagic.count)))
        } else if let decoded = try? JSONDecoder().decode(Archive.self, from: payload) {
            return decoded
        } else {
            archiveData = try self.decompress(payload)
        }

        guard let archive = try? JSONDecoder().decode(Archive.self, from: archiveData) else {
            throw OpenClawBackupError.invalidArchive
        }
        return archive
    }

    private static func compress(_ data: Data) throws -> Data {
        guard let compressed = try (data as NSData).compressed(using: .lzfse) as Data? else {
            throw OpenClawBackupError.compressionFailed
        }
        return compressed
    }

    private static func decompress(_ data: Data) throws -> Data {
        guard let decompressed = try (data as NSData).decompressed(using: .lzfse) as Data? else {
            throw OpenClawBackupError.decompressionFailed
        }
        return decompressed
    }

    private static func captureDefaults() throws -> Data {
        let bundleID = Bundle.main.bundleIdentifier ?? "ai.openclaw.ios"
        let domain = UserDefaults.standard.persistentDomain(forName: bundleID) ?? [:]
        guard PropertyListSerialization.propertyList(domain, isValidFor: .binary) else {
            throw OpenClawBackupError.userDefaultsSerializationFailed
        }
        return try PropertyListSerialization.data(fromPropertyList: domain, format: .binary, options: 0)
    }

    private static func decodeDefaultsDomain(_ data: Data) throws -> [String: Any] {
        let object = try PropertyListSerialization.propertyList(from: data, options: [], format: nil)
        guard let domain = object as? [String: Any] else {
            throw OpenClawBackupError.userDefaultsDeserializationFailed
        }
        return domain
    }

    private static func captureKeychainItems() throws -> [KeychainItem] {
        var items: [KeychainItem] = []
        for service in self.keychainServices {
            let serviceItems = try self.readKeychainItems(service: service)
            items.append(contentsOf: serviceItems)
        }
        return items.sorted { lhs, rhs in
            if lhs.service == rhs.service {
                return lhs.account < rhs.account
            }
            return lhs.service < rhs.service
        }
    }

    private static func readKeychainItems(service: String) throws -> [KeychainItem] {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecMatchLimit as String: kSecMatchLimitAll,
            kSecReturnAttributes as String: true,
            kSecReturnData as String: true,
        ]

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound {
            return []
        }
        guard status == errSecSuccess else {
            throw OpenClawBackupError.keychainReadFailed(status)
        }

        let rows: [[String: Any]]
        if let array = result as? [[String: Any]] {
            rows = array
        } else if let one = result as? [String: Any] {
            rows = [one]
        } else {
            rows = []
        }

        var items: [KeychainItem] = []
        for row in rows {
            guard let account = row[kSecAttrAccount as String] as? String,
                  let data = row[kSecValueData as String] as? Data,
                  let value = String(data: data, encoding: .utf8)
            else {
                continue
            }
            items.append(KeychainItem(service: service, account: account, value: value))
        }
        return items
    }

    private static func deleteAllKeychainEntries(service: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
        ]
        _ = SecItemDelete(query as CFDictionary)
    }

    private static func roots(fileManager: FileManager) -> [RootAlias] {
        var values: [RootAlias] = []
        if let documents = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first {
            values.append(RootAlias(alias: "documents", url: documents))
        }
        if let caches = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first {
            values.append(RootAlias(alias: "caches", url: caches))
        }
        if let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            values.append(RootAlias(alias: "appSupport", url: appSupport))
        }
        if let library = fileManager.urls(for: .libraryDirectory, in: .userDomainMask).first {
            values.append(RootAlias(alias: "library", url: library))
        }
        values.append(RootAlias(alias: "tmp", url: fileManager.temporaryDirectory))
        return values
    }

    private static func pathToken(for fileURL: URL, roots: [RootAlias]) -> String? {
        let standardized = fileURL.standardizedFileURL.path
        let sortedRoots = roots.sorted { lhs, rhs in
            lhs.url.standardizedFileURL.path.count > rhs.url.standardizedFileURL.path.count
        }

        for root in sortedRoots {
            let rootPath = root.url.standardizedFileURL.path
            if standardized == rootPath {
                return root.alias
            }
            let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
            guard standardized.hasPrefix(prefix) else { continue }
            let relative = String(standardized.dropFirst(prefix.count))
            if relative.isEmpty { continue }
            return "\(root.alias)/\(relative)"
        }
        return nil
    }

    private static func url(fromToken token: String, rootsByAlias: [String: URL]) -> URL? {
        let parts = token.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false)
        guard let alias = parts.first.map(String.init),
              let root = rootsByAlias[alias]
        else {
            return nil
        }
        guard parts.count > 1 else { return root }
        let relative = String(parts[1])
        guard !relative.contains("..") else { return nil }
        return root.appendingPathComponent(relative, isDirectory: false)
    }

    private static func captureFiles(fileManager: FileManager, roots: [RootAlias]) throws -> [ArchivedFile] {
        var tokenToData: [String: Data] = [:]

        func addFile(_ fileURL: URL) throws {
            guard self.isRegularFile(fileURL, fileManager: fileManager) else { return }
            guard let token = self.pathToken(for: fileURL, roots: roots) else { return }
            let data = try Data(contentsOf: fileURL)
            tokenToData[token] = data
        }

        func addDirectory(_ directoryURL: URL) throws {
            guard self.isDirectory(directoryURL, fileManager: fileManager) else { return }
            guard let enumerator = fileManager.enumerator(
                at: directoryURL,
                includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey],
                options: [],
                errorHandler: nil)
            else {
                return
            }

            for case let fileURL as URL in enumerator {
                guard self.isRegularFile(fileURL, fileManager: fileManager) else { continue }
                try addFile(fileURL)
            }
        }

        for directory in self.workspaceCandidates(fileManager: fileManager) {
            try addDirectory(directory)
        }

        let memoryPaths = self.memoryStoreCandidates(fileManager: fileManager)
        for memoryPath in memoryPaths {
            try addFile(memoryPath)
            try addFile(URL(fileURLWithPath: memoryPath.path + "-wal"))
            try addFile(URL(fileURLWithPath: memoryPath.path + "-shm"))
            let cronDirectory = memoryPath
                .deletingLastPathComponent()
                .appendingPathComponent("cron", isDirectory: true)
            try addDirectory(cronDirectory)
        }

        for pairingFile in self.telegramPairingCandidates(fileManager: fileManager) {
            try addFile(pairingFile)
        }

        for directory in self.additionalDirectoryCandidates(fileManager: fileManager) {
            try addDirectory(directory)
        }

        for file in self.additionalFileCandidates(fileManager: fileManager) {
            try addFile(file)
        }

        return tokenToData
            .map { ArchivedFile(pathToken: $0.key, data: $0.value) }
            .sorted { lhs, rhs in lhs.pathToken < rhs.pathToken }
    }

    private static func clearKnownPersistentStorage(fileManager: FileManager) throws {
        let workspaceCandidates = self.workspaceCandidates(fileManager: fileManager)
        let memoryCandidates = self.memoryStoreCandidates(fileManager: fileManager)
        let pairingCandidates = self.telegramPairingCandidates(fileManager: fileManager)
        let additionalDirectories = self.additionalDirectoryCandidates(fileManager: fileManager)
        let additionalFiles = self.additionalFileCandidates(fileManager: fileManager)

        for directory in workspaceCandidates {
            try self.removeIfExists(directory, fileManager: fileManager)
        }
        for memoryPath in memoryCandidates {
            try self.removeIfExists(memoryPath, fileManager: fileManager)
            try self.removeIfExists(URL(fileURLWithPath: memoryPath.path + "-wal"), fileManager: fileManager)
            try self.removeIfExists(URL(fileURLWithPath: memoryPath.path + "-shm"), fileManager: fileManager)
            let cronDirectory = memoryPath
                .deletingLastPathComponent()
                .appendingPathComponent("cron", isDirectory: true)
            try self.removeIfExists(cronDirectory, fileManager: fileManager)
        }
        for file in pairingCandidates {
            try self.removeIfExists(file, fileManager: fileManager)
        }
        for directory in additionalDirectories {
            try self.removeIfExists(directory, fileManager: fileManager)
        }
        for file in additionalFiles {
            try self.removeIfExists(file, fileManager: fileManager)
        }
    }

    private static func workspaceCandidates(fileManager: FileManager) -> [URL] {
        var values: [URL] = []
        if let documents = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first {
            values.append(
                documents
                    .appendingPathComponent("OpenClawTV", isDirectory: true)
                    .appendingPathComponent("Workspace", isDirectory: true))
        }
        if let caches = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first {
            values.append(caches.appendingPathComponent("OpenClawTVWorkspace", isDirectory: true))
        }
        values.append(fileManager.temporaryDirectory.appendingPathComponent("OpenClawTVWorkspace", isDirectory: true))
        return self.uniqueURLs(values)
    }

    private static func memoryStoreCandidates(fileManager: FileManager) -> [URL] {
        var values: [URL] = []
        if let caches = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first {
            values.append(
                caches
                    .appendingPathComponent("OpenClawTV", isDirectory: true)
                    .appendingPathComponent("GatewayMemory.sqlite", isDirectory: false))
            values.append(caches.appendingPathComponent("GatewayMemory.sqlite", isDirectory: false))
        }
        if let library = fileManager.urls(for: .libraryDirectory, in: .userDomainMask).first {
            values.append(
                library
                    .appendingPathComponent("Caches", isDirectory: true)
                    .appendingPathComponent("OpenClawTV", isDirectory: true)
                    .appendingPathComponent("GatewayMemory.sqlite", isDirectory: false))
            values.append(
                library
                    .appendingPathComponent("Caches", isDirectory: true)
                    .appendingPathComponent("GatewayMemory.sqlite", isDirectory: false))
        }
        values.append(fileManager.temporaryDirectory.appendingPathComponent("GatewayMemory.sqlite", isDirectory: false))
        return self.uniqueURLs(values)
    }

    private static func telegramPairingCandidates(fileManager: FileManager) -> [URL] {
        var values: [URL] = []
        if let caches = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first {
            values.append(
                caches
                    .appendingPathComponent("OpenClawTV", isDirectory: true)
                    .appendingPathComponent("TelegramPairing.json", isDirectory: false))
            values.append(caches.appendingPathComponent("TelegramPairing.json", isDirectory: false))
        }
        values.append(fileManager.temporaryDirectory.appendingPathComponent("TelegramPairing.json", isDirectory: false))
        return self.uniqueURLs(values)
    }

    private static func additionalDirectoryCandidates(fileManager: FileManager) -> [URL] {
        var values: [URL] = []
        if let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            values.append(appSupport.appendingPathComponent("OpenClaw", isDirectory: true))
        }
        if let caches = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first {
            values.append(caches.appendingPathComponent("OpenClaw", isDirectory: true))
        }
        return self.uniqueURLs(values)
    }

    private static func additionalFileCandidates(fileManager: FileManager) -> [URL] {
        guard let documents = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first else {
            return []
        }
        return [documents.appendingPathComponent("openclaw-gateway.log", isDirectory: false)]
    }

    private static func uniqueURLs(_ values: [URL]) -> [URL] {
        var seen: Set<String> = []
        var deduped: [URL] = []
        for value in values {
            let key = value.standardizedFileURL.path
            if seen.contains(key) { continue }
            seen.insert(key)
            deduped.append(value)
        }
        return deduped
    }

    private static func isRegularFile(_ url: URL, fileManager: FileManager) -> Bool {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) else { return false }
        return !isDirectory.boolValue
    }

    private static func isDirectory(_ url: URL, fileManager: FileManager) -> Bool {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) else { return false }
        return isDirectory.boolValue
    }

    private static func removeIfExists(_ url: URL, fileManager: FileManager) throws {
        guard fileManager.fileExists(atPath: url.path) else { return }
        try fileManager.removeItem(at: url)
    }
}
