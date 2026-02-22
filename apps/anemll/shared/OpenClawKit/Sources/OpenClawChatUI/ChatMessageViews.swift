import Foundation
import OpenClawKit
import SwiftUI

private enum ChatUIConstants {
    static var bubbleMaxWidth: CGFloat {
        #if os(macOS)
        .infinity
        #elseif os(iOS)
        ProcessInfo.processInfo.isiOSAppOnMac ? .infinity : 560
        #else
        560
        #endif
    }

    static let bubbleCorner: CGFloat = 18
}

private struct ChatBubbleShape: InsettableShape {
    enum Tail {
        case left
        case right
        case none
    }

    let cornerRadius: CGFloat
    let tail: Tail
    var insetAmount: CGFloat = 0

    private let tailWidth: CGFloat = 7
    private let tailBaseHeight: CGFloat = 9

    func inset(by amount: CGFloat) -> ChatBubbleShape {
        var copy = self
        copy.insetAmount += amount
        return copy
    }

    func path(in rect: CGRect) -> Path {
        let rect = rect.insetBy(dx: self.insetAmount, dy: self.insetAmount)
        switch self.tail {
        case .left:
            return self.leftTailPath(in: rect, radius: self.cornerRadius)
        case .right:
            return self.rightTailPath(in: rect, radius: self.cornerRadius)
        case .none:
            return Path(roundedRect: rect, cornerRadius: self.cornerRadius)
        }
    }

    private func rightTailPath(in rect: CGRect, radius r: CGFloat) -> Path {
        var path = Path()
        let bubbleMinX = rect.minX
        let bubbleMaxX = rect.maxX - self.tailWidth
        let bubbleMinY = rect.minY
        let bubbleMaxY = rect.maxY

        let available = max(4, bubbleMaxY - bubbleMinY - 2 * r)
        let baseH = min(tailBaseHeight, available)
        let baseBottomY = bubbleMaxY - max(r * 0.45, 6)
        let baseTopY = baseBottomY - baseH
        let midY = (baseTopY + baseBottomY) / 2

        let baseTop = CGPoint(x: bubbleMaxX, y: baseTopY)
        let baseBottom = CGPoint(x: bubbleMaxX, y: baseBottomY)
        let tip = CGPoint(x: bubbleMaxX + self.tailWidth, y: midY)

        path.move(to: CGPoint(x: bubbleMinX + r, y: bubbleMinY))
        path.addLine(to: CGPoint(x: bubbleMaxX - r, y: bubbleMinY))
        path.addQuadCurve(
            to: CGPoint(x: bubbleMaxX, y: bubbleMinY + r),
            control: CGPoint(x: bubbleMaxX, y: bubbleMinY))
        path.addLine(to: baseTop)
        path.addCurve(
            to: tip,
            control1: CGPoint(x: bubbleMaxX + self.tailWidth * 0.2, y: baseTopY + baseH * 0.05),
            control2: CGPoint(x: bubbleMaxX + self.tailWidth * 0.95, y: midY - baseH * 0.15))
        path.addCurve(
            to: baseBottom,
            control1: CGPoint(x: bubbleMaxX + self.tailWidth * 0.95, y: midY + baseH * 0.15),
            control2: CGPoint(x: bubbleMaxX + self.tailWidth * 0.2, y: baseBottomY - baseH * 0.05))
        path.addQuadCurve(
            to: CGPoint(x: bubbleMaxX - r, y: bubbleMaxY),
            control: CGPoint(x: bubbleMaxX, y: bubbleMaxY))
        path.addLine(to: CGPoint(x: bubbleMinX + r, y: bubbleMaxY))
        path.addQuadCurve(
            to: CGPoint(x: bubbleMinX, y: bubbleMaxY - r),
            control: CGPoint(x: bubbleMinX, y: bubbleMaxY))
        path.addLine(to: CGPoint(x: bubbleMinX, y: bubbleMinY + r))
        path.addQuadCurve(
            to: CGPoint(x: bubbleMinX + r, y: bubbleMinY),
            control: CGPoint(x: bubbleMinX, y: bubbleMinY))

        return path
    }

