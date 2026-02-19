import OpenClawChatUI
import OpenClawKit
import SwiftUI

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
    @AppStorage("chat.toolCalls.visible") private var showsToolCallsInChat: Bool = true
    @AppStorage("chat.autoRetryAttemptsOnError") private var autoRetryAttemptsOnError: Int = 1
    @State private var viewModel: OpenClawChatViewModel
    @State private var showsTranscriptViewer = false
    @State private var transcriptMessageAnchor: UUID?
    private let userAccent: Color?
    private let agentName: String?

    init(gateway: GatewayNodeSession, sessionKey: String, agentName: String? = nil, userAccent: Color? = nil) {
        let transport = IOSGatewayChatTransport(gateway: gateway)
        let resolvedSessionKey = LastThreadStore.resolve(initial: sessionKey)
        self._viewModel = State(
            initialValue: OpenClawChatViewModel(
                sessionKey: resolvedSessionKey,
                transport: transport))
        self.userAccent = userAccent
        self.agentName = agentName
    }

    init(transport: any OpenClawChatTransport, sessionKey: String, agentName: String? = nil, userAccent: Color? = nil) {
        let resolvedSessionKey = LastThreadStore.resolve(initial: sessionKey)
        self._viewModel = State(
            initialValue: OpenClawChatViewModel(
                sessionKey: resolvedSessionKey,
                transport: transport))
        self.userAccent = userAccent
        self.agentName = agentName
    }

    var body: some View {
        NavigationStack {
            OpenClawChatView(
                viewModel: self.viewModel,
                showsSessionSwitcher: true,
                showsToolCalls: self.showsToolCallsInChat,
                assistantName: self.agentName,
                userAccent: self.userAccent,
                syncedMessageAnchor: self.$transcriptMessageAnchor)
                .toolbar(.hidden, for: .navigationBar)
                .safeAreaInset(edge: .top, spacing: 0) {
                    self.compactTopBar
                }
                .onAppear {
                    self.viewModel.autoRetryAttemptsOnError = max(0, self.autoRetryAttemptsOnError)
                    LastThreadStore.save(self.viewModel.sessionKey)
                }
                .onChange(of: self.autoRetryAttemptsOnError) { _, newValue in
                    self.viewModel.autoRetryAttemptsOnError = max(0, newValue)
                }
                .onChange(of: self.viewModel.sessionKey) { _, newValue in
                    LastThreadStore.save(newValue)
                }
                .fullScreenCover(isPresented: self.$showsTranscriptViewer) {
                    ChatTranscriptViewerSheet(
                        viewModel: self.viewModel,
                        showsToolCalls: self.showsToolCallsInChat,
                        agentName: self.agentName,
                        userAccent: self.userAccent,
                        messageAnchor: self.$transcriptMessageAnchor)
                }
        }
    }

    private var compactTopBar: some View {
        HStack(spacing: 12) {
            Button {
                self.showsTranscriptViewer = true
            } label: {
                Image(systemName: "eye")
            }
            .accessibilityLabel("Open full chat view")

            Spacer(minLength: 0)

            Button {
                self.dismiss()
            } label: {
                Image(systemName: "xmark")
            }
            .accessibilityLabel("Close")
        }
        .font(.system(size: 15, weight: .semibold))
        .padding(.horizontal, 12)
        .frame(height: 34)
        .background(.ultraThinMaterial)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color.white.opacity(0.08))
                .frame(height: 1)
        }
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

    var id: String { self.rawValue }

    var title: String {
        switch self {
        case .extraSmall:
            return "Extra Small"
        case .small:
            return "Small"
        case .default:
            return "Default"
        case .large:
            return "Large"
        case .extraLarge:
            return "Extra Large"
        }
    }

    var dynamicTypeSize: DynamicTypeSize {
        switch self {
        case .extraSmall:
            return .xSmall
        case .small:
            return .small
        case .default:
            return .large
        case .large:
            return .xLarge
        case .extraLarge:
            return .xxLarge
        }
    }

    var textScale: CGFloat {
        switch self {
        case .extraSmall:
            return 0.82
        case .small:
            return 0.92
        case .default:
            return 1.0
        case .large:
            return 1.14
        case .extraLarge:
            return 1.30
        }
    }
}
