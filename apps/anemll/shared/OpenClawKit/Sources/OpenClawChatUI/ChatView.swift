import SwiftUI

@MainActor
public struct OpenClawChatView: View {
    public enum Style {
        case standard
        case onboarding
    }

    @State private var viewModel: OpenClawChatViewModel
    @State private var showSessions = false
    @State private var hasPerformedInitialScroll = false
    @State private var isPinnedToBottom = true
    @State private var lastUserMessageID: UUID?
    @State private var scrollProxy: ScrollViewProxy?
    private let bottomAnchorID = "chatView.bottomAnchor"
    private let showsSessionSwitcher: Bool
    private let showsToolCalls: Bool
    private let assistantName: String?
    private let style: Style
    private let markdownVariant: ChatMarkdownVariant
    private let userAccent: Color?
    private let showsComposer: Bool
    private let autoloadOnAppear: Bool
    private let syncedMessageAnchor: Binding<UUID?>?
    private let textScale: CGFloat
    private let dictation: (any ChatDictationProvider)?

    private enum Layout {
        #if os(macOS)
        static let outerPaddingHorizontal: CGFloat = 6
        static let outerPaddingVertical: CGFloat = 0
        static let composerPaddingHorizontal: CGFloat = 0
        static let stackSpacing: CGFloat = 0
        static let messageSpacing: CGFloat = 6
        static let messageListPaddingTop: CGFloat = 12
        static let messageListPaddingBottom: CGFloat = 16
        static let messageListPaddingHorizontal: CGFloat = 6
        #else
        static let outerPaddingHorizontal: CGFloat = 6
        static let outerPaddingVertical: CGFloat = 6
        static let composerPaddingHorizontal: CGFloat = 6
        static let stackSpacing: CGFloat = 6
        static let messageSpacing: CGFloat = 12
        static let messageListPaddingTop: CGFloat = 10
        static let messageListPaddingBottom: CGFloat = 6
        static let messageListPaddingHorizontal: CGFloat = 8
        #endif
    }

    public init(
        viewModel: OpenClawChatViewModel,
        showsSessionSwitcher: Bool = false,
        showsToolCalls: Bool = true,
        assistantName: String? = nil,
        style: Style = .standard,
        markdownVariant: ChatMarkdownVariant = .standard,
        userAccent: Color? = nil,
        showsComposer: Bool = true,
        autoloadOnAppear: Bool = true,
        syncedMessageAnchor: Binding<UUID?>? = nil,
        textScale: CGFloat = 1.0,
        dictation: (any ChatDictationProvider)? = nil)
    {
        self._viewModel = State(initialValue: viewModel)
        self.showsSessionSwitcher = showsSessionSwitcher
        self.showsToolCalls = showsToolCalls
        self.assistantName = assistantName
        self.style = style
        self.markdownVariant = markdownVariant
        self.userAccent = userAccent
        self.showsComposer = showsComposer
        self.autoloadOnAppear = autoloadOnAppear
        self.syncedMessageAnchor = syncedMessageAnchor
        self.textScale = max(0.7, min(1.8, textScale))
        self.dictation = dictation
    }

    public var body: some View {
        ZStack {
            if self.style == .standard {
                OpenClawChatTheme.background
                    .ignoresSafeArea()
            }

            VStack(spacing: Layout.stackSpacing) {
                self.messageList
                    .padding(.horizontal, Layout.outerPaddingHorizontal)
                if self.showsComposer {
                    OpenClawChatComposer(
                        viewModel: self.viewModel,
                        style: self.style,
                        showsSessionSwitcher: self.showsSessionSwitcher,
                        dictation: self.dictation,
                        showSessionsSheet: self.$showSessions)
                        .padding(.horizontal, Layout.composerPaddingHorizontal)
                }
            }
            .padding(.vertical, Layout.outerPaddingVertical)
            .frame(maxWidth: .infinity)
            .frame(maxHeight: .infinity, alignment: .top)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .environment(\.openClawChatTextScale, self.textScale)
        .onAppear {
            guard self.autoloadOnAppear else { return }
            self.viewModel.load()
        }
        .sheet(isPresented: self.$showSessions) {
            if self.showsSessionSwitcher {
                ChatSessionsSheet(viewModel: self.viewModel)
            } else {
                EmptyView()
            }
        }
    }

    private var messageList: some View {
        ZStack {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: Layout.messageSpacing) {
                        self.messageListRows

                        Spacer()
                            .frame(height: Layout.messageListPaddingBottom)
                            .id(self.bottomAnchorID)
                    }
                    .padding(.top, Layout.messageListPaddingTop)
                    .padding(.horizontal, Layout.messageListPaddingHorizontal)
                }
                .onAppear { self.scrollProxy = proxy }
            }