    private func leftTailPath(in rect: CGRect, radius r: CGFloat) -> Path {
        var path = Path()
        let bubbleMinX = rect.minX + self.tailWidth
        let bubbleMaxX = rect.maxX
        let bubbleMinY = rect.minY
        let bubbleMaxY = rect.maxY

        let available = max(4, bubbleMaxY - bubbleMinY - 2 * r)
        let baseH = min(tailBaseHeight, available)
        let baseBottomY = bubbleMaxY - max(r * 0.45, 6)
        let baseTopY = baseBottomY - baseH
        let midY = (baseTopY + baseBottomY) / 2

        let baseTop = CGPoint(x: bubbleMinX, y: baseTopY)
        let baseBottom = CGPoint(x: bubbleMinX, y: baseBottomY)
        let tip = CGPoint(x: bubbleMinX - self.tailWidth, y: midY)

        path.move(to: CGPoint(x: bubbleMinX + r, y: bubbleMinY))
        path.addLine(to: CGPoint(x: bubbleMaxX - r, y: bubbleMinY))
        path.addQuadCurve(
            to: CGPoint(x: bubbleMaxX, y: bubbleMinY + r),
            control: CGPoint(x: bubbleMaxX, y: bubbleMinY))
        path.addLine(to: CGPoint(x: bubbleMaxX, y: bubbleMaxY - r))
        path.addQuadCurve(
            to: CGPoint(x: bubbleMaxX - r, y: bubbleMaxY),
            control: CGPoint(x: bubbleMaxX, y: bubbleMaxY))
        path.addLine(to: CGPoint(x: bubbleMinX + r, y: bubbleMaxY))
        path.addQuadCurve(
            to: CGPoint(x: bubbleMinX, y: bubbleMaxY - r),
            control: CGPoint(x: bubbleMinX, y: bubbleMaxY))
        path.addLine(to: baseBottom)
        path.addCurve(
            to: tip,
            control1: CGPoint(x: bubbleMinX - self.tailWidth * 0.2, y: baseBottomY - baseH * 0.05),
            control2: CGPoint(x: bubbleMinX - self.tailWidth * 0.95, y: midY + baseH * 0.15))
        path.addCurve(
            to: baseTop,
            control1: CGPoint(x: bubbleMinX - self.tailWidth * 0.95, y: midY - baseH * 0.15),
            control2: CGPoint(x: bubbleMinX - self.tailWidth * 0.2, y: baseTopY + baseH * 0.05))
        path.addLine(to: CGPoint(x: bubbleMinX, y: bubbleMinY + r))
        path.addQuadCurve(
            to: CGPoint(x: bubbleMinX + r, y: bubbleMinY),
            control: CGPoint(x: bubbleMinX, y: bubbleMinY))

        return path
    }
}

@MainActor
struct ChatMessageBubble: View {
    let message: OpenClawChatMessage
    let showsToolCalls: Bool
    let style: OpenClawChatView.Style
    let markdownVariant: ChatMarkdownVariant
    let userAccent: Color?

    @State private var showCopied = false

