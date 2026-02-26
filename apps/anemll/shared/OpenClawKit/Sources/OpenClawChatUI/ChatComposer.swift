import Foundation
import Observation
import SwiftUI

#if os(iOS)
import PhotosUI
import UIKit
import UniformTypeIdentifiers
#endif

@MainActor
struct OpenClawChatComposer: View {
    @Bindable var viewModel: OpenClawChatViewModel
    let style: OpenClawChatView.Style
    let showsSessionSwitcher: Bool
    var dictation: (any ChatDictationProvider)?
    @Binding var showSessionsSheet: Bool
    @State private var isDictating = false
    @State private var showCreateConversation = false
    @State private var showClearConfirmation = false
    @State private var newConversationName: String = ""
    #if os(macOS)
    @AppStorage(OpenClawChatTextScaleLevel.defaultsKey)
    private var chatTextScaleLevelRaw: String = OpenClawChatTextScaleLevel.defaultLevel.rawValue
    #endif

    #if os(iOS)
    @State private var pickerItems: [PhotosPickerItem] = []
    @State private var isKeyboardVisible = false
    @FocusState private var isFocused: Bool
    #elseif os(tvOS)
    @FocusState private var isFocused: Bool
    #else
    @State private var shouldFocusTextView = false
    #endif

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if self.showsToolbar {
                HStack(spacing: 6) {
                    if self.showsSessionSwitcher {
                        self.sessionPicker
                    }
                    self.thinkingPicker
                    #if os(iOS)
                    if self.dictation != nil {
                        self.dictationButton
                    }
                    #endif
                    #if os(macOS)
                    self.textScaleMenu
                    #endif
                    Spacer()
                    self.refreshButton
                    #if os(iOS)
                    if self.isKeyboardVisible {
                        self.keyboardDismissButton
                    }
                    #endif
                    self.attachmentPicker
                }
            }

            if self.showsAttachments, !self.viewModel.attachments.isEmpty {
                self.attachmentsStrip
            }

