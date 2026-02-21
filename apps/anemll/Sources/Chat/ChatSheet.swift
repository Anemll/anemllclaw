import OpenClawChatUI
import OpenClawGatewayCore
import OpenClawKit
import SwiftUI

extension Notification.Name {
    static let openclawOpenSettings = Notification.Name("openclawOpenSettings")
}

struct ChatSheet: View {
    private enum LastThreadStore {
        static let defaultsKey = "chat.lastSessionKey"

        static func resolve(initial requestedSessionKey: String) -> String {
            let fallback = Self.normalized(requestedSessionKey) ?? "main"
            guard
                let saved = UserDefaults.standard.string(forKey: Self.defaultsKey),
                let normalizedSaved = Self.normalized(saved)
            else {
                return fallback
            }
            return normalizedSaved
        }

        static func save(_ sessionKey: String) {
            guard let normalized = Self.normalized(sessionKey) else { return }
            UserDefaults.standard.set(normalized, forKey: Self.defaultsKey)
        }

        private static func normalized(_ raw: String) -> String? {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
    }

    @Environment(\.dismiss) private var dismiss
    @Environment(NodeAppModel.self) private var appModel: NodeAppModel
    @Environment(VoiceWakeManager.self) private var voiceWake: VoiceWakeManager
    @Environment(GatewayConnectionController.self) private var gatewayController: GatewayConnectionController
    @Environment(TVOSLocalGatewayRuntime.self) private var localGatewayRuntime: TVOSLocalGatewayRuntime
    @AppStorage("chat.toolCalls.visible") private var showsToolCallsInChat: Bool = false
    @AppStorage("chat.autoRetryAttemptsOnError") private var autoRetryAttemptsOnError: Int = 1
    @AppStorage(OpenClawChatTextScaleLevel.defaultsKey)
    private var mainChatZoomLevelRaw: String = OpenClawChatTextScaleLevel.defaultLevel.rawValue
    @State private var viewModel: OpenClawChatViewModel
    @State private var showsTranscriptViewer = false
    @State private var showsSettings = false
    @State private var settingsAutoAddProvider = false
    @State private var transcriptMessageAnchor: UUID?
    @State private var savedProviders: [SavedLLMProvider] = []
    @State private var activeProviderID: String?
    @State private var modelSwitching = false
    private let userAccent: Color?
    private let agentName: String?
    private let allowDismiss: Bool

    init(
        gateway: GatewayNodeSession,
        sessionKey: String,
        agentName: String? = nil,
        userAccent: Color? = nil,
        allowDismiss: Bool = true)
    {
        let transport = IOSGatewayChatTransport(gateway: gateway)
        let resolvedSessionKey = LastThreadStore.resolve(initial: sessionKey)
        let vm = OpenClawChatViewModel(
            sessionKey: resolvedSessionKey,
            transport: transport)
        vm.appName = "AnemllClaw"
        self._viewModel = State(initialValue: vm)
        self.userAccent = userAccent
        self.agentName = agentName
        self.allowDismiss = allowDismiss
    }

    init(
        transport: any OpenClawChatTransport,
        sessionKey: String,
        agentName: String? = nil,
        userAccent: Color? = nil,
        allowDismiss: Bool = true)
    {
        let resolvedSessionKey = LastThreadStore.resolve(initial: sessionKey)
        let vm = OpenClawChatViewModel(
            sessionKey: resolvedSessionKey,
            transport: transport)
        vm.appName = "AnemllClaw"
        self._viewModel = State(initialValue: vm)
        self.userAccent = userAccent
        self.agentName = agentName
        self.allowDismiss = allowDismiss
    }

    var body: some View {
        NavigationStack {
            Group {
                if self.usesMacTopBarLayout {
                    self.chatContent
                        .ignoresSafeArea(.container, edges: .top)
                        .overlay(alignment: .top) {
                            self.compactTopBar
                        }
                } else {
                    self.chatContent
                        .safeAreaInset(edge: .top, spacing: 0) {
                            self.compactTopBar
                        }
                }
            }
            .navigationTitle(self.agentName ?? "Chat")
            .onAppear {
                self.viewModel.autoRetryAttemptsOnError = max(0, self.autoRetryAttemptsOnError)
                LastThreadStore.save(self.viewModel.sessionKey)
                self.savedProviders = LLMProviderStore.load()
                self.activeProviderID = LLMProviderStore.activeID()
            }
            .onChange(of: self.autoRetryAttemptsOnError) { _, newValue in
                self.viewModel.autoRetryAttemptsOnError = max(0, newValue)
            }
            .onChange(of: self.viewModel.sessionKey) { _, newValue in
                LastThreadStore.save(newValue)
            }
            .onReceive(NotificationCenter.default.publisher(for: .openclawOpenSettings)) { note in
                self.settingsAutoAddProvider = (note.userInfo?["addProvider"] as? Bool) == true
                self.showsSettings = true
            }
            .fullScreenCover(isPresented: self.$showsTranscriptViewer) {
                ChatTranscriptViewerSheet(
                    viewModel: self.viewModel,
                    showsToolCalls: self.showsToolCallsInChat,
                    agentName: self.agentName,
                    userAccent: self.userAccent,
                    messageAnchor: self.$transcriptMessageAnchor)
            }
            .sheet(isPresented: self.$showsSettings, onDismiss: {
                self.savedProviders = LLMProviderStore.load()
                self.activeProviderID = LLMProviderStore.activeID()
                self.settingsAutoAddProvider = false
            }) {
                SettingsTab(autoAddProvider: self.settingsAutoAddProvider)
                    .environment(self.appModel)
                    .environment(self.voiceWake)
                    .environment(self.gatewayController)
                    .environment(self.localGatewayRuntime)
            }
        }
    }