    var body: some View {
        ChatMessageBody(
            message: self.message,
            isUser: self.isUser,
            showsToolCalls: self.showsToolCalls,
            style: self.style,
            markdownVariant: self.markdownVariant,
            userAccent: self.userAccent)
            .overlay(alignment: .topTrailing) {
                if !self.copyableText.isEmpty {
                    Button {
                        #if os(macOS)
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(
                            self.copyableText, forType: .string)
                        #else
                        UIPasteboard.general.string = self.copyableText
                        #endif
                        withAnimation(.easeInOut(duration: 0.15)) {
                            self.showCopied = true
                        }
                        Task {
                            try? await Task.sleep(nanoseconds: 1_200_000_000)
                            withAnimation(.easeOut(duration: 0.2)) {
                                self.showCopied = false
                            }
                        }
                    } label: {
                        Image(systemName: self.showCopied ? "checkmark" : "doc.on.doc")
                            .font(.system(size: 11))
                            .foregroundStyle(self.showCopied ? .green.opacity(0.8) : .secondary.opacity(0.3))
                            .padding(5)
                            .background(.ultraThinMaterial.opacity(0.5))
                            .clipShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .padding(4)
                }
            }
            .frame(maxWidth: ChatUIConstants.bubbleMaxWidth, alignment: self.isUser ? .trailing : .leading)
            .frame(maxWidth: .infinity, alignment: self.isUser ? .trailing : .leading)
            .padding(.horizontal, 2)
    }

    private var isUser: Bool {
        self.message.role.lowercased() == "user"
    }

    private var copyableText: String {
        let parts = self.message.content.compactMap { content -> String? in
            let kind = (content.type ?? "text").lowercased()
            guard kind == "text" || kind.isEmpty else { return nil }
            return content.text
        }
        return parts.joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

@MainActor
private struct ChatMessageBody: View {
    private enum LegacyToolTrace {
        case call(OpenClawChatMessageContent)
        case result(OpenClawChatMessageContent)
    }

    let message: OpenClawChatMessage
    let isUser: Bool
    let showsToolCalls: Bool
    let style: OpenClawChatView.Style
    let markdownVariant: ChatMarkdownVariant
    let userAccent: Color?
    @Environment(\.openClawChatTextScale) private var chatTextScale

    var body: some View {
        let text = self.primaryText
        let textColor = self.isUser ? OpenClawChatTheme.userText : OpenClawChatTheme.assistantText

        VStack(alignment: .leading, spacing: 10) {
            // Credential prompt — always visible, even when tool calls are hidden.
            // Checked first because legacy tool results use role "tool" (not "tool_result").
            if let credPrompt = self.standaloneCredentialPrompt {
                CredentialPromptCard(serviceName: credPrompt)
            } else if self.isToolResultMessage {
                if self.showsToolCalls, !text.isEmpty {
                    ToolResultCard(
                        title: self.toolResultTitle,
                        text: text,
                        isUser: self.isUser)
                }
            } else if self.isUser {
                if !text.isEmpty {
                    ChatMarkdownRenderer(
                        text: text,
                        context: .user,
                        variant: self.markdownVariant,
                        font: .system(size: 14 * self.chatTextScale),
                        textColor: textColor)
                }
            } else if !text.isEmpty {
                ChatAssistantTextBody(text: text, markdownVariant: self.markdownVariant)
            }

            if !self.inlineAttachments.isEmpty {
                ForEach(self.inlineAttachments.indices, id: \.self) { idx in
                    AttachmentRow(att: self.inlineAttachments[idx], isUser: self.isUser)
                }
            }

            if self.showsToolCalls, !self.toolCalls.isEmpty {
                ForEach(self.toolCalls.indices, id: \.self) { idx in
                    ToolCallCard(
                        content: self.toolCalls[idx],
                        isUser: self.isUser)
                }
            }

            if self.showsToolCalls, !self.inlineToolResults.isEmpty {
                ForEach(self.inlineToolResults.indices, id: \.self) { idx in
                    let toolResult = self.inlineToolResults[idx]
                    let display = ToolDisplayRegistry.resolve(name: toolResult.name ?? "tool", args: nil)
                    ToolResultCard(
                        title: "\(display.emoji) \(display.title)",
                        text: toolResult.text ?? "",
                        isUser: self.isUser)
                }
            }

            // Credential prompts always visible (even when tool calls are hidden)
            ForEach(self.inlineCredentialPrompts, id: \.self) { service in
                CredentialPromptCard(serviceName: service)
            }
        }
        .openClawTextSelectionEnabledCompat()
        .padding(.vertical, 10)
        .padding(.horizontal, 12)
        .foregroundStyle(textColor)
        .background(self.bubbleBackground)
        .clipShape(self.bubbleShape)
        .overlay(self.bubbleBorder)
        .shadow(color: self.bubbleShadowColor, radius: self.bubbleShadowRadius, y: self.bubbleShadowYOffset)
        .padding(.leading, self.tailPaddingLeading)
        .padding(.trailing, self.tailPaddingTrailing)
    }

    private var primaryText: String {
        if self.legacyToolTrace != nil {
            return ""
        }
        let parts = self.message.content.compactMap { content -> String? in
            let kind = (content.type ?? "text").lowercased()
            guard kind == "text" || kind.isEmpty else { return nil }
            return content.text
        }
        return parts.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var inlineAttachments: [OpenClawChatMessageContent] {
        self.message.content.filter { content in
            switch content.type ?? "text" {
            case "file", "attachment":
                true
            default:
                false
            }
        }
    }

    private var toolCalls: [OpenClawChatMessageContent] {
        var calls = self.message.content.filter { content in
            let kind = (content.type ?? "").lowercased()
            if ["toolcall", "tool_call", "tooluse", "tool_use"].contains(kind) {
                return true
            }
            return content.name != nil && content.arguments != nil
        }
        if case let .call(call)? = self.legacyToolTrace {
            calls.append(call)
        }
        return calls
    }

    private var inlineToolResults: [OpenClawChatMessageContent] {
        var results = self.message.content.filter { content in
            let kind = (content.type ?? "").lowercased()
            return kind == "toolresult" || kind == "tool_result"
        }
        if case let .result(result)? = self.legacyToolTrace {
            results.append(result)
        }
        return results
    }

    private var isToolResultMessage: Bool {
        let role = self.message.role.lowercased()
        return role == "toolresult" || role == "tool_result"
    }

    private var toolResultTitle: String {
        if let name = self.message.toolName, !name.isEmpty {
            let display = ToolDisplayRegistry.resolve(name: name, args: nil)
            return "\(display.emoji) \(display.title)"
        }
        let display = ToolDisplayRegistry.resolve(name: "tool", args: nil)
        return "\(display.emoji) \(display.title)"
    }

    // MARK: - Credential Prompts

    /// For standalone tool-result messages (role == "tool_result" or legacy "tool"),
    /// check if this is a credentials.get with hasKey: false.
    private var standaloneCredentialPrompt: String? {
        // Structured tool_result role with toolName
        if self.isToolResultMessage {
            let name = (self.message.toolName ?? "").lowercased()
            if name == "credentials.get" {
                return Self.parseCredentialService(from: self.primaryText)
            }
        }
        // Legacy "tool" role with "tool.result credentials.get {...}" text
        if case let .result(result)? = self.legacyToolTrace {
            if (result.name ?? "").lowercased() == "credentials.get" {
                return Self.parseCredentialService(from: result.text ?? "")
            }
        }
        return nil
    }

    /// For inline tool results inside assistant messages,
    /// extract credential prompts from results with hasKey: false.
    private var inlineCredentialPrompts: [String] {
        self.inlineToolResults.compactMap { result in
            guard (result.name ?? "").lowercased() == "credentials.get" else { return nil }
            return Self.parseCredentialService(from: result.text ?? "")
        }
    }

    /// Parse JSON tool result text for `hasKey: false` and extract the service name.
    private static func parseCredentialService(from text: String) -> String? {
        guard !text.isEmpty,
              let data = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              json["hasKey"] as? Bool == false,
              let service = json["service"] as? String,
              !service.isEmpty
        else { return nil }
        return service
    }

    private var legacyToolTrace: LegacyToolTrace? {
        let role = self.message.role.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard role != "user" else { return nil }

        let text = self.message.content.compactMap { content -> String? in
            let kind = (content.type ?? "text").lowercased()
            guard kind == "text" || kind.isEmpty else { return nil }
            return content.text
        }.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }

        if let call = Self.parseLegacyToolCall(
            text: text,
            toolCallID: self.message.toolCallId)
        {
            return .call(call)
        }

        if let result = Self.parseLegacyToolResult(
            text: text,
            toolCallID: self.message.toolCallId)
        {
            return .result(result)
        }

        // Keep broad parsing conservative: only explicit "tool" role gets the legacy fallback.
        guard role == "tool" else { return nil }

        let fallbackName = self.message.toolName?.trimmingCharacters(in: .whitespacesAndNewlines)
        let fallbackContent = OpenClawChatMessageContent(
            type: "tool_result",
            text: text,
            thinking: nil,
            thinkingSignature: nil,
            mimeType: nil,
            fileName: nil,
            content: nil,
            id: self.message.toolCallId,
            name: (fallbackName?.isEmpty == false ? fallbackName : "tool"),
            arguments: nil)
        return .result(fallbackContent)
    }

    private static func parseLegacyToolCall(
        text: String,
        toolCallID: String?) -> OpenClawChatMessageContent?
    {
        let prefix = "tool.call "
        guard text.lowercased().hasPrefix(prefix) else { return nil }

        let payload = String(text.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !payload.isEmpty else { return nil }

        let name: String
        let argsRaw: String
        if let argsRange = payload.range(of: " args=") {
            name = String(payload[..<argsRange.lowerBound])
            argsRaw = String(payload[argsRange.upperBound...])
        } else {
            name = payload
            argsRaw = ""
        }
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { return nil }

        let parsedArguments = Self.parseLegacyToolArguments(argsRaw)
        return OpenClawChatMessageContent(
            type: "tool_call",
            text: nil,
            thinking: nil,
            thinkingSignature: nil,
            mimeType: nil,
            fileName: nil,
            content: nil,
            id: toolCallID,
            name: trimmedName,
            arguments: parsedArguments)
    }

    private static func parseLegacyToolResult(
        text: String,
        toolCallID: String?) -> OpenClawChatMessageContent?
    {
        let prefix = "tool.result "
        guard text.lowercased().hasPrefix(prefix) else { return nil }

        let payload = String(text.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !payload.isEmpty else { return nil }

        let name: String
        let resultText: String
        if let split = payload.firstIndex(where: \.isWhitespace) {
            name = String(payload[..<split])
            resultText = String(payload[split...]).trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            name = payload
            resultText = ""
        }

        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { return nil }

        return OpenClawChatMessageContent(
            type: "tool_result",
            text: resultText.isEmpty ? "ok" : resultText,
            thinking: nil,
            thinkingSignature: nil,
            mimeType: nil,
            fileName: nil,
            content: nil,
            id: toolCallID,
            name: trimmedName,
            arguments: nil)
    }

    private static func parseLegacyToolArguments(_ raw: String) -> AnyCodable? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let data = trimmed.data(using: .utf8),
           let decoded = try? JSONDecoder().decode(AnyCodable.self, from: data)
        {
            return decoded
        }
        return AnyCodable(trimmed)
    }

    private var bubbleFillColor: Color {
        if self.isUser {
            return self.userAccent ?? OpenClawChatTheme.userBubble
        }
        if self.style == .onboarding {
            return OpenClawChatTheme.onboardingAssistantBubble
        }
        return OpenClawChatTheme.assistantBubble
    }

    private var bubbleBackground: AnyShapeStyle {
        AnyShapeStyle(self.bubbleFillColor)
    }

    private var bubbleBorderColor: Color {
        if self.isUser {
            return Color.white.opacity(0.12)
        }
        if self.style == .onboarding {
            return OpenClawChatTheme.onboardingAssistantBorder
        }
        return Color.white.opacity(0.08)
    }

    private var bubbleBorderWidth: CGFloat {
        if self.isUser { return 0.5 }
        if self.style == .onboarding { return 0.8 }
        return 1
    }

    private var bubbleBorder: some View {
        self.bubbleShape.strokeBorder(self.bubbleBorderColor, lineWidth: self.bubbleBorderWidth)
    }

    private var bubbleShape: ChatBubbleShape {
        ChatBubbleShape(cornerRadius: ChatUIConstants.bubbleCorner, tail: self.bubbleTail)
    }

    private var bubbleTail: ChatBubbleShape.Tail {
        guard self.style == .onboarding else { return .none }
        return self.isUser ? .right : .left
    }

    private var tailPaddingLeading: CGFloat {
        self.style == .onboarding && !self.isUser ? 8 : 0
    }

    private var tailPaddingTrailing: CGFloat {
        self.style == .onboarding && self.isUser ? 8 : 0
    }

    private var bubbleShadowColor: Color {
        self.style == .onboarding && !self.isUser ? Color.black.opacity(0.28) : .clear
    }

    private var bubbleShadowRadius: CGFloat {
        self.style == .onboarding && !self.isUser ? 6 : 0
    }

    private var bubbleShadowYOffset: CGFloat {
        self.style == .onboarding && !self.isUser ? 2 : 0
    }
}

extension View {
    @ViewBuilder
    fileprivate func openClawTextSelectionEnabledCompat() -> some View {
        #if os(tvOS)
        self
        #else
        self.textSelection(.enabled)
        #endif
    }
}

private struct AttachmentRow: View {
    let att: OpenClawChatMessageContent
    let isUser: Bool
    @Environment(\.openClawChatTextScale) private var chatTextScale

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "paperclip")
            Text(self.att.fileName ?? "Attachment")
                .font(.system(size: 13 * self.chatTextScale))
                .lineLimit(1)
                .foregroundStyle(self.isUser ? OpenClawChatTheme.userText : OpenClawChatTheme.assistantText)
            Spacer()
        }
        .padding(10)
        .background(self.isUser ? Color.white.opacity(0.2) : Color.black.opacity(0.04))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

private struct ToolCallCard: View {
    let content: OpenClawChatMessageContent
    let isUser: Bool
    @State private var expanded = false
    @Environment(\.openClawChatTextScale) private var chatTextScale

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(self.collapsedSummary)
                .font(.system(size: 13 * self.chatTextScale, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(self.expanded ? nil : 1)
                .contentShape(Rectangle())
                .onTapGesture {
                    guard self.canExpand else { return }
                    withAnimation(.easeInOut(duration: 0.15)) {
                        self.expanded.toggle()
                    }
                }

            if self.expanded, let argumentsText = self.argumentsText {
                Text(argumentsText)
                    .font(.system(size: 13 * self.chatTextScale, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .openClawTextSelectionEnabledCompat()
                    .lineLimit(nil)
            }

            if self.canExpand {
                Button(self.expanded ? "Collapse" : "Expand") {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        self.expanded.toggle()
                    }
                }
                .buttonStyle(.plain)
                .font(.system(size: 12 * self.chatTextScale))
                .foregroundStyle(.secondary)
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(OpenClawChatTheme.subtleCard)
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.08), lineWidth: 1)))
    }

    private var collapsedSummary: String {
        self.display.summaryLine
    }

    private var canExpand: Bool {
        self.argumentsText != nil
    }

    private var argumentsText: String? {
        guard let arguments = self.content.arguments else { return nil }
        let object = Self.foundationObject(from: arguments.value)
        if JSONSerialization.isValidJSONObject(object),
           let data = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]),
           let text = String(data: data, encoding: .utf8)?
               .trimmingCharacters(in: .whitespacesAndNewlines),
               !text.isEmpty
        {
            return text
        }

        let rendered = String(describing: object).trimmingCharacters(in: .whitespacesAndNewlines)
        return rendered.isEmpty ? nil : rendered
    }