            self.editor
        }
        .padding(self.composerPadding)
        .background {
            let cornerRadius: CGFloat = 18

            #if os(macOS)
            if self.style == .standard {
                let shape = UnevenRoundedRectangle(
                    cornerRadii: RectangleCornerRadii(
                        topLeading: 0,
                        bottomLeading: cornerRadius,
                        bottomTrailing: cornerRadius,
                        topTrailing: 0),
                    style: .continuous)
                shape
                    .fill(OpenClawChatTheme.composerBackground)
                    .overlay(shape.strokeBorder(OpenClawChatTheme.composerBorder, lineWidth: 1))
                    .shadow(color: .black.opacity(0.12), radius: 12, y: 6)
            } else {
                let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                shape
                    .fill(OpenClawChatTheme.composerBackground)
                    .overlay(shape.strokeBorder(OpenClawChatTheme.composerBorder, lineWidth: 1))
                    .shadow(color: .black.opacity(0.12), radius: 12, y: 6)
            }
            #else
            let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            shape
                .fill(OpenClawChatTheme.composerBackground)
                .overlay(shape.strokeBorder(OpenClawChatTheme.composerBorder, lineWidth: 1))
                .shadow(color: .black.opacity(0.12), radius: 12, y: 6)
            #endif
        }
        #if os(macOS)
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            self.handleDrop(providers)
        }
        .onAppear {
            self.shouldFocusTextView = true
        }
        #endif
        .alert("New Conversation", isPresented: self.$showCreateConversation) {
                TextField("Name", text: self.$newConversationName)
                #if os(iOS) || os(tvOS)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                #endif
                Button("Cancel", role: .cancel) {
                    self.newConversationName = ""
                }
                Button("Create") {
                    self.createConversationFromInput()
                }
                .disabled(self.trimmedNewConversationName.isEmpty)
            } message: {
                Text("Enter a name for this conversation.")
            }
            .alert("Clear Conversation?", isPresented: self.$showClearConfirmation) {
                Button("Clear", role: .destructive) {
                    Task { try? await self.viewModel.clearCurrentSession() }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This will permanently delete all messages in this conversation.")
            }
        #if os(iOS)
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in
                self.isKeyboardVisible = true
                // Keyboard and microphone are mutually exclusive.
                if self.isDictating {
                    self.dictation?.stopDictation()
                    self.isDictating = false
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
                self.isKeyboardVisible = false
            }
            .onDisappear {
                self.isKeyboardVisible = false
            }
        #endif
    }

    private var thinkingPicker: some View {
        Picker("Thinking", selection: self.$viewModel.thinkingLevel) {
            Text("Off").tag("off")
            Text("Low").tag("low")
            Text("Medium").tag("medium")
            Text("High").tag("high")
            Text("X-High").tag("xhigh")
        }
        .labelsHidden()
        .pickerStyle(.menu)
        .controlSize(.small)
        .fixedSize()
    }

    private var sessionPicker: some View {
        Menu {
            ForEach(self.viewModel.sessionChoices, id: \.key) { session in
                Button {
                    self.viewModel.switchSession(to: session.key)
                } label: {
                    if session.key == self.viewModel.sessionKey {
                        Label {
                            Text(session.displayName ?? session.key)
                                .font(.system(.caption, design: .monospaced))
                                .lineLimit(1)
                        } icon: {
                            Image(systemName: "checkmark")
                        }
                    } else {
                        Text(session.displayName ?? session.key)
                            .font(.system(.caption, design: .monospaced))
                            .lineLimit(1)
                    }
                }
            }
            Divider()
            Button {
                self.newConversationName = ""
                self.showCreateConversation = true
            } label: {
                Label("New Conversation", systemImage: "square.and.pencil")
            }
            Button(role: .destructive) {
                self.showClearConfirmation = true
            } label: {
                Label("Clear Conversation", systemImage: "trash")
            }
            Button {
                self.showSessionsSheet = true
            } label: {
                Label("Manage Conversations…", systemImage: "list.bullet")
            }
        } label: {
            HStack(spacing: 4) {
                Text(self.activeSessionLabel)
                    .font(.system(.caption, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .allowsTightening(true)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .frame(maxWidth: self.sessionPickerMaxWidth, alignment: .leading)
        .help("Conversation")
    }

    @ViewBuilder
    private var attachmentPicker: some View {
        #if os(macOS)
        Button {
            self.pickFilesMac()
        } label: {
            Image(systemName: "paperclip")
        }
        .help("Add Image")
        .buttonStyle(.bordered)
        .controlSize(.small)
        #elseif os(iOS)
        PhotosPicker(selection: self.$pickerItems, maxSelectionCount: 8, matching: .images) {
            Image(systemName: "paperclip")
        }
        .help("Add Image")
        .buttonStyle(.bordered)
        .controlSize(.small)
        .onChange(of: self.pickerItems) { _, newItems in
            Task { await self.loadPhotosPickerItems(newItems) }
        }
        #else
        Button {
            // tvOS does not support the iOS PhotosPicker flow in this chat composer.
        } label: {
            Image(systemName: "paperclip")
        }
        .help("Image picker is unavailable on tvOS")
        .buttonStyle(.bordered)
        .controlSize(.small)
        .disabled(true)
        #endif
    }

    private var attachmentsStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(
                    self.viewModel.attachments,
                    id: \OpenClawPendingAttachment.id)
                { (att: OpenClawPendingAttachment) in
                    HStack(spacing: 6) {
                        if let img = att.preview {
                            OpenClawPlatformImageFactory.image(img)
                                .resizable()
                                .scaledToFill()
                                .frame(width: 22, height: 22)
                                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                        } else {
                            Image(systemName: "photo")
                        }

                        Text(att.fileName)
                            .lineLimit(1)

                        Button {
                            self.viewModel.removeAttachment(att.id)
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(Color.accentColor.opacity(0.08))
                    .clipShape(Capsule())
                }
            }
        }
    }

    private var editor: some View {
        VStack(alignment: .leading, spacing: 8) {
            self.editorOverlay

            Rectangle()
                .fill(OpenClawChatTheme.divider)
                .frame(height: 1)
                .padding(.horizontal, 2)

            HStack(alignment: .center, spacing: 8) {
                if self.showsConnectionPill {
                    self.connectionPill
                }
                Spacer(minLength: 0)
                self.sendButton
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(OpenClawChatTheme.composerField)
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(OpenClawChatTheme.composerBorder)))
        .padding(self.editorPadding)
    }

    private var connectionPill: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(self.viewModel.healthOK ? .green : .orange)
                .frame(width: 7, height: 7)
            if let transportIconName = self.connectionTransportIconName {
                Image(systemName: transportIconName)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(self.connectionTransportIconColor)
            }
            Text(self.activeSessionLabel)
                .font(.caption2.weight(.semibold))
            Text(self.viewModel.healthOK ? "Connected" : "Connecting…")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(OpenClawChatTheme.subtleCard)
        .clipShape(Capsule())
        .accessibilityLabel(self.connectionPillAccessibilityLabel)
    }

    private var activeSessionLabel: String {
        let match = self.viewModel.sessions.first { $0.key == self.viewModel.sessionKey }
        let trimmed = match?.displayName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? self.viewModel.sessionKey : trimmed
    }

    private var connectionTransportIconName: String? {
        guard self.viewModel.healthOK else { return nil }
        guard let transport = self.viewModel.activeSessionTransportLabel else { return nil }
        switch transport {
        case "WebSocket":
            return "dot.radiowaves.left.and.right"
        case "HTTPS":
            return "lock.shield.fill"
        default:
            return "network"
        }
    }

    private var connectionTransportIconColor: Color {
        guard let transport = self.viewModel.activeSessionTransportLabel else { return .secondary }
        switch transport {
        case "WebSocket":
            return .cyan
        case "HTTPS":
            return .blue
        default:
            return .secondary
        }
    }

    private var connectionPillAccessibilityLabel: String {
        if self.viewModel.healthOK,
           let transport = self.viewModel.activeSessionTransportLabel
        {
            return "\(self.activeSessionLabel), Connected, \(transport)"
        }
        return "\(self.activeSessionLabel), \(self.viewModel.healthOK ? "Connected" : "Connecting")"
    }

    private var sessionPickerMaxWidth: CGFloat {
        self.activeSessionLabel.count > 22 ? 148 : 160
    }

    private var editorOverlay: some View {
        ZStack(alignment: .topLeading) {
            if self.viewModel.input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text("Message \(self.viewModel.appName)…")
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 4)
            }

            #if os(macOS)
            ChatComposerTextView(text: self.$viewModel.input, shouldFocus: self.$shouldFocusTextView) {
                self.viewModel.send()
            }
            .frame(minHeight: self.textMinHeight, idealHeight: self.textMinHeight, maxHeight: self.textMaxHeight)
            .padding(.horizontal, 4)
            .padding(.vertical, 3)
            #elseif os(iOS)
            TextEditor(text: self.$viewModel.input)
                .font(.system(size: 15))
                .scrollContentBackground(.hidden)
                .frame(
                    minHeight: self.textMinHeight,
                    idealHeight: self.textMinHeight,
                    maxHeight: self.textMaxHeight)
                .padding(.horizontal, 4)
                .padding(.vertical, 4)
                .focused(self.$isFocused)
                .onChange(of: self.viewModel.input) {
                    // During dictation the text is set programmatically so
                    // TextEditor doesn't auto-scroll.  Find the underlying
                    // UITextView and scroll to the end.
                    guard self.isDictating else { return }
                    Self.scrollTextEditorToEnd()
                }
            #else
            TextField("", text: self.$viewModel.input)
                .font(.system(size: 15))
                .textFieldStyle(.plain)
                .padding(.horizontal, 4)
                .padding(.vertical, 6)
                .focused(self.$isFocused)
            #endif
        }
    }

    private var sendButton: some View {
        Group {
            if self.viewModel.pendingRunCount > 0 {
                Button {
                    self.viewModel.abort()
                } label: {
                    if self.viewModel.isAborting {
                        ProgressView().controlSize(.mini)
                    } else {
                        Image(systemName: "stop.fill")
                            .font(.system(size: self.sendButtonSymbolSize, weight: .semibold))
                    }
                }
                .buttonStyle(.plain)
                .foregroundStyle(.white)
                .frame(width: self.sendButtonVisualSize, height: self.sendButtonVisualSize)
                .background(Circle().fill(Color.red))
                .frame(minWidth: self.sendButtonHitTarget, minHeight: self.sendButtonHitTarget)
                .contentShape(Rectangle())
                .disabled(self.viewModel.isAborting)
            } else {
                Button {
                    self.sendFromComposer()
                } label: {
                    if self.viewModel.isSending {
                        ProgressView().controlSize(.mini)
                    } else {
                        Image(systemName: "arrow.up")
                            .font(.system(size: self.sendButtonSymbolSize, weight: .semibold))
                    }
                }
                .buttonStyle(.plain)
                .foregroundStyle(.white)
                .frame(width: self.sendButtonVisualSize, height: self.sendButtonVisualSize)
                .background(Circle().fill(Color.accentColor))
                .frame(minWidth: self.sendButtonHitTarget, minHeight: self.sendButtonHitTarget)
                .contentShape(Rectangle())
                .disabled(!self.viewModel.canSend)
            }
        }
    }

    private var sendButtonVisualSize: CGFloat {
        #if os(macOS)
        64
        #elseif os(visionOS)
        52
        #else
        self.usesEnlargedControls ? 52 : 26
        #endif
    }

    private var sendButtonHitTarget: CGFloat {
        #if os(macOS)
        84
        #elseif os(visionOS)
        64
        #else
        self.usesEnlargedControls ? 64 : self.sendButtonVisualSize
        #endif
    }

    private var sendButtonSymbolSize: CGFloat {
        #if os(macOS)
        30
        #elseif os(visionOS)
        26
        #else
        self.usesEnlargedControls ? 26 : 13
        #endif
    }

    private var usesEnlargedControls: Bool {
        #if os(macOS) || os(visionOS)
        return true
        #elseif os(iOS)
        if ProcessInfo.processInfo.isiOSAppOnMac { return true }
        return UIDevice.current.userInterfaceIdiom == .pad
        #else
        return false
        #endif
    }

    private var refreshButton: some View {
        Button {
            self.viewModel.sendContinue()
        } label: {
            Image(systemName: "arrow.clockwise")
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .disabled(self.viewModel.isSending)
        .help("Continue")
    }

    #if os(macOS)
    private var textScaleLevel: OpenClawChatTextScaleLevel {
        OpenClawChatTextScaleLevel(rawValue: self.chatTextScaleLevelRaw) ?? .defaultLevel
    }

    private var textScaleMenu: some View {
        Menu {
            ForEach(OpenClawChatTextScaleLevel.allCases) { level in
                Button {
                    self.chatTextScaleLevelRaw = level.rawValue
                } label: {
                    if level == self.textScaleLevel {
                        Label(level.title, systemImage: "checkmark")
                    } else {
                        Text(level.title)
                    }
                }
            }
        } label: {
            Image(systemName: "textformat.size")
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .help("Chat text size")
    }
    #endif

    #if os(iOS)
    private var keyboardDismissButton: some View {
        Button {
            self.dismissKeyboardFromComposer()
        } label: {
            Image(systemName: "keyboard.chevron.compact.down")
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .help("Dismiss Keyboard")
    }

    private var dictationButton: some View {
        Button {
            if self.isDictating {
                self.dictation?.stopDictation()
                self.isDictating = false
            } else {
                // Dismiss keyboard before starting dictation — they share
                // the audio input and shouldn't be active simultaneously.
                self.dismissKeyboardFromComposer()
                self.isDictating = true
                Task {
                    await self.dictation?.startDictation { [weak viewModel] transcript in
                        viewModel?.input = transcript
                    }
                    // If dictation ended on its own (final result / error),
                    // sync the toggle back.
                    if self.dictation?.isListening == false {
                        self.isDictating = false
                    }
                }
            }
        } label: {
            Image(systemName: self.isDictating ? "mic.fill" : "mic")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(self.isDictating ? .white : .secondary)
                .symbolEffect(.pulse, isActive: self.isDictating)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .tint(self.isDictating ? .red : nil)
        .animation(.none, value: self.isDictating)
        .help(self.isDictating ? "Stop Dictation" : "Dictate")
    }
    #endif

    private var showsToolbar: Bool {
        self.style == .standard
    }

    private var showsAttachments: Bool {
        self.style == .standard
    }

    private var showsConnectionPill: Bool {
        self.style == .standard
    }

    private var composerPadding: CGFloat {
        self.style == .onboarding ? 5 : 6
    }

    private var editorPadding: CGFloat {
        self.style == .onboarding ? 5 : 6
    }

    private var textMinHeight: CGFloat {
        self.style == .onboarding ? 24 : 28
    }

    private var textMaxHeight: CGFloat {
        self.style == .onboarding ? 52 : 64
    }

    private var trimmedNewConversationName: String {
        self.newConversationName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func createConversationFromInput() {
        let name = self.trimmedNewConversationName
        guard !name.isEmpty else { return }
        self.showCreateConversation = false
        self.newConversationName = ""
        self.viewModel.switchSession(to: name)
    }

    private func sendFromComposer() {
        #if os(iOS)
        // Stop dictation before sending so the onTranscript callback
        // doesn't re-populate the input after send() clears it.
        if self.isDictating {
            self.dictation?.stopDictation()
            self.isDictating = false
        }
        self.dismissKeyboardFromComposer()
        #endif
        self.viewModel.send()
    }

    #if os(iOS)
    private func dismissKeyboardFromComposer() {
        self.isFocused = false
        self.isKeyboardVisible = false
        UIApplication.shared.sendAction(
            #selector(UIResponder.resignFirstResponder),
            to: nil,
            from: nil,
            for: nil)
    }

    /// Walk the key window's view hierarchy to find any UITextView and
    /// scroll it to the very end.  Used during dictation where text is set
    /// programmatically and TextEditor doesn't auto-scroll.
    private static func scrollTextEditorToEnd() {
        guard let scene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene }).first,
            let window = scene.windows.first(where: \.isKeyWindow)
        else { return }

        func findTextView(in view: UIView) -> UITextView? {
            if let tv = view as? UITextView { return tv }
            for sub in view.subviews {
                if let found = findTextView(in: sub) { return found }
            }
            return nil
        }

        guard let textView = findTextView(in: window) else { return }
        let end = NSRange(location: textView.text.count, length: 0)
        textView.scrollRangeToVisible(end)
    }
    #endif

    #if os(macOS)
    private func pickFilesMac() {
        let panel = NSOpenPanel()
        panel.title = "Select image attachments"
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.image]
        panel.begin { resp in
            guard resp == .OK else { return }
            self.viewModel.addAttachments(urls: panel.urls)
        }
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        let fileProviders = providers.filter { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }
        guard !fileProviders.isEmpty else { return false }
        for item in fileProviders {
            item.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                guard let data = item as? Data,
                      let url = URL(dataRepresentation: data, relativeTo: nil)
                else { return }
                Task { @MainActor in
                    self.viewModel.addAttachments(urls: [url])
                }
            }
        }
        return true
    }

    #elseif os(iOS)
    private func loadPhotosPickerItems(_ items: [PhotosPickerItem]) async {
        for item in items {
            do {
                guard let data = try await item.loadTransferable(type: Data.self) else { continue }
                let type = item.supportedContentTypes.first ?? .image
                let ext = type.preferredFilenameExtension ?? "jpg"
                let mime = type.preferredMIMEType ?? "image/jpeg"
                let name = "photo-\(UUID().uuidString.prefix(8)).\(ext)"
                self.viewModel.addImageAttachment(data: data, fileName: name, mimeType: mime)
            } catch {
                self.viewModel.errorText = error.localizedDescription
            }
        }
        self.pickerItems = []
    }
    #endif
}