            if self.viewModel.isLoading {
                ProgressView()
                    .controlSize(.large)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            self.messageListOverlay
        }
        // Ensure the message list claims vertical space on the first layout pass.
        .frame(maxHeight: .infinity, alignment: .top)
        .layoutPriority(1)
        .onChange(of: self.viewModel.isLoading) { _, isLoading in
            guard !isLoading else { return }
            self.hasPerformedInitialScroll = true
            self.isPinnedToBottom = true
            self.scrollToBottom(animated: false)
        }
        .onChange(of: self.viewModel.sessionKey) { _, _ in
            self.isPinnedToBottom = true
            self.lastUserMessageID = nil
            self.hasPerformedInitialScroll = true
            self.scrollToBottom(animated: false)
        }
        .onChange(of: self.viewModel.isSending) { _, isSending in
            guard isSending, self.hasPerformedInitialScroll else { return }
            self.isPinnedToBottom = true
            self.scrollToBottom(animated: true)
        }
        .onChange(of: self.viewModel.messages.count) { _, _ in
            guard self.hasPerformedInitialScroll else { return }
            if let lastMessage = self.viewModel.messages.last,
               lastMessage.role.lowercased() == "user",
               lastMessage.id != self.lastUserMessageID
            {
                self.lastUserMessageID = lastMessage.id
                self.isPinnedToBottom = true
                self.scrollToBottom(animated: true)
                return
            }

            guard self.isPinnedToBottom else { return }
            self.scrollToBottom(animated: false)
        }
        .onChange(of: self.viewModel.pendingRunCount) { _, _ in
            guard self.hasPerformedInitialScroll else { return }
            guard self.isPinnedToBottom else { return }
            self.scrollToBottom(animated: false)
        }
        .onChange(of: self.viewModel.streamingAssistantText) { _, _ in
            guard self.hasPerformedInitialScroll else { return }
            guard self.isPinnedToBottom else { return }
            self.scrollToBottom(animated: false)
        }
        // Keyboard show/hide is handled by SwiftUI's built-in safe area adjustment.
        // Manual scrollToBottom on keyboard events fights the framework and overshoots.
    }

    @ViewBuilder
    private var messageListRows: some View {
        ForEach(self.visibleMessages) { msg in
            ChatMessageBubble(
                message: msg,
                showsToolCalls: self.showsToolCalls,
                style: self.style,
                markdownVariant: self.markdownVariant,
                userAccent: self.userAccent)
                .frame(
                    maxWidth: .infinity,
                    alignment: msg.role.lowercased() == "user" ? .trailing : .leading)
        }

        if self.viewModel.pendingRunCount > 0 || self.viewModel.isSending {
            HStack {
                ChatTypingIndicatorBubble(
                    style: self.style,
                    assistantName: self.assistantName ?? self.viewModel.appName)
                    .equatable()
                Spacer(minLength: 0)
            }
        }

        if self.showsToolCalls, !self.viewModel.pendingToolCalls.isEmpty {
            ChatPendingToolsBubble(toolCalls: self.viewModel.pendingToolCalls)
                .equatable()
                .frame(maxWidth: .infinity, alignment: .leading)
        }

        if let text = self.viewModel.streamingAssistantText, AssistantTextParser.hasVisibleContent(in: text) {
            ChatStreamingAssistantBubble(text: text, markdownVariant: self.markdownVariant)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var visibleMessages: [OpenClawChatMessage] {
        let base: [OpenClawChatMessage]
        if self.style == .onboarding {
            guard let first = self.viewModel.messages.first else { return [] }
            base = first.role.lowercased() == "user" ? Array(self.viewModel.messages.dropFirst()) : self.viewModel
                .messages
        } else {
            base = self.viewModel.messages
        }
        let merged = self.mergeToolResults(in: base)
        guard !self.showsToolCalls else { return merged }
        return merged.filter { !self.isToolTraceOnlyMessage($0) }
    }

    /// Single source of truth for scrolling to the bottom of the conversation.
    /// Uses only ScrollViewReader.scrollTo — no .scrollPosition binding.
    private func scrollToBottom(animated: Bool) {
        guard let proxy = self.scrollProxy else { return }
        if let syncedMessageAnchor {
            syncedMessageAnchor.wrappedValue = nil
        }

        if animated {
            withAnimation(.easeOut(duration: 0.18)) {
                proxy.scrollTo(self.bottomAnchorID, anchor: .bottom)
            }
        } else {
            proxy.scrollTo(self.bottomAnchorID, anchor: .bottom)
        }
    }

    @ViewBuilder
    private var messageListOverlay: some View {
        if self.viewModel.isLoading {
            EmptyView()
        } else if let error = self.activeErrorText {
            let presentation = self.errorPresentation(for: error)
            if self.hasVisibleMessageListContent {
                VStack(spacing: 0) {
                    ChatNoticeBanner(
                        systemImage: presentation.systemImage,
                        title: presentation.title,
                        message: error,
                        tint: presentation.tint,
                        dismiss: { self.viewModel.errorText = nil },
                        refresh: { self.viewModel.refresh() })
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 10)
                .padding(.top, 8)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            } else {
                ChatNoticeCard(
                    systemImage: presentation.systemImage,
                    title: presentation.title,
                    message: error,
                    tint: presentation.tint,
                    actionTitle: "Refresh",
                    action: { self.viewModel.refresh() })
                    .padding(.horizontal, 24)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        } else if self.showsEmptyState {
            ChatNoticeCard(
                systemImage: "bubble.left.and.bubble.right.fill",
                title: self.emptyStateTitle,
                message: self.emptyStateMessage,
                tint: .accentColor,
                actionTitle: nil,
                action: nil)
                .padding(.horizontal, 24)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var activeErrorText: String? {
        guard let text = self.viewModel.errorText?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !text.isEmpty
        else {
            return nil
        }
        return text
    }

    private var hasVisibleMessageListContent: Bool {
        if !self.visibleMessages.isEmpty {
            return true
        }
        if let text = self.viewModel.streamingAssistantText,
           AssistantTextParser.hasVisibleContent(in: text)
        {
            return true
        }
        if self.viewModel.pendingRunCount > 0 {
            return true
        }
        if self.showsToolCalls, !self.viewModel.pendingToolCalls.isEmpty {
            return true
        }
        return false
    }

    private var showsEmptyState: Bool {
        self.viewModel.messages.isEmpty &&
            !(self.viewModel.streamingAssistantText.map { AssistantTextParser.hasVisibleContent(in: $0) } ?? false) &&
            self.viewModel.pendingRunCount == 0 &&
            (!self.showsToolCalls || self.viewModel.pendingToolCalls.isEmpty)
    }

    private var emptyStateTitle: String {
        #if os(macOS)
        "Web Chat"
        #else
        "Chat"
        #endif
    }

    private var emptyStateMessage: String {
        #if os(macOS)
        "Type a message below to start.\nReturn sends • Shift-Return adds a line break."
        #else
        "Type a message below to start."
        #endif
    }

    private func errorPresentation(for error: String) -> (title: String, systemImage: String, tint: Color) {
        let lower = error.lowercased()
        if lower.contains("not connected") || lower.contains("socket") {
            return ("Disconnected", "wifi.slash", .orange)
        }
        if lower.contains("timed out") {
            return ("Timed out", "clock.badge.exclamationmark", .orange)
        }
        return ("Error", "exclamationmark.triangle.fill", .orange)
    }

    private func mergeToolResults(in messages: [OpenClawChatMessage]) -> [OpenClawChatMessage] {
        var result: [OpenClawChatMessage] = []
        result.reserveCapacity(messages.count)

        for message in messages {
            guard self.isToolResultMessage(message) else {
                result.append(message)
                continue
            }

            guard let toolCallId = message.toolCallId,
                  let last = result.last,
                  self.toolCallIds(in: last).contains(toolCallId)
            else {
                result.append(message)
                continue
            }

            let toolText = self.toolResultText(from: message)
            if toolText.isEmpty {
                continue
            }

            var content = last.content
            content.append(
                OpenClawChatMessageContent(
                    type: "tool_result",
                    text: toolText,
                    thinking: nil,
                    thinkingSignature: nil,
                    mimeType: nil,
                    fileName: nil,
                    content: nil,
                    id: toolCallId,
                    name: message.toolName,
                    arguments: nil))

            let merged = OpenClawChatMessage(
                id: last.id,
                role: last.role,
                content: content,
                timestamp: last.timestamp,
                toolCallId: last.toolCallId,
                toolName: last.toolName,
                usage: last.usage,
                stopReason: last.stopReason)
            result[result.count - 1] = merged
        }

        return result
    }

    private func isToolResultMessage(_ message: OpenClawChatMessage) -> Bool {
        let role = message.role.lowercased()
        return role == "toolresult" || role == "tool_result"
    }

    private func toolCallIds(in message: OpenClawChatMessage) -> Set<String> {
        var ids = Set<String>()
        for content in message.content {
            let kind = (content.type ?? "").lowercased()
            let isTool =
                ["toolcall", "tool_call", "tooluse", "tool_use"].contains(kind) ||
                (content.name != nil && content.arguments != nil)
            if isTool, let id = content.id {
                ids.insert(id)
            }
        }
        if let toolCallId = message.toolCallId {
            ids.insert(toolCallId)
        }
        return ids
    }

    private func toolResultText(from message: OpenClawChatMessage) -> String {
        let parts = message.content.compactMap { content -> String? in
            let kind = (content.type ?? "text").lowercased()
            guard kind == "text" || kind.isEmpty else { return nil }
            return content.text
        }
        return parts.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func isToolTraceOnlyMessage(_ message: OpenClawChatMessage) -> Bool {
        let role = message.role.lowercased()
        if role == "tool" || role == "toolresult" || role == "tool_result" {
            // Keep credential prompt messages visible so the "Set up API key" button
            // always shows, even when "Show Tool Calls" is off.
            if Self.isCredentialPromptMessage(message) {
                return false
            }
            return true
        }

        let textSegments = message.content.compactMap { content -> String? in
            let kind = (content.type ?? "text").lowercased()
            guard kind == "text" || kind.isEmpty else { return nil }
            guard let text = content.text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else {
                return nil
            }
            return text
        }

        if role != "user",
           !textSegments.isEmpty,
           textSegments.allSatisfy({ self.isLegacyToolTraceText($0) })
        {
            return true
        }

        let hasVisibleText = !textSegments.isEmpty
        if hasVisibleText {
            return false
        }

        let hasAttachment = message.content.contains { content in
            let kind = (content.type ?? "").lowercased()
            return kind == "file" || kind == "attachment"
        }
        if hasAttachment {
            return false
        }

        return message.content.contains { content in
            let kind = (content.type ?? "").lowercased()
            if ["toolcall", "tool_call", "tooluse", "tool_use", "toolresult", "tool_result"].contains(kind) {
                return true
            }
            return content.name != nil && content.arguments != nil
        }
    }

    private func isLegacyToolTraceText(_ text: String) -> Bool {
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return normalized.hasPrefix("tool.call ") || normalized.hasPrefix("tool.result ")
    }

    /// Returns true when the message is a credentials.get tool result with hasKey: false.
    /// These messages must remain visible so the credential prompt button always renders.
    private static func isCredentialPromptMessage(_ message: OpenClawChatMessage) -> Bool {
        let text = message.content.compactMap { content -> String? in
            let kind = (content.type ?? "text").lowercased()
            guard kind == "text" || kind.isEmpty else { return nil }
            return content.text
        }.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return false }

        // Legacy format: "tool.result credentials.get {..."hasKey":false...}"
        let prefix = "tool.result "
        guard text.lowercased().hasPrefix(prefix) else { return false }
        let payload = String(text.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
        guard let spaceIdx = payload.firstIndex(where: \.isWhitespace) else { return false }
        let name = String(payload[..<spaceIdx]).lowercased()
        guard name == "credentials.get" else { return false }
        let jsonText = String(payload[spaceIdx...]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = jsonText.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              json["hasKey"] as? Bool == false,
              let service = json["service"] as? String,
              !service.isEmpty
        else { return false }
        return true
    }
}

private struct ChatNoticeCard: View {
    let systemImage: String
    let title: String
    let message: String
    let tint: Color
    let actionTitle: String?
    let action: (() -> Void)?

    var body: some View {
        VStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(self.tint.opacity(0.16))
                Image(systemName: self.systemImage)
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(self.tint)
            }
            .frame(width: 52, height: 52)

            Text(self.title)
                .font(.headline)

            Text(self.message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .lineLimit(4)
                .frame(maxWidth: 360)

            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
            }
        }
        .padding(18)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(OpenClawChatTheme.subtleCard)
                .overlay(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.12), lineWidth: 1)))
        .shadow(color: .black.opacity(0.14), radius: 18, y: 8)
    }
}

private struct ChatNoticeBanner: View {
    let systemImage: String
    let title: String
    let message: String
    let tint: Color
    let dismiss: () -> Void
    let refresh: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: self.systemImage)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(self.tint)
                .padding(.top, 1)

            VStack(alignment: .leading, spacing: 3) {
                Text(self.title)
                    .font(.caption.weight(.semibold))

                Text(self.message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            Spacer(minLength: 0)

            Button(action: self.refresh) {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .help("Refresh")

            Button(action: self.dismiss) {
                Image(systemName: "xmark")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Dismiss")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(OpenClawChatTheme.subtleCard)
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.12), lineWidth: 1)))
    }
}