    private static func foundationObject(from raw: Any) -> Any {
        switch raw {
        case let value as AnyCodable:
            self.foundationObject(from: value.value)
        case let dict as [String: AnyCodable]:
            dict.mapValues { self.foundationObject(from: $0.value) }
        case let array as [AnyCodable]:
            array.map { self.foundationObject(from: $0.value) }
        case let dict as [String: Any]:
            dict.mapValues { self.foundationObject(from: $0) }
        case let array as [Any]:
            array.map { self.foundationObject(from: $0) }
        case let value as NSString:
            String(value)
        case let value as NSNumber:
            value
        case let value as String:
            value
        case let value as NSNull:
            value
        default:
            String(describing: raw)
        }
    }

    private var display: ToolDisplaySummary {
        ToolDisplayRegistry.resolve(name: self.content.name ?? "tool", args: self.content.arguments)
    }
}

private struct ToolResultCard: View {
    let title: String
    let text: String
    let isUser: Bool
    @State private var expanded = false
    @Environment(\.openClawChatTextScale) private var chatTextScale

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text(self.title)
                    .font(.system(size: 13 * self.chatTextScale, weight: .semibold))
                Spacer(minLength: 0)
            }

            Text(self.displayText)
                .font(.system(size: 13 * self.chatTextScale, design: .monospaced))
                .foregroundStyle(self.isUser ? OpenClawChatTheme.userText : OpenClawChatTheme.assistantText)
                .lineLimit(self.expanded ? nil : 1)
                .truncationMode(.tail)
                .contentShape(Rectangle())
                .onTapGesture {
                    guard self.shouldShowToggle else { return }
                    withAnimation(.easeInOut(duration: 0.15)) {
                        self.expanded.toggle()
                    }
                }

            if self.shouldShowToggle {
                Button(self.expanded ? "Collapse" : "Expand") {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        self.expanded.toggle()
                    }
                }
                .buttonStyle(.plain)
                .font(.system(size: 12 * self.chatTextScale))
                .foregroundStyle(.secondary)
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(OpenClawChatTheme.subtleCard)
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.08), lineWidth: 1)))
    }

    private static let previewCharacterLimit = 180

    private var displayText: String {
        guard !self.expanded else { return self.text }
        return self.previewText
    }

    private var shouldShowToggle: Bool {
        self.previewText != self.normalizedText
    }

    private var previewText: String {
        let text = self.normalizedText
        guard text.count > Self.previewCharacterLimit else { return text }
        let end = text.index(text.startIndex, offsetBy: Self.previewCharacterLimit)
        return String(text[..<end]) + "…"
    }

    private var normalizedText: String {
        self.text
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}

