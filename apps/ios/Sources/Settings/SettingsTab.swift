import OpenClawGatewayCore
import OpenClawKit
import Network
import Observation
import os
import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct SettingsTab: View {
    @Environment(NodeAppModel.self) private var appModel: NodeAppModel
    @Environment(VoiceWakeManager.self) private var voiceWake: VoiceWakeManager
    @Environment(GatewayConnectionController.self) private var gatewayController: GatewayConnectionController
    @Environment(TVOSLocalGatewayRuntime.self) private var localGatewayRuntime: TVOSLocalGatewayRuntime
    @Environment(\.dismiss) private var dismiss
    @AppStorage("node.displayName") private var displayName: String = "iOS Node"
    @AppStorage("node.instanceId") private var instanceId: String = UUID().uuidString
    @AppStorage("voiceWake.enabled") private var voiceWakeEnabled: Bool = false
    @AppStorage("talk.enabled") private var talkEnabled: Bool = false
    @AppStorage("talk.button.enabled") private var talkButtonEnabled: Bool = false
    @AppStorage("talk.background.enabled") private var talkBackgroundEnabled: Bool = false
    @AppStorage("talk.voiceDirectiveHint.enabled") private var talkVoiceDirectiveHintEnabled: Bool = false
    @AppStorage("camera.enabled") private var cameraEnabled: Bool = true
    @AppStorage("location.enabledMode") private var locationEnabledModeRaw: String = OpenClawLocationMode.off.rawValue
    @AppStorage("location.preciseEnabled") private var locationPreciseEnabled: Bool = true
    @AppStorage("screen.preventSleep") private var preventSleep: Bool = true
    @AppStorage("gateway.preferredStableID") private var preferredGatewayStableID: String = ""
    @AppStorage("gateway.lastDiscoveredStableID") private var lastDiscoveredGatewayStableID: String = ""
    @AppStorage("gateway.autoconnect") private var gatewayAutoConnect: Bool = false
    @AppStorage("gateway.manual.enabled") private var manualGatewayEnabled: Bool = false
    @AppStorage("gateway.manual.host") private var manualGatewayHost: String = ""
    @AppStorage("gateway.manual.port") private var manualGatewayPort: Int = 18789
    @AppStorage("gateway.manual.tls") private var manualGatewayTLS: Bool = true
    @AppStorage("gateway.discovery.debugLogs") private var discoveryDebugLogsEnabled: Bool = false
    @AppStorage("canvas.debugStatusEnabled") private var canvasDebugStatusEnabled: Bool = false
    @AppStorage("chat.toolCalls.visible") private var showsToolCallsInChat: Bool = true
    @AppStorage("chat.autoRetryAttemptsOnError") private var chatAutoRetryAttemptsOnError: Int = 1
    @AppStorage("llm.setupPrompt.suppressed") private var llmSetupPromptSuppressed: Bool = false

    // Onboarding control (RootCanvas listens to onboarding.requestID and force-opens the wizard).
    @AppStorage("onboarding.requestID") private var onboardingRequestID: Int = 0
    @AppStorage("gateway.onboardingComplete") private var onboardingComplete: Bool = false
    @AppStorage("gateway.hasConnectedOnce") private var hasConnectedOnce: Bool = false

    @State private var connectingGatewayID: String?
    @State private var localIPAddress: String?
    @State private var lastLocationModeRaw: String = OpenClawLocationMode.off.rawValue
    @State private var gatewayToken: String = ""
    @State private var gatewayPassword: String = ""
    @State private var talkElevenLabsApiKey: String = ""
    @AppStorage("gateway.setupCode") private var setupCode: String = ""
    @State private var setupStatusText: String?
    @State private var manualGatewayPortText: String = ""
    @State private var gatewayExpanded: Bool = false
    @State private var selectedAgentPickerId: String = ""

    @State private var showResetOnboardingAlert: Bool = false
    @State private var suppressCredentialPersist: Bool = false
    @State private var llmProvider: GatewayLocalLLMProviderKind = .disabled
    @State private var llmBaseURL: String = ""
    @State private var llmAPIKey: String = ""
    @State private var llmModel: String = ""
    @State private var llmToolCallingMode: GatewayLocalLLMToolCallingMode = .auto
    @State private var llmApplying: Bool = false

    @State private var savedProviders: [SavedLLMProvider] = []
    @State private var activeProviderID: String?
    @State private var editingProvider: SavedLLMProvider?

    @State private var showBackupConfirmAlert: Bool = false
    @State private var showRestoreImporter: Bool = false
    @State private var pendingRestoreFileURL: URL?
    @State private var showRestoreConfirmAlert: Bool = false
    @State private var backupOperationInFlight: Bool = false
    @State private var backupExportDocument = OpenClawBackupExportDocument(data: Data())
    @State private var backupExportFileName: String = "OpenClaw-Backup.ocbackup"
    @State private var showBackupExporter: Bool = false
    @State private var backupStatusMessage: String?
    @State private var showBackupStatusAlert: Bool = false

    private let gatewayLogger = Logger(subsystem: "ai.openclaw.ios", category: "GatewaySettings")

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent("Status") {
                        Text(self.localGatewayRuntime.state == .running ? "Running" : "Stopped")
                            .foregroundStyle(self.localGatewayRuntime.state == .running ? .green : .orange)
                    }
                    if let port = self.localGatewayRuntime.listenerPort {
                        LabeledContent("Port", value: "\(port)")
                    }
                    LabeledContent("Session", value: self.localGatewayRuntime.chatSessionKey)

                    Toggle("LAN Access (Debug)", isOn: Binding(
                        get: { self.localGatewayRuntime.lanAccessEnabled },
                        set: { newValue in
                            Task { await self.localGatewayRuntime.setLanAccessEnabled(newValue) }
                        }))
                    if self.localGatewayRuntime.lanAccessEnabled {
                        Text("Server is reachable from your local network. This reduces security — use only for debugging.")
                            .font(.footnote)
                            .foregroundStyle(.orange)
                    } else {
                        Text("Server only accepts connections from this device (localhost).")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    HStack(spacing: 8) {
                        Circle()
                            .fill(self.localGatewayRuntime.state == .running ? Color.green : Color.orange)
                            .frame(width: 10, height: 10)
                        Text("Local Server")
                    }
                }

                Section {
                    if self.savedProviders.isEmpty {
                        Text("No LLM providers configured.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(self.savedProviders) { provider in
                            self.providerRow(provider)
                        }
                        .onDelete { indexSet in
                            let deletedIDs = indexSet.map { self.savedProviders[$0].id }
                            self.savedProviders.remove(atOffsets: indexSet)
                            LLMProviderStore.save(self.savedProviders)
                            if let activeID = self.activeProviderID, deletedIDs.contains(activeID) {
                                self.activeProviderID = nil
                                LLMProviderStore.setActiveID(nil)
                                Task { await self.activateProvider(nil) }
                            }
                        }
                    }

                    Button {
                        self.editingProvider = SavedLLMProvider()
                    } label: {
                        Label("Add Provider", systemImage: "plus.circle.fill")
                    }

                    if self.llmApplying {
                        HStack(spacing: 8) {
                            ProgressView().progressViewStyle(.circular)
                            Text("Applying…")
                        }
                    }

                    Toggle(
                        "Show launch prompt when LLM is missing",
                        isOn: Binding(
                            get: { !self.llmSetupPromptSuppressed },
                            set: { self.llmSetupPromptSuppressed = !$0 }))

                    LabeledContent {
                        Picker("Tool Calls", selection: self.$llmToolCallingMode) {
                            ForEach(GatewayLocalLLMToolCallingMode.allCases, id: \.self) { mode in
                                Text(mode.displayLabel).tag(mode)
                            }
                        }
                        .labelsHidden()
                    } label: {
                        HStack(spacing: 4) {
                            Text("Tool Calls")
                            Text("(i)")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.secondary)
                        }
                    }
                    Text(self.llmToolCallingMode.helpText)
                        .font(.footnote)
                        .foregroundStyle(.secondary)

                    if let error = self.localGatewayRuntime.localLLMConfigErrorText {
                        Text(error)
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }

                    if let succeeded = self.localGatewayRuntime.lastLocalLLMProbeSucceeded {
                        HStack(spacing: 6) {
                            Image(systemName: succeeded ? "checkmark.circle.fill" : "xmark.circle.fill")
                                .foregroundStyle(succeeded ? .green : .red)
                            Text(succeeded ? "LLM test passed" : "LLM test failed")
                                .font(.footnote.weight(.medium))
                        }
                    }
                    if let errorText = self.localGatewayRuntime.lastLocalLLMProbeErrorText {
                        Text(Self.formatLLMError(errorText))
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                    if let responseText = self.localGatewayRuntime.lastLocalLLMProbeResponseText {
                        Text(responseText)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .lineLimit(4)
                    }
                } header: {
                    Text("LLM Providers")
                }

                Section {
                    DisclosureGroup(isExpanded: self.$gatewayExpanded) {
                        if !self.isGatewayConnected {
                            Text(
                                "1. Open Telegram and message your bot: /pair\n"
                                    + "2. Copy the setup code it returns\n"
                                    + "3. Paste here and tap Connect\n"
                                    + "4. Back in Telegram, run /pair approve")
                                .font(.footnote)
                                .foregroundStyle(.secondary)

                            if let warning = self.tailnetWarningText {
                                Text(warning)
                                    .font(.footnote.weight(.semibold))
                                    .foregroundStyle(.orange)
                            }

                            TextField("Paste setup code", text: self.$setupCode)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()

                            Button {
                                Task { await self.applySetupCodeAndConnect() }
                            } label: {
                                if self.connectingGatewayID == "manual" {
                                    HStack(spacing: 8) {
                                        ProgressView()
                                            .progressViewStyle(.circular)
                                        Text("Connecting…")
                                    }
                                } else {
                                    Text("Connect with setup code")
                                }
                            }
                            .disabled(self.connectingGatewayID != nil
                                || self.setupCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                            if let status = self.setupStatusLine {
                                Text(status)
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }
                        }

                        if self.isGatewayConnected {
                            Picker("Bot", selection: self.$selectedAgentPickerId) {
                                Text("Default").tag("")
                                let defaultId = (self.appModel.gatewayDefaultAgentId ?? "")
                                    .trimmingCharacters(in: .whitespacesAndNewlines)
                                ForEach(self.appModel.gatewayAgents.filter { $0.id != defaultId }, id: \.id) { agent in
                                    let name = (agent.name ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                                    Text(name.isEmpty ? agent.id : name).tag(agent.id)
                                }
                            }
                            Text("Controls which bot Chat and Talk speak to.")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }

                        if self.appModel.gatewayServerName == nil {
                            LabeledContent("Discovery", value: self.gatewayController.discoveryStatusText)
                        }
                        LabeledContent("Status", value: self.appModel.gatewayStatusText)
                        Toggle("Auto-connect on launch", isOn: self.$gatewayAutoConnect)

                        if let serverName = self.appModel.gatewayServerName {
                            LabeledContent("Server", value: serverName)
                            if let addr = self.appModel.gatewayRemoteAddress {
                                let parts = Self.parseHostPort(from: addr)
                                let urlString = Self.httpURLString(host: parts?.host, port: parts?.port, fallback: addr)
                                LabeledContent("Address") {
                                    Text(urlString)
                                }
                                .contextMenu {
                                    Button {
                                        UIPasteboard.general.string = urlString
                                    } label: {
                                        Label("Copy URL", systemImage: "doc.on.doc")
                                    }

                                    if let parts {
                                        Button {
                                            UIPasteboard.general.string = parts.host
                                        } label: {
                                            Label("Copy Host", systemImage: "doc.on.doc")
                                        }

                                        Button {
                                            UIPasteboard.general.string = "\(parts.port)"
                                        } label: {
                                            Label("Copy Port", systemImage: "doc.on.doc")
                                        }
                                    }
                                }
                            }

                            Button("Disconnect", role: .destructive) {
                                self.appModel.disconnectGateway()
                            }
                        } else {
                            self.gatewayList(showing: .all)
                        }

                        DisclosureGroup("Advanced") {
                            Toggle("Use Manual Gateway", isOn: self.$manualGatewayEnabled)

                            TextField("Host", text: self.$manualGatewayHost)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()

                            TextField("Port (optional)", text: self.manualPortBinding)
                                .keyboardType(.numberPad)

                            Toggle("Use TLS", isOn: self.$manualGatewayTLS)

                            Button {
                                Task { await self.connectManual() }
                            } label: {
                                if self.connectingGatewayID == "manual" {
                                    HStack(spacing: 8) {
                                        ProgressView()
                                            .progressViewStyle(.circular)
                                        Text("Connecting…")
                                    }
                                } else {
                                    Text("Connect (Manual)")
                                }
                            }
                            .disabled(self.connectingGatewayID != nil || self.manualGatewayHost
                                .trimmingCharacters(in: .whitespacesAndNewlines)
                                .isEmpty || !self.manualPortIsValid)

                            Text(
                                "Use this when mDNS/Bonjour discovery is blocked. "
                                    + "Leave port empty for 443 on tailnet DNS (TLS) or 18789 otherwise.")
                                .font(.footnote)
                                .foregroundStyle(.secondary)

                            Toggle("Discovery Debug Logs", isOn: self.$discoveryDebugLogsEnabled)
                                .onChange(of: self.discoveryDebugLogsEnabled) { _, newValue in
                                    self.gatewayController.setDiscoveryDebugLoggingEnabled(newValue)
                                }

                            NavigationLink("Discovery Logs") {
                                GatewayDiscoveryDebugLogView()
                            }

                            Toggle("Debug Canvas Status", isOn: self.$canvasDebugStatusEnabled)
                            self.tvOSGatewayCapabilityMatrixSection()

                            TextField("Gateway Auth Token", text: self.$gatewayToken)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()

                            SecureField("Gateway Password", text: self.$gatewayPassword)

                            Button("Reset Onboarding", role: .destructive) {
                                self.showResetOnboardingAlert = true
                            }

                            VStack(alignment: .leading, spacing: 6) {
                                Text("Debug")
                                    .font(.footnote.weight(.semibold))
                                    .foregroundStyle(.secondary)
                                Text(self.gatewayDebugText())
                                    .font(.system(size: 12, weight: .regular, design: .monospaced))
                                    .foregroundStyle(.secondary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(10)
                                    .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                            }
                        }
                    } label: {
                        HStack(spacing: 10) {
                            Circle()
                                .fill(self.isGatewayConnected ? Color.green : Color.secondary.opacity(0.35))
                                .frame(width: 10, height: 10)
                            Text("Remote Gateway")
                            Spacer()
                            Text(self.isGatewayConnected ? self.gatewaySummaryText : "Optional")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                Section {
                    Button {
                        self.showBackupConfirmAlert = true
                    } label: {
                        Label("Backup to Files…", systemImage: "square.and.arrow.up")
                    }
                    .disabled(self.backupOperationInFlight)

                    Button(role: .destructive) {
                        self.showRestoreImporter = true
                    } label: {
                        Label("Restore from Backup…", systemImage: "square.and.arrow.down")
                    }
                    .disabled(self.backupOperationInFlight)

                    Text("Backup includes chats, workspace files, settings, and saved credentials.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } header: {
                    Text("Backup / Restore")
                }

                Section("Device") {
                    DisclosureGroup("Features") {
                        // Voice Wake, Talk Mode, and ElevenLabs are hidden —
                        // they require a remote gateway and don't work with local server.
                        Toggle("Show Talk Button", isOn: self.$talkButtonEnabled)
                        Toggle("Show Tool Calls in Chat", isOn: self.$showsToolCallsInChat)
                        Text("Tool calls are collapsed by default. Disable to hide tool traces in Chat.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        Stepper(value: self.$chatAutoRetryAttemptsOnError, in: 0...5) {
                            LabeledContent("Auto-Retry on Chat Error", value: "\(self.chatAutoRetryAttemptsOnError)")
                        }
                        Text("When chat.send fails, Chat sends \"Continue\" up to this many times per user message.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)

                        Toggle("Allow Camera", isOn: self.$cameraEnabled)
                        Text("Allows the gateway to request photos or short video clips (foreground only).")
                            .font(.footnote)
                            .foregroundStyle(.secondary)

                        Picker("Location Access", selection: self.$locationEnabledModeRaw) {
                            Text("Off").tag(OpenClawLocationMode.off.rawValue)
                            Text("While Using").tag(OpenClawLocationMode.whileUsing.rawValue)
                            Text("Always").tag(OpenClawLocationMode.always.rawValue)
                        }
                        .pickerStyle(.segmented)

                        Toggle("Precise Location", isOn: self.$locationPreciseEnabled)
                            .disabled(self.locationMode == .off)

                        Text("Always requires system permission and may prompt to open Settings.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)

                        Toggle("Prevent Sleep", isOn: self.$preventSleep)
                        Text("Keeps the screen awake while OpenClaw is open.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }

                    DisclosureGroup("Device Info") {
                        TextField("Name", text: self.$displayName)
                        Text(self.instanceId)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        LabeledContent("IP", value: self.localIPAddress ?? "—")
                            .contextMenu {
                                if let ip = self.localIPAddress {
                                    Button {
                                        UIPasteboard.general.string = ip
                                    } label: {
                                        Label("Copy", systemImage: "doc.on.doc")
                                    }
                                }
                            }
                        LabeledContent("Platform", value: self.platformString())
                        LabeledContent("Version", value: self.appVersion())
                        LabeledContent("Model", value: self.modelIdentifier())
                    }
                }
            }
            .modifier(SettingsFormWidthModifier())
            .navigationTitle("Settings")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        self.dismiss()
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .accessibilityLabel("Close")
                }
            }
            .alert("Reset Onboarding?", isPresented: self.$showResetOnboardingAlert) {
                Button("Reset", role: .destructive) {
                    self.resetOnboarding()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text(
                    "This will disconnect, clear saved gateway connection + credentials, and reopen the onboarding wizard.")
            }
            .onAppear {
                self.localIPAddress = NetworkInterfaces.primaryIPv4Address()
                self.lastLocationModeRaw = self.locationEnabledModeRaw
                self.syncManualPortText()
                let trimmedInstanceId = self.instanceId.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmedInstanceId.isEmpty {
                    self.gatewayToken = GatewaySettingsStore.loadGatewayToken(instanceId: trimmedInstanceId) ?? ""
                    self.gatewayPassword = GatewaySettingsStore.loadGatewayPassword(instanceId: trimmedInstanceId) ?? ""
                }
                self.talkElevenLabsApiKey = GatewaySettingsStore.loadTalkElevenLabsApiKey() ?? ""
                // Local server is primary — collapse remote gateway by default.
                let localRunning = self.localGatewayRuntime.state == .running
                self.gatewayExpanded = !localRunning && !self.isGatewayConnected
                self.selectedAgentPickerId = self.appModel.selectedAgentId ?? ""
                self.loadLLMSettingsFromRuntime()
                let migrated = LLMProviderStore.migrateFromLegacyIfNeeded()
                self.savedProviders = migrated.providers
                self.activeProviderID = migrated.activeID
            }
            .onChange(of: self.selectedAgentPickerId) { _, newValue in
                let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
                self.appModel.setSelectedAgentId(trimmed.isEmpty ? nil : trimmed)
            }
            .onChange(of: self.llmProvider) { _, newValue in
                self.applyRecommendedLLMDefaultsIfNeeded(for: newValue)
            }
            .onChange(of: self.appModel.selectedAgentId ?? "") { _, newValue in
                if newValue != self.selectedAgentPickerId {
                    self.selectedAgentPickerId = newValue
                }
            }
            .onChange(of: self.preferredGatewayStableID) { _, newValue in
                let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { return }
                GatewaySettingsStore.savePreferredGatewayStableID(trimmed)
            }
            .onChange(of: self.gatewayToken) { _, newValue in
                guard !self.suppressCredentialPersist else { return }
                let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
                let instanceId = self.instanceId.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !instanceId.isEmpty else { return }
                GatewaySettingsStore.saveGatewayToken(trimmed, instanceId: instanceId)
            }
            .onChange(of: self.gatewayPassword) { _, newValue in
                guard !self.suppressCredentialPersist else { return }
                let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
                let instanceId = self.instanceId.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !instanceId.isEmpty else { return }
                GatewaySettingsStore.saveGatewayPassword(trimmed, instanceId: instanceId)
            }
            .onChange(of: self.talkElevenLabsApiKey) { _, newValue in
                GatewaySettingsStore.saveTalkElevenLabsApiKey(newValue)
            }
            .onChange(of: self.manualGatewayPort) { _, _ in
                self.syncManualPortText()
            }
            .onChange(of: self.appModel.gatewayServerName) { _, newValue in
                if newValue != nil {
                    self.setupCode = ""
                    self.setupStatusText = nil
                    return
                }
                if self.manualGatewayEnabled {
                    self.setupStatusText = self.appModel.gatewayStatusText
                }
            }
            .onChange(of: self.appModel.gatewayStatusText) { _, newValue in
                guard self.manualGatewayEnabled || self.connectingGatewayID == "manual" else { return }
                let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { return }
                self.setupStatusText = trimmed
            }
            .onChange(of: self.locationEnabledModeRaw) { _, newValue in
                let previous = self.lastLocationModeRaw
                self.lastLocationModeRaw = newValue
                guard let mode = OpenClawLocationMode(rawValue: newValue) else { return }
                Task {
                    let granted = await self.appModel.requestLocationPermissions(mode: mode)
                    if !granted {
                        await MainActor.run {
                            self.locationEnabledModeRaw = previous
                            self.lastLocationModeRaw = previous
                        }
                    }
                }
            }
        }
        .gatewayTrustPromptAlert()
        .sheet(item: self.$editingProvider) { editing in
            self.providerEditorSheet(for: editing)
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
                self.backupStatusMessage = "Saved to \(url.lastPathComponent)."
                self.showBackupStatusAlert = true
            case let .failure(error):
                self.backupStatusMessage = "Backup export failed: \(error.localizedDescription)"
                self.showBackupStatusAlert = true
            }
        }
        .alert("Backup", isPresented: self.$showBackupStatusAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(self.backupStatusMessage ?? "")
        }
    }

    @ViewBuilder
    private func gatewayList(showing: GatewayListMode) -> some View {
        if self.gatewayController.gateways.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                Text("No gateways found yet.")
                    .foregroundStyle(.secondary)
                Text("If your gateway is on another network, connect it and ensure DNS is working.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                if let lastKnown = GatewaySettingsStore.loadLastGatewayConnection(),
                   case let .manual(host, port, _, _) = lastKnown
                {
                    Button {
                        Task { await self.connectLastKnown() }
                    } label: {
                        self.lastKnownButtonLabel(host: host, port: port)
                    }
                    .disabled(self.connectingGatewayID != nil)
                    .buttonStyle(.borderedProminent)
                    .tint(self.appModel.seamColor)
                }
            }
        } else {
            let connectedID = self.appModel.connectedGatewayID
            let rows = self.gatewayController.gateways.filter { gateway in
                let isConnected = gateway.stableID == connectedID
                switch showing {
                case .all:
                    return true
                case .availableOnly:
                    return !isConnected
                }
            }

            if rows.isEmpty, showing == .availableOnly {
                Text("No other gateways found.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(rows) { gateway in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            // Avoid localized-string formatting edge cases from Bonjour-advertised names.
                            Text(verbatim: gateway.name)
                            let detailLines = self.gatewayDetailLines(gateway)
                            ForEach(detailLines, id: \.self) { line in
                                Text(verbatim: line)
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Spacer()

                        Button {
                            Task { await self.connect(gateway) }
                        } label: {
                            if self.connectingGatewayID == gateway.id {
                                ProgressView()
                                    .progressViewStyle(.circular)
                            } else {
                                Text("Connect")
                            }
                        }
                        .disabled(self.connectingGatewayID != nil)
                    }
                }
            }
        }
    }

    private enum GatewayListMode: Equatable {
        case all
        case availableOnly
    }

    private var isGatewayConnected: Bool {
        let status = self.appModel.gatewayStatusText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if status.contains("connected") { return true }
        return self.appModel.gatewayServerName != nil && !status.contains("offline")
    }

    // MARK: - Provider List

    @ViewBuilder
    private func providerRow(_ provider: SavedLLMProvider) -> some View {
        let isActive = self.activeProviderID == provider.id
        Button {
            Task { await self.activateProvider(provider) }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: isActive ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isActive ? .green : .secondary)
                    .font(.title3)

                VStack(alignment: .leading, spacing: 2) {
                    Text(provider.displayName)
                        .font(.body.weight(isActive ? .semibold : .regular))
                        .foregroundStyle(.primary)
                    Text(provider.provider.displayLabel + (provider.model.isEmpty ? "" : " · \(provider.model)"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button {
                    self.editingProvider = provider
                } label: {
                    Image(systemName: "pencil.circle")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .buttonStyle(.plain)
        .disabled(self.llmApplying)
    }

    @ViewBuilder
    private func providerEditorSheet(for editing: SavedLLMProvider) -> some View {
        LLMProviderEditorSheet(
            provider: editing,
            isNew: !self.savedProviders.contains(where: { $0.id == editing.id }))
        { saved, test in
            await self.handleProviderEditorSave(saved, test: test)
        }
    }

    @MainActor
    private func handleProviderEditorSave(_ saved: SavedLLMProvider, test: Bool) async {
        if let index = self.savedProviders.firstIndex(where: { $0.id == saved.id }) {
            self.savedProviders[index] = saved
        } else {
            self.savedProviders.append(saved)
        }
        LLMProviderStore.save(self.savedProviders)
        await self.activateProvider(saved)
        if test {
            let quickTestLogLine = "llm editor quick test start"
                + " provider=\(saved.provider.rawValue)"
                + " model=\(saved.model)"
            print("[OpenClaw iOS] \(quickTestLogLine)")
            self.gatewayLogger.info("\(quickTestLogLine, privacy: .public)")
            await self.localGatewayRuntime.probeLocalLLM(prompt: "Who are you?")
            let passed = self.localGatewayRuntime.lastLocalLLMProbeSucceeded == true
            let outcome = passed ? "passed" : "failed"
            print("[OpenClaw iOS] llm editor quick test \(outcome)")
            self.gatewayLogger.info("llm editor quick test \(outcome, privacy: .public)")
        }
    }

    private func activateProvider(_ provider: SavedLLMProvider?) async {
        self.llmApplying = true
        defer { self.llmApplying = false }

        if let provider {
            self.activeProviderID = provider.id
            LLMProviderStore.setActiveID(provider.id)

            self.llmProvider = provider.provider
            self.llmBaseURL = provider.baseURL
            self.llmAPIKey = provider.apiKey
            self.llmModel = provider.model
            self.llmToolCallingMode = provider.toolCallingMode

            var settings = self.localGatewayRuntime.controlPlaneSettings
            settings.localLLMProvider = provider.provider
            settings.localLLMBaseURL = provider.baseURL
            settings.localLLMAPIKey = provider.apiKey
            settings.localLLMModel = provider.model
            settings.localLLMToolCallingMode = provider.toolCallingMode
            await self.localGatewayRuntime.applyControlPlaneSettings(settings)
        } else {
            self.activeProviderID = nil
            LLMProviderStore.setActiveID(nil)

            self.llmProvider = .disabled
            self.llmBaseURL = ""
            self.llmAPIKey = ""
            self.llmModel = ""

            var settings = self.localGatewayRuntime.controlPlaneSettings
            settings.localLLMProvider = .disabled
            settings.localLLMBaseURL = ""
            settings.localLLMAPIKey = ""
            settings.localLLMModel = ""
            settings.localLLMToolCallingMode = self.llmToolCallingMode
            await self.localGatewayRuntime.applyControlPlaneSettings(settings)
        }
    }

    // MARK: - Local LLM Settings

    private var llmSettingsDirty: Bool {
        let settings = self.localGatewayRuntime.controlPlaneSettings
        return self.llmProvider != settings.localLLMProvider
            || self.llmBaseURL != settings.localLLMBaseURL
            || self.llmAPIKey != settings.localLLMAPIKey
            || self.llmModel != settings.localLLMModel
            || self.llmToolCallingMode != settings.localLLMToolCallingMode
    }

    private func loadLLMSettingsFromRuntime() {
        let settings = self.localGatewayRuntime.controlPlaneSettings
        self.llmProvider = settings.localLLMProvider
        self.llmBaseURL = settings.localLLMBaseURL
        self.llmAPIKey = settings.localLLMAPIKey
        self.llmModel = settings.localLLMModel
        self.llmToolCallingMode = settings.localLLMToolCallingMode
    }

    private func applyRecommendedLLMDefaultsIfNeeded(for provider: GatewayLocalLLMProviderKind) {
        guard provider != .disabled else { return }

        if self.llmBaseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           let recommendedBaseURL = TVOSLocalGatewayRuntime.defaultLocalLLMBaseURL(for: provider)
        {
            self.llmBaseURL = recommendedBaseURL
        }

        if self.llmModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           let recommendedModel = TVOSLocalGatewayRuntime.defaultLocalLLMModel(for: provider)
        {
            self.llmModel = recommendedModel
        }
    }

    private func applyLLMSettings(test: Bool) async {
        self.llmApplying = true
        var settings = self.localGatewayRuntime.controlPlaneSettings
        settings.localLLMProvider = self.llmProvider
        settings.localLLMBaseURL = self.llmBaseURL
        settings.localLLMAPIKey = self.llmAPIKey
        settings.localLLMModel = self.llmModel
        settings.localLLMToolCallingMode = self.llmToolCallingMode
        await self.localGatewayRuntime.applyControlPlaneSettings(settings)
        if test {
            await self.localGatewayRuntime.probeLocalLLM(prompt: "Who are you?")
        }
        self.llmApplying = false
    }

    private func testLocalLLM() async {
        self.llmApplying = true
        await self.localGatewayRuntime.probeLocalLLM(prompt: "Who are you?")
        self.llmApplying = false
    }

    private static func formatLLMError(_ raw: String) -> String {
        SettingsNetworkingHelpers.formatLLMError(raw)
    }

    private var gatewaySummaryText: String {
        if let server = self.appModel.gatewayServerName, self.isGatewayConnected {
            return server
        }
        let trimmed = self.appModel.gatewayStatusText.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Not connected" : trimmed
    }

    private func platformString() -> String {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return "iOS \(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
    }

    private var locationMode: OpenClawLocationMode {
        OpenClawLocationMode(rawValue: self.locationEnabledModeRaw) ?? .off
    }

    private func appVersion() -> String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
    }

    private func deviceFamily() -> String {
        switch UIDevice.current.userInterfaceIdiom {
        case .pad:
            "iPad"
        case .phone:
            "iPhone"
        default:
            "iOS"
        }
    }

    private func modelIdentifier() -> String {
        var systemInfo = utsname()
        uname(&systemInfo)
        let machine = withUnsafeBytes(of: &systemInfo.machine) { ptr in
            String(bytes: ptr.prefix { $0 != 0 }, encoding: .utf8)
        }
        let trimmed = machine?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? "unknown" : trimmed
    }

    private func connect(_ gateway: GatewayDiscoveryModel.DiscoveredGateway) async {
        self.connectingGatewayID = gateway.id
        self.manualGatewayEnabled = false
        self.preferredGatewayStableID = gateway.stableID
        GatewaySettingsStore.savePreferredGatewayStableID(gateway.stableID)
        self.lastDiscoveredGatewayStableID = gateway.stableID
        GatewaySettingsStore.saveLastDiscoveredGatewayStableID(gateway.stableID)
        defer { self.connectingGatewayID = nil }

        let err = await self.gatewayController.connectWithDiagnostics(gateway)
        if let err {
            self.setupStatusText = err
        }
    }

    private func connectLastKnown() async {
        self.connectingGatewayID = "last-known"
        defer { self.connectingGatewayID = nil }
        await self.gatewayController.connectLastKnown()
    }

    private func gatewayDebugText() -> String {
        var lines: [String] = [
            "gateway: \(self.appModel.gatewayStatusText)",
            "discovery: \(self.gatewayController.discoveryStatusText)",
        ]
        lines.append("server: \(self.appModel.gatewayServerName ?? "—")")
        lines.append("address: \(self.appModel.gatewayRemoteAddress ?? "—")")
        if let last = self.gatewayController.discoveryDebugLog.last?.message {
            lines.append("discovery log: \(last)")
        }
        #if os(tvOS)
        lines.append("gateway capability matrix (\(GatewayHostCapabilityMatrix.activeHostLabel)):")
        lines.append(contentsOf: GatewayHostCapabilityMatrix.summaryLines())
        #endif
        return lines.joined(separator: "\n")
    }

    @ViewBuilder
    private func tvOSGatewayCapabilityMatrixSection() -> some View {
        #if os(tvOS)
        DisclosureGroup("Gateway Runtime Capabilities (tvOS)") {
            ForEach(GatewayHostCapabilityMatrix.activeCapabilities) { capability in
                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(capability.title)
                        Spacer()
                        Text(capability.support.label)
                            .font(.system(size: 11, weight: .semibold, design: .monospaced))
                            .foregroundStyle(self.capabilitySupportColor(capability.support))
                    }
                    Text(capability.details)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 2)
            }

            Text("supported = local tvOS runtime, remote-only = delegated to remote gateway, unsupported = intentionally excluded from tvOS scope.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        #endif
    }

    private func capabilitySupportColor(_ support: GatewayHostCapabilitySupport) -> Color {
        switch support {
        case .supported:
            return .green
        case .remoteOnly:
            return .orange
        case .unsupported:
            return .red
        }
    }

    @ViewBuilder
    private func lastKnownButtonLabel(host: String, port: Int) -> some View {
        if self.connectingGatewayID == "last-known" {
            HStack(spacing: 8) {
                ProgressView()
                    .progressViewStyle(.circular)
                Text("Connecting…")
            }
            .frame(maxWidth: .infinity)
        } else {
            HStack(spacing: 8) {
                Image(systemName: "bolt.horizontal.circle.fill")
                VStack(alignment: .leading, spacing: 2) {
                    Text("Connect last known")
                    Text("\(host):\(port)")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .frame(maxWidth: .infinity)
        }
    }

    private var manualPortBinding: Binding<String> {
        Binding(
            get: { self.manualGatewayPortText },
            set: { newValue in
                let filtered = newValue.filter(\.isNumber)
                if self.manualGatewayPortText != filtered {
                    self.manualGatewayPortText = filtered
                }
                if filtered.isEmpty {
                    if self.manualGatewayPort != 0 {
                        self.manualGatewayPort = 0
                    }
                } else if let port = Int(filtered), self.manualGatewayPort != port {
                    self.manualGatewayPort = port
                }
            })
    }

    private var manualPortIsValid: Bool {
        if self.manualGatewayPortText.isEmpty { return true }
        return self.manualGatewayPort >= 1 && self.manualGatewayPort <= 65535
    }

    private func syncManualPortText() {
        if self.manualGatewayPort > 0 {
            let next = String(self.manualGatewayPort)
            if self.manualGatewayPortText != next {
                self.manualGatewayPortText = next
            }
        } else if !self.manualGatewayPortText.isEmpty {
            self.manualGatewayPortText = ""
        }
    }

    private func applySetupCodeAndConnect() async {
        self.setupStatusText = nil
        guard self.applySetupCode() else { return }
        let host = self.manualGatewayHost.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedPort = self.resolvedManualPort(host: host)
        let hasToken = !self.gatewayToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let hasPassword = !self.gatewayPassword.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        GatewayDiagnostics.log(
            "setup code applied host=\(host) port=\(resolvedPort ?? -1) tls=\(self.manualGatewayTLS) token=\(hasToken) password=\(hasPassword)")
        guard let port = resolvedPort else {
            self.setupStatusText = "Failed: invalid port"
            return
        }
        let ok = await self.preflightGateway(host: host, port: port, useTLS: self.manualGatewayTLS)
        guard ok else { return }
        self.setupStatusText = "Setup code applied. Connecting…"
        await self.connectManual()
    }

    @discardableResult
    private func applySetupCode() -> Bool {
        let raw = self.setupCode.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else {
            self.setupStatusText = "Paste a setup code to continue."
            return false
        }

        guard let payload = GatewaySetupCode.decode(raw: raw) else {
            self.setupStatusText = "Setup code not recognized."
            return false
        }

        if let urlString = payload.url, let url = URL(string: urlString) {
            self.applySetupURL(url)
        } else if let host = payload.host, !host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            self.manualGatewayHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
            if let port = payload.port {
                self.manualGatewayPort = port
                self.manualGatewayPortText = String(port)
            } else {
                self.manualGatewayPort = 0
                self.manualGatewayPortText = ""
            }
            if let tls = payload.tls {
                self.manualGatewayTLS = tls
            }
        } else if let url = URL(string: raw), url.scheme != nil {
            self.applySetupURL(url)
        } else {
            self.setupStatusText = "Setup code missing URL or host."
            return false
        }

        let trimmedInstanceId = self.instanceId.trimmingCharacters(in: .whitespacesAndNewlines)
        if let token = payload.token, !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let trimmedToken = token.trimmingCharacters(in: .whitespacesAndNewlines)
            self.gatewayToken = trimmedToken
            if !trimmedInstanceId.isEmpty {
                GatewaySettingsStore.saveGatewayToken(trimmedToken, instanceId: trimmedInstanceId)
            }
        }
        if let password = payload.password, !password.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let trimmedPassword = password.trimmingCharacters(in: .whitespacesAndNewlines)
            self.gatewayPassword = trimmedPassword
            if !trimmedInstanceId.isEmpty {
                GatewaySettingsStore.saveGatewayPassword(trimmedPassword, instanceId: trimmedInstanceId)
            }
        }

        return true
    }

    private func applySetupURL(_ url: URL) {
        guard let host = url.host, !host.isEmpty else { return }
        self.manualGatewayHost = host
        if let port = url.port {
            self.manualGatewayPort = port
            self.manualGatewayPortText = String(port)
        } else {
            self.manualGatewayPort = 0
            self.manualGatewayPortText = ""
        }
        let scheme = (url.scheme ?? "").lowercased()
        if scheme == "wss" || scheme == "https" {
            self.manualGatewayTLS = true
        } else if scheme == "ws" || scheme == "http" {
            self.manualGatewayTLS = false
        }
    }

    private func resolvedManualPort(host: String) -> Int? {
        if self.manualGatewayPort > 0 {
            return self.manualGatewayPort <= 65535 ? self.manualGatewayPort : nil
        }
        let trimmed = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if self.manualGatewayTLS && trimmed.lowercased().hasSuffix(".ts.net") {
            return 443
        }
        return 18789
    }

    private func preflightGateway(host: String, port: Int, useTLS: Bool) async -> Bool {
        let trimmed = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }

        if SettingsNetworkingHelpers.isTailnetHostOrIP(trimmed) && !SettingsNetworkingHelpers.hasTailnetIPv4() {
            let msg = "Tailscale is off on this iPhone. Turn it on, then try again."
            self.setupStatusText = msg
            GatewayDiagnostics.log("preflight fail: tailnet missing host=\(trimmed)")
            self.gatewayLogger.warning("\(msg, privacy: .public)")
            return false
        }

        self.setupStatusText = "Checking gateway reachability…"
        let ok = await Self.probeTCP(host: trimmed, port: port, timeoutSeconds: 3)
        if !ok {
            let msg = "Can't reach gateway at \(trimmed):\(port). Check Tailscale or LAN."
            self.setupStatusText = msg
            GatewayDiagnostics.log("preflight fail: unreachable host=\(trimmed) port=\(port)")
            self.gatewayLogger.warning("\(msg, privacy: .public)")
            return false
        }
        GatewayDiagnostics.log("preflight ok host=\(trimmed) port=\(port) tls=\(useTLS)")
        return true
    }

    private static func probeTCP(host: String, port: Int, timeoutSeconds: Double) async -> Bool {
        await TCPProbe.probe(
            host: host,
            port: port,
            timeoutSeconds: timeoutSeconds,
            queueLabel: "gateway.preflight")
    }

    // (GatewaySetupCode) decode raw setup codes.

    private func connectManual() async {
        let host = self.manualGatewayHost.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !host.isEmpty else {
            self.setupStatusText = "Failed: host required"
            return
        }
        guard self.manualPortIsValid else {
            self.setupStatusText = "Failed: invalid port"
            return
        }

        self.connectingGatewayID = "manual"
        self.manualGatewayEnabled = true
        defer { self.connectingGatewayID = nil }

        GatewayDiagnostics.log(
            "connect manual host=\(host) port=\(self.manualGatewayPort) tls=\(self.manualGatewayTLS)")
        await self.gatewayController.connectManual(
            host: host,
            port: self.manualGatewayPort,
            useTLS: self.manualGatewayTLS)
    }

    private var setupStatusLine: String? {
        let trimmedSetup = self.setupStatusText?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let gatewayStatus = self.appModel.gatewayStatusText.trimmingCharacters(in: .whitespacesAndNewlines)
        if let friendly = self.friendlyGatewayMessage(from: gatewayStatus) { return friendly }
        if let friendly = self.friendlyGatewayMessage(from: trimmedSetup) { return friendly }
        if !trimmedSetup.isEmpty { return trimmedSetup }
        if gatewayStatus.isEmpty || gatewayStatus == "Offline" { return nil }
        return gatewayStatus
    }

    private var tailnetWarningText: String? {
        let host = self.manualGatewayHost.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !host.isEmpty else { return nil }
        guard SettingsNetworkingHelpers.isTailnetHostOrIP(host) else { return nil }
        guard !SettingsNetworkingHelpers.hasTailnetIPv4() else { return nil }
        return "This gateway is on your tailnet. Turn on Tailscale on this iPhone, then tap Connect."
    }

    private func friendlyGatewayMessage(from raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let lower = trimmed.lowercased()
        if lower.contains("pairing required") {
            return "Pairing required. Go back to Telegram and run /pair approve, then tap Connect again."
        }
        if lower.contains("device nonce required") || lower.contains("device nonce mismatch") {
            return "Secure handshake failed. Make sure Tailscale is connected, then tap Connect again."
        }
        if lower.contains("device signature expired") || lower.contains("device signature invalid") {
            return "Secure handshake failed. Check that your iPhone time is correct, then tap Connect again."
        }
        if lower.contains("connect timed out") || lower.contains("timed out") {
            return "Connection timed out. Make sure Tailscale is connected, then try again."
        }
        if lower.contains("unauthorized role") {
            return "Connected, but some controls are restricted for nodes. This is expected."
        }
        return nil
    }

    private static func parseHostPort(from address: String) -> SettingsHostPort? {
        SettingsNetworkingHelpers.parseHostPort(from: address)
    }

    private static func httpURLString(host: String?, port: Int?, fallback: String) -> String {
        SettingsNetworkingHelpers.httpURLString(host: host, port: port, fallback: fallback)
    }

}

// MARK: - Backup / Restore

extension SettingsTab {
    func performBackupExport() async {
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
            }

            self.backupOperationInFlight = false
            self.backupExportDocument = OpenClawBackupExportDocument(data: artifact.data)
            self.backupExportFileName = artifact.defaultFileName
            self.showBackupExporter = true
        } catch {
            if wasRunning {
                await self.localGatewayRuntime.start()
            }
            self.backupOperationInFlight = false
            self.backupStatusMessage = "Backup failed: \(error.localizedDescription)"
            self.showBackupStatusAlert = true
        }
    }

    func handleRestoreSelection(_ result: Result<[URL], any Error>) {
        switch result {
        case let .success(urls):
            guard let url = urls.first else { return }
            self.pendingRestoreFileURL = url
            self.showRestoreConfirmAlert = true
        case let .failure(error):
            self.backupStatusMessage = "Could not open file: \(error.localizedDescription)"
            self.showBackupStatusAlert = true
        }
    }

    func performRestoreFromPendingFile() async {
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
                self.loadLLMSettingsFromRuntime()
                let migrated = LLMProviderStore.migrateFromLegacyIfNeeded()
                self.savedProviders = migrated.providers
                self.activeProviderID = migrated.activeID

                self.backupOperationInFlight = false
                self.backupStatusMessage =
                    "Restored \(restored.restoredFileCount) files, "
                    + "\(restored.restoredDefaultsCount) settings, "
                    + "\(restored.restoredKeychainCount) keychain entries."
                self.showBackupStatusAlert = true
            } catch {
                await self.localGatewayRuntime.reloadPersistedControlPlaneSettings(startIfStopped: wasRunning)
                self.backupOperationInFlight = false
                self.backupStatusMessage = "Restore failed: \(error.localizedDescription)"
                self.showBackupStatusAlert = true
            }
        } catch {
            self.backupOperationInFlight = false
            self.backupStatusMessage = "Restore failed: \(error.localizedDescription)"
            self.showBackupStatusAlert = true
        }
    }

    func resetOnboarding() {
        self.appModel.disconnectGateway()
        self.connectingGatewayID = nil
        self.setupStatusText = nil
        self.setupCode = ""
        self.gatewayAutoConnect = false

        self.suppressCredentialPersist = true
        defer { self.suppressCredentialPersist = false }

        self.gatewayToken = ""
        self.gatewayPassword = ""

        let trimmedInstanceId = self.instanceId.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedInstanceId.isEmpty {
            GatewaySettingsStore.deleteGatewayCredentials(instanceId: trimmedInstanceId)
        }

        GatewaySettingsStore.clearLastGatewayConnection()

        self.onboardingComplete = false
        self.hasConnectedOnce = false

        self.manualGatewayEnabled = false
        self.manualGatewayHost = ""

        self.onboardingRequestID += 1

        self.dismiss()
    }

    func gatewayDetailLines(_ gateway: GatewayDiscoveryModel.DiscoveredGateway) -> [String] {
        var lines: [String] = []
        if let lanHost = gateway.lanHost { lines.append("LAN: \(lanHost)") }
        if let tailnet = gateway.tailnetDns { lines.append("Tailnet: \(tailnet)") }

        let gatewayPort = gateway.gatewayPort
        let canvasPort = gateway.canvasPort
        if gatewayPort != nil || canvasPort != nil {
            let gw = gatewayPort.map(String.init) ?? "—"
            let canvas = canvasPort.map(String.init) ?? "—"
            lines.append("Ports: gateway \(gw) · canvas \(canvas)")
        }

        if lines.isEmpty {
            lines.append(gateway.debugID)
        }

        return lines
    }
}

private extension GatewayLocalLLMToolCallingMode {
    static let allCases: [GatewayLocalLLMToolCallingMode] = [.auto, .on, .off]

    var displayLabel: String {
        switch self {
        case .auto:
            return "Auto"
        case .on:
            return "On"
        case .off:
            return "Off"
        }
    }

    var helpText: String {
        switch self {
        case .auto:
            return "Auto uses tool-aware API, then falls back to plain chat if the provider rejects tools."
        case .on:
            return "On forces tool-aware API. Chat fails if the model endpoint does not support tool calls."
        case .off:
            return "Off disables tool-aware API and uses plain chat completions only."
        }
    }
}

private struct SettingsFormWidthModifier: ViewModifier {
    @ViewBuilder
    func body(content: Content) -> some View {
        #if os(iOS)
        if ProcessInfo.processInfo.isiOSAppOnMac {
            content
                .formStyle(.grouped)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        } else {
            content
        }
        #else
        content
        #endif
    }
}
