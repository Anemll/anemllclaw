import Foundation
import SwiftUI
import Textual

public enum ChatMarkdownVariant: String, CaseIterable, Sendable {
    case standard
    case compact
}

@MainActor
struct ChatMarkdownRenderer: View {
    enum Context {
        case user
        case assistant
    }

    let text: String
    let context: Context
    let variant: ChatMarkdownVariant
    let font: Font
    let textColor: Color

    var body: some View {
        let display = ChatMarkdownDisplayLimiter.displayText(for: self.text)
        let redacted = ChatSensitiveValueRedactor.redact(display.text)
        let processed = ChatMarkdownPreprocessor.preprocess(markdown: redacted)
        let usePlainText = display.truncated
            || processed.prefersPlainText
            || ChatMarkdownDisplayLimiter.prefersPlainTextRenderer(for: processed.cleaned)
        VStack(alignment: .leading, spacing: 10) {
            if usePlainText {
                Text(processed.cleaned)
                    .font(self.font)
                    .foregroundStyle(self.textColor)
                    .openClawTextSelectionEnabledCompat()
            } else {
                StructuredText(markdown: processed.cleaned)
                    .modifier(ChatMarkdownStyle(
                        variant: self.variant,
                        context: self.context,
                        font: self.font,
                        textColor: self.textColor))
            }

            if !processed.images.isEmpty {
                InlineImageList(images: processed.images)
            }

            if display.truncated {
                Text(
                    "Showing first \(display.renderedUTF16) of \(display.originalUTF16) characters. "
                        + "Copy still uses the full message.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private enum ChatMarkdownDisplayLimiter {
    static let maxRenderedUTF16 = 12000
    private static let maxStructuredTextUTF16 = 6000

    static func displayText(for text: String)
    -> (text: String, truncated: Bool, originalUTF16: Int, renderedUTF16: Int) {
        let originalCount = text.utf16.count
        guard originalCount > self.maxRenderedUTF16 else {
            return (text, false, originalCount, originalCount)
        }

        let rendered = self.prefixByUTF16(text, self.maxRenderedUTF16)
        return (rendered, true, originalCount, rendered.utf16.count)
    }

    private static func prefixByUTF16(_ text: String, _ maxChars: Int) -> String {
        String(decoding: text.utf16.prefix(max(0, maxChars)), as: UTF16.self)
    }

    static func prefersPlainTextRenderer(for text: String) -> Bool {
        if text.utf16.count > self.maxStructuredTextUTF16 {
            return true
        }

        #if os(iOS) || os(tvOS)
        return true
        #else
        return false
        #endif
    }
}

private enum ChatSensitiveValueRedactor {
    static func redact(_ text: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: #"\d{7,}"#) else {
            return text
        }
        let nsText = text as NSString
        let matches = regex.matches(
            in: text,
            options: [],
            range: NSRange(location: 0, length: nsText.length))
        guard !matches.isEmpty else { return text }

        var result = ""
        var cursor = 0
        for match in matches {
            let range = match.range
            if range.location > cursor {
                result += nsText.substring(with: NSRange(location: cursor, length: range.location - cursor))
            }
            let rawID = nsText.substring(with: range)
            result += self.maskID(rawID)
            cursor = range.location + range.length
        }
        if cursor < nsText.length {
            result += nsText.substring(from: cursor)
        }
        return result
    }

    private static func maskID(_ rawID: String) -> String {
        let trimmed = rawID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "*" }
        let visibleCount = min(4, trimmed.count)
        return "*\(trimmed.suffix(visibleCount))"
    }
}

private struct ChatMarkdownStyle: ViewModifier {
    let variant: ChatMarkdownVariant
    let context: ChatMarkdownRenderer.Context
    let font: Font
    let textColor: Color

    func body(content: Content) -> some View {
        Group {
            if self.variant == .compact {
                content.textual.structuredTextStyle(.default)
            } else {
                content.textual.structuredTextStyle(.gitHub)
            }
        }
        .font(self.font)
        .foregroundStyle(self.textColor)
        .textual.inlineStyle(self.inlineStyle)
        .openClawTextSelectionEnabledCompat()
    }

    private var inlineStyle: InlineStyle {
        let linkColor: Color = self.context == .user ? self.textColor : .accentColor
        let codeScale: CGFloat = self.variant == .compact ? 0.85 : 0.9
        return InlineStyle()
            .code(.monospaced, .fontScale(codeScale))
            .link(.foregroundColor(linkColor))
    }
}

extension View {
    @ViewBuilder
    fileprivate func openClawTextSelectionEnabledCompat() -> some View {
        #if os(tvOS)
        self
        #else
        self.textual.textSelection(.enabled)
        #endif
    }
}

@MainActor
private struct InlineImageList: View {
    let images: [ChatMarkdownPreprocessor.InlineImage]

    var body: some View {
        ForEach(self.images, id: \.id) { item in
            if let img = item.image {
                OpenClawPlatformImageFactory.image(img)
                    .resizable()
                    .scaledToFit()
                    .frame(maxHeight: 260)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .strokeBorder(Color.white.opacity(0.12), lineWidth: 1))
            } else {
                Text(item.label.isEmpty ? "Image" : item.label)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