// MARK: - Credential Prompt Card

@MainActor
struct CredentialPromptCard: View {
    let serviceName: String
    @State private var showingEntry = false
    @State private var saved = false
    @Environment(\.openClawCredentialSave) private var credentialSave
    @Environment(\.openClawChatTextScale) private var chatTextScale

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if self.saved {
                HStack(spacing: 8) {
                    Image(systemName: "key.fill")
                        .foregroundStyle(.green)
                    Text("API key configured for \(self.serviceName)")
                        .font(.system(size: 14 * self.chatTextScale, weight: .medium))
                }
                .padding(10)
            } else {
                Button {
                    self.showingEntry = true
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "key")
                        Text("Set up API key for \(self.serviceName)")
                            .font(.system(size: 14 * self.chatTextScale, weight: .medium))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .padding(.horizontal, 16)
                    .background(.blue)
                    .foregroundStyle(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
                .buttonStyle(.plain)
                .padding(10)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(OpenClawChatTheme.subtleCard)
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.08), lineWidth: 1)))
        .sheet(isPresented: self.$showingEntry) {
            CredentialEntrySheet(
                serviceName: self.serviceName,
                onSave: { key in
                    let ok = self.credentialSave?(self.serviceName, key) ?? false
                    if ok { self.saved = true }
                    return ok
                },
                onDismiss: { self.showingEntry = false })
        }
    }
}