    private var chatContent: some View {
        OpenClawChatView(
            viewModel: self.viewModel,
            showsSessionSwitcher: true,
            showsToolCalls: self.showsToolCallsInChat,
            assistantName: self.agentName,
            userAccent: self.userAccent,
            syncedMessageAnchor: self.$transcriptMessageAnchor,
            textScale: self.mainChatZoomLevel.textScale)
            .toolbar(.hidden, for: .navigationBar)
    }

    private var usesMacTopBarLayout: Bool {
        ProcessInfo.processInfo.isiOSAppOnMac
    }

    private var usesEnlargedControls: Bool {
        #if os(visionOS)
        return true
        #else
        if ProcessInfo.processInfo.isiOSAppOnMac { return true }
        return UIDevice.current.userInterfaceIdiom == .pad
        #endif
    }

    private var compactTopBar: some View {
        HStack(spacing: 12) {
            Button {
                self.showsTranscriptViewer = true
            } label: {
                Image(systemName: "eye")
            }
            .accessibilityLabel("Open full chat view")

            self.mainZoomMenu

            if self.configuredProviders.count >= 2 {
                self.modelPickerMenu
            }

            Spacer(minLength: 0)

            Button {
                self.showsSettings = true
            } label: {
                Image(systemName: "gearshape")
            }
            .accessibilityLabel("Settings")

            if self.allowDismiss {
                Button {
                    self.dismiss()
                } label: {
                    Image(systemName: "xmark")
                }
                .accessibilityLabel("Close")
            }
        }
        .font(.system(size: self.compactTopBarFontSize, weight: .semibold))
        .padding(.horizontal, 12)
        .frame(height: self.compactTopBarHeight)
        .background(.ultraThinMaterial)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color.white.opacity(0.08))
                .frame(height: 1)
        }
    }

    private var compactTopBarHeight: CGFloat {
        if self.usesEnlargedControls {
            return self.usesMacTopBarLayout ? 52 : 68
        }
        return 34
    }

    private var compactTopBarFontSize: CGFloat {
        if self.usesEnlargedControls {
            return self.usesMacTopBarLayout ? 26 : 30
        }
        return 15
    }

    private var mainZoomMenu: some View {
        Menu {
            ForEach(OpenClawChatTextScaleLevel.allCases) { level in
                Button {
                    self.mainChatZoomLevelRaw = level.rawValue
                } label: {
                    if level == self.mainChatZoomLevel {
                        Label(level.title, systemImage: "checkmark")
                    } else {
                        Text(level.title)
                    }
                }
            }
        } label: {
            Image(systemName: "textformat.size")
        }
        .accessibilityLabel("Adjust chat text size")
    }

    private var mainChatZoomLevel: OpenClawChatTextScaleLevel {
        OpenClawChatTextScaleLevel(rawValue: self.mainChatZoomLevelRaw) ?? .defaultLevel
    }

    private var configuredProviders: [SavedLLMProvider] {
        self.savedProviders.filter(\.isConfigured)
    }

    private var activeProvider: SavedLLMProvider? {
        guard let id = self.activeProviderID else { return nil }
        return self.savedProviders.first(where: { $0.id == id })
    }

    private var modelPickerMenu: some View {
        Menu {
            ForEach(self.configuredProviders) { provider in
                Button {
                    Task { await self.activateProvider(provider) }
                } label: {
                    if provider.id == self.activeProviderID {
                        Label(provider.shortDisplayName, systemImage: "checkmark")
                    } else {
                        Text(provider.shortDisplayName)
                    }
                }
                .disabled(provider.id == self.activeProviderID || self.modelSwitching)
            }
        } label: {
            Text(self.activeProvider?.shortDisplayName ?? "Model")
                .font(.system(size: self.compactTopBarFontSize - 2, weight: .medium))
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(.ultraThinMaterial, in: Capsule())
        }
        .accessibilityLabel("Switch model")
    }

    private func activateProvider(_ provider: SavedLLMProvider) async {
        guard provider.id != self.activeProviderID else { return }
        self.modelSwitching = true
        defer { self.modelSwitching = false }

        self.activeProviderID = provider.id
        LLMProviderStore.setActiveID(provider.id)

        var settings = self.localGatewayRuntime.controlPlaneSettings
        settings.localLLMProvider = provider.provider
        settings.localLLMBaseURL = provider.baseURL
        settings.localLLMAPIKey = provider.apiKey
        settings.localLLMModel = provider.model
        await self.localGatewayRuntime.applyControlPlaneSettings(settings)
    }
}

