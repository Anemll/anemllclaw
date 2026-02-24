import OpenClawChatUI
import OpenClawKit
import SwiftUI
import os

struct ChatSheet: View {
    private static let logger = Logger(subsystem: "ai.openclaw", category: "ios.chat.sheet")
    @Environment(\.dismiss) private var dismiss
    @State private var viewModel: OpenClawChatViewModel
    private let userAccent: Color?
    private let agentName: String?

    init(gateway: GatewayNodeSession, sessionKey: String, agentName: String? = nil, userAccent: Color? = nil) {
        let transport = Self.resolveTransport(gateway: gateway)
        self._viewModel = State(
            initialValue: OpenClawChatViewModel(
                sessionKey: sessionKey,
                transport: transport))
        self.userAccent = userAccent
        self.agentName = agentName
    }

    var body: some View {
        NavigationStack {
            OpenClawChatView(
                viewModel: self.viewModel,
                showsSessionSwitcher: true,
                userAccent: self.userAccent)
                .navigationTitle(self.chatTitle)
                .navigationBarTitleDisplayMode(.inline)
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
        }
    }

    private var chatTitle: String {
        let trimmed = (self.agentName ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return "Chat" }
        return "Chat (\(trimmed))"
    }

    private static func resolveTransport(gateway: GatewayNodeSession) -> any OpenClawChatTransport {
        let defaults = UserDefaults.standard
        ChatTransportPreferences.migrateLegacyModeIfNeeded(defaults: defaults)
        let openAIWebSocketEnabled = ChatTransportPreferences.isOpenAIWebSocketEnabled(defaults: defaults)

        guard openAIWebSocketEnabled else {
            return IOSGatewayChatTransport(gateway: gateway)
        }

        let modelRaw = defaults.string(forKey: ChatTransportPreferences.openAIModelDefaultsKey) ?? ""
        let model = modelRaw.trimmingCharacters(in: .whitespacesAndNewlines)
        let apiKey = GatewaySettingsStore.loadChatOpenAIApiKey() ?? ""
        if apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            Self.logger.warning("openai websocket toggle enabled but api key missing")
        }
        return OpenAIWebSocketChatTransport(
            apiKey: apiKey,
            model: model.isEmpty ? ChatTransportPreferences.defaultOpenAIModel : model)
    }
}