#if os(macOS)
import AppKit
import UniformTypeIdentifiers

private struct ChatComposerTextView: NSViewRepresentable {
    @Binding var text: String
    @Binding var shouldFocus: Bool
    var onSend: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let textView = ChatComposerNSTextView()
        textView.delegate = context.coordinator
        textView.drawsBackground = false
        textView.isRichText = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.font = .systemFont(ofSize: 14, weight: .regular)
        textView.textContainer?.lineBreakMode = .byWordWrapping
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainerInset = NSSize(width: 2, height: 4)
        textView.focusRingType = .none

        textView.minSize = .zero
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        textView.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = true

        textView.string = self.text
        textView.onSend = { [weak textView] in
            textView?.window?.makeFirstResponder(nil)
            self.onSend()
        }

        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.hasHorizontalScroller = false
        scroll.documentView = textView
        return scroll
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? ChatComposerNSTextView else { return }

        if self.shouldFocus, let window = scrollView.window {
            window.makeFirstResponder(textView)
            self.shouldFocus = false
        }

        let isEditing = scrollView.window?.firstResponder == textView

        // Always allow clearing the text (e.g. after send), even while editing.
        // Only skip other updates while editing to avoid cursor jumps.
        let shouldClear = self.text.isEmpty && !textView.string.isEmpty
        if isEditing, !shouldClear { return }

        if textView.string != self.text {
            context.coordinator.isProgrammaticUpdate = true
            defer { context.coordinator.isProgrammaticUpdate = false }
            textView.string = self.text
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: ChatComposerTextView
        var isProgrammaticUpdate = false

        init(_ parent: ChatComposerTextView) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard !self.isProgrammaticUpdate else { return }
            guard let view = notification.object as? NSTextView else { return }
            guard view.window?.firstResponder === view else { return }
            self.parent.text = view.string
        }
    }
}

private final class ChatComposerNSTextView: NSTextView {
    var onSend: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        let isReturn = event.keyCode == 36
        if isReturn {
            if event.modifierFlags.contains(.shift) {
                super.insertNewline(nil)
                return
            }
            self.onSend?()
            return
        }
        super.keyDown(with: event)
    }
}
#endif