private struct ChatTranscriptViewerSheet: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage("chat.transcript.zoomLevel")
    private var transcriptZoomLevelRaw = TranscriptZoomLevel.defaultLevel.rawValue
    let viewModel: OpenClawChatViewModel
    let showsToolCalls: Bool
    let agentName: String?
    let userAccent: Color?
    @Binding var messageAnchor: UUID?

    var body: some View {
        GeometryReader { geometry in
            let isLandscape = geometry.size.width > geometry.size.height
            if isLandscape {
                self.transcriptContent
                    .overlay(alignment: .topLeading) {
                        self.landscapeCloseOverlay
                    }
                    .overlay(alignment: .topTrailing) {
                        self.landscapeZoomOverlay
                    }
            } else {
                NavigationStack {
                    self.transcriptContent
                        .navigationTitle(self.title)
                        .navigationBarTitleDisplayMode(.inline)
                        .toolbar {
                            ToolbarItem(placement: .topBarLeading) {
                                Button {
                                    self.dismiss()
                                } label: {
                                    Image(systemName: "xmark")
                                }
                                .accessibilityLabel("Close full chat view")
                            }
                            ToolbarItem(placement: .topBarTrailing) {
                                self.zoomMenu
                            }
                        }
                }
            }
        }
    }

    private var transcriptContent: some View {
        OpenClawChatView(
            viewModel: self.viewModel,
            showsSessionSwitcher: false,
            showsToolCalls: self.showsToolCalls,
            assistantName: self.agentName,
            style: .standard,
            userAccent: self.userAccent,
            showsComposer: false,
            autoloadOnAppear: false,
            syncedMessageAnchor: self.$messageAnchor,
            textScale: self.transcriptZoomLevel.textScale)
            .dynamicTypeSize(self.transcriptZoomLevel.dynamicTypeSize)
    }

    private var transcriptZoomLevel: TranscriptZoomLevel {
        TranscriptZoomLevel(rawValue: self.transcriptZoomLevelRaw) ?? .defaultLevel
    }

    private var title: String {
        let trimmed = (self.agentName ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return "Chat" }
        return trimmed
    }

    private var landscapeCloseOverlay: some View {
        Button {
            self.dismiss()
        } label: {
            Image(systemName: "xmark")
                .font(.headline)
                .padding(10)
                .background(.ultraThinMaterial, in: Circle())
        }
        .padding(.top, 10)
        .padding(.leading, 10)
        .accessibilityLabel("Close full chat view")
    }

    private var landscapeZoomOverlay: some View {
        self.zoomMenu
            .padding(.top, 10)
            .padding(.trailing, 10)
    }

    private var zoomMenu: some View {
        Menu {
            ForEach(TranscriptZoomLevel.allCases) { level in
                Button {
                    self.transcriptZoomLevelRaw = level.rawValue
                } label: {
                    if level == self.transcriptZoomLevel {
                        Label(level.title, systemImage: "checkmark")
                    } else {
                        Text(level.title)
                    }
                }
            }
        } label: {
            Image(systemName: "textformat.size")
                .font(.headline)
                .padding(10)
                .background(.ultraThinMaterial, in: Circle())
        }
        .accessibilityLabel("Adjust transcript zoom")
    }
}

private enum TranscriptZoomLevel: String, CaseIterable, Identifiable {
    case extraSmall
    case small
    case `default`
    case large
    case extraLarge

    static let defaultLevel: TranscriptZoomLevel = .default

    var id: String {
        self.rawValue
    }

    var title: String {
        switch self {
        case .extraSmall:
            "Extra Small"
        case .small:
            "Small"
        case .default:
            "Default"
        case .large:
            "Large"
        case .extraLarge:
            "Extra Large"
        }
    }

    var dynamicTypeSize: DynamicTypeSize {
        switch self {
        case .extraSmall:
            .xSmall
        case .small:
            .small
        case .default:
            .large
        case .large:
            .xLarge
        case .extraLarge:
            .xxLarge
        }
    }

    var textScale: CGFloat {
        switch self {
        case .extraSmall:
            0.74
        case .small:
            0.88
        case .default:
            1.0
        case .large:
            1.22
        case .extraLarge:
            1.42
        }
    }
}