private struct CredentialEntrySheet: View {
    let serviceName: String
    let onSave: (String) -> Bool
    let onDismiss: () -> Void
    @State private var apiKey = ""
    @State private var saveError = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    SecureField("API Key", text: self.$apiKey)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } header: {
                    Text("Enter API key for \(self.serviceName)")
                } footer: {
                    Text(
                        "Stored securely in the device keychain."
                            + " Never shared or displayed in chat.")
                }

                Section {
                    Button {
                        let trimmed = self.apiKey
                            .trimmingCharacters(in: .whitespacesAndNewlines)
                        let ok = self.onSave(trimmed)
                        if ok {
                            self.onDismiss()
                        } else {
                            self.saveError = true
                        }
                    } label: {
                        HStack {
                            Spacer()
                            Text("Save API Key")
                                .fontWeight(.semibold)
                            Spacer()
                        }
                    }
                    .disabled(
                        self.apiKey
                            .trimmingCharacters(in: .whitespacesAndNewlines)
                            .isEmpty)
                }
            }
            .navigationTitle("API Key")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { self.onDismiss() }
                }
            }
            .alert("Save Failed", isPresented: self.$saveError) {
                Button("OK", role: .cancel) {}
            } message: {
                Text("Could not save the API key to the device keychain.")
            }
        }
    }
}

@MainActor
struct ChatTypingIndicatorBubble: View {
    let style: OpenClawChatView.Style
    let assistantName: String?
    @Environment(\.openClawChatTextScale) private var chatTextScale

    var body: some View {
        HStack(spacing: 10) {
            TypingDots()
            if self.style == .standard {
                Text(self.thinkingLabel)
                    .font(.system(size: 15 * self.chatTextScale))
                    .foregroundStyle(.secondary)
                Spacer()
            }
        }
        .padding(.vertical, self.style == .standard ? 12 : 10)
        .padding(.horizontal, self.style == .standard ? 12 : 14)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(OpenClawChatTheme.assistantBubble))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.white.opacity(0.08), lineWidth: 1))
        .frame(maxWidth: ChatUIConstants.bubbleMaxWidth, alignment: .leading)
        .focusable(false)
    }

    private var thinkingLabel: String {
        let trimmed = (self.assistantName ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return "OpenClaw is thinking…"
        }
        return "\(trimmed) is thinking…"
    }
}

extension ChatTypingIndicatorBubble: @MainActor Equatable {
    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.style == rhs.style && lhs.assistantName == rhs.assistantName
    }
}

@MainActor
struct ChatStreamingAssistantBubble: View {
    let text: String
    let markdownVariant: ChatMarkdownVariant

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ChatAssistantTextBody(text: self.text, markdownVariant: self.markdownVariant)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(OpenClawChatTheme.assistantBubble))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.white.opacity(0.08), lineWidth: 1))
        .frame(maxWidth: ChatUIConstants.bubbleMaxWidth, alignment: .leading)
        .focusable(false)
    }
}

@MainActor
struct ChatPendingToolsBubble: View {
    let toolCalls: [OpenClawChatPendingToolCall]
    @Environment(\.openClawChatTextScale) private var chatTextScale

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Running tools…", systemImage: "hammer")
                .font(.system(size: 12 * self.chatTextScale))
                .foregroundStyle(.secondary)

            ForEach(self.toolCalls) { call in
                let display = ToolDisplayRegistry.resolve(name: call.name, args: call.args)
                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("\(display.emoji) \(display.label)")
                            .font(.system(size: 13 * self.chatTextScale, design: .monospaced))
                            .lineLimit(1)
                        Spacer(minLength: 0)
                        ProgressView().controlSize(.mini)
                    }
                    if let detail = display.detailLine, !detail.isEmpty {
                        Text(detail)
                            .font(.system(size: 12 * self.chatTextScale, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }
                .padding(10)
                .background(Color.white.opacity(0.06))
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(OpenClawChatTheme.assistantBubble))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.white.opacity(0.08), lineWidth: 1))
        .frame(maxWidth: ChatUIConstants.bubbleMaxWidth, alignment: .leading)
        .focusable(false)
    }
}

extension ChatPendingToolsBubble: @MainActor Equatable {
    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.toolCalls == rhs.toolCalls
    }
}

@MainActor
private struct TypingDots: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var animate = false

    var body: some View {
        HStack(spacing: 4) {
            ForEach(0..<3, id: \.self) { idx in
                Circle()
                    .fill(Color.primary.opacity(0.45))
                    .frame(width: 7, height: 7)
                    .scaleEffect(self.reduceMotion ? 0.85 : (self.animate ? 1.0 : 0.55))
                    .opacity(self.reduceMotion ? 0.7 : (self.animate ? 1.0 : 0.3))
                    .frame(width: 8, height: 8, alignment: .center)
                    .clipped()
                    .animation(
                        self.reduceMotion ? nil : .easeInOut(duration: 0.55)
                            .repeatForever(autoreverses: true)
                            .delay(Double(idx) * 0.16),
                        value: self.animate)
            }
        }
        .frame(height: 10, alignment: .center)
        .fixedSize()
        .clipped()
        .onAppear {
            // Delay slightly to ensure SwiftUI processes the initial layout before
            // toggling animate, so the animation transition is properly observed.
            if !self.reduceMotion {
                DispatchQueue.main.async {
                    self.animate = true
                }
            }
        }
        .onDisappear { self.animate = false }
    }
}

private struct ChatAssistantTextBody: View {
    let text: String
    let markdownVariant: ChatMarkdownVariant
    @Environment(\.openClawChatTextScale) private var chatTextScale

    var body: some View {
        let segments = AssistantTextParser.segments(from: self.text)
        VStack(alignment: .leading, spacing: 10) {
            ForEach(segments) { segment in
                let baseSize = 14 * self.chatTextScale
                let font = segment.kind == .thinking ? Font.system(size: baseSize).italic() : Font
                    .system(size: baseSize)
                ChatMarkdownRenderer(
                    text: segment.text,
                    context: .assistant,
                    variant: self.markdownVariant,
                    font: font,
                    textColor: OpenClawChatTheme.assistantText)
            }
        }
    }
}
