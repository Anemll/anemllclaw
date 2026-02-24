import Foundation

enum ChatMarkdownPreprocessor {
    struct InlineImage: Identifiable {
        let id: Int
        let label: String
        let image: OpenClawPlatformImage?
    }

    struct Result {
        let cleaned: String
        let images: [InlineImage]
        let prefersPlainText: Bool
    }

    static func preprocess(markdown raw: String) -> Result {
        let pattern = #"!\[([^\]]*)\]\((data:image\/[^;]+;base64,[^)]+)\)"#
        guard let re = try? NSRegularExpression(pattern: pattern) else {
            return Self.finalize(cleaned: raw, images: [])
        }

        let ns = raw as NSString
        let matches = re.matches(in: raw, range: NSRange(location: 0, length: ns.length))
        if matches.isEmpty { return Self.finalize(cleaned: raw, images: []) }

        var images: [InlineImage] = []
        var nextImageID = 0
        var cleaned = raw

        for match in matches.reversed() {
            guard match.numberOfRanges >= 3 else { continue }
            let label = ns.substring(with: match.range(at: 1))
            let dataURL = ns.substring(with: match.range(at: 2))

            let image: OpenClawPlatformImage? = {
                guard let comma = dataURL.firstIndex(of: ",") else { return nil }
                let b64 = String(dataURL[dataURL.index(after: comma)...])
                guard let data = Data(base64Encoded: b64) else { return nil }
                return OpenClawPlatformImage(data: data)
            }()
            images.append(InlineImage(id: nextImageID, label: label, image: image))
            nextImageID += 1

            // NSRegularExpression returns UTF-16 ranges; convert safely for Swift String indexing.
            if let imageRange = Range(match.range, in: cleaned) {
                cleaned.replaceSubrange(imageRange, with: "")
            }
        }

        return Self.finalize(cleaned: cleaned, images: images.reversed())
    }

    private static let structuredTextMaxCharacters = 12000
    private static let structuredTextMaxLineLength = 2000
    private static let structuredTextMaxLines = 260
    private static let plainTextCodeFenceCharsThreshold = 6000
    private static let plainTextCodeFenceLineThreshold = 140

    private static func finalize(cleaned: String, images: [InlineImage]) -> Result {
        let normalized = cleaned
            .unicodeScalars
            .filter { scalar in
                // Drop non-printable ASCII control chars that can destabilize rich markdown rendering.
                // Keep standard whitespace controls.
                switch scalar.value {
                case 0x09, 0x0A, 0x0D:
                    true
                case 0x00...0x1F:
                    false
                default:
                    true
                }
            }
            .reduce(into: String()) { partial, scalar in
                partial.unicodeScalars.append(scalar)
            }
            .replacingOccurrences(of: "\n\n\n", with: "\n\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let balanced = Self.balanceCodeFences(in: normalized)
        let prefersPlainText = Self.shouldPreferPlainText(for: balanced)
        return Result(cleaned: balanced, images: images, prefersPlainText: prefersPlainText)
    }

    private static func balanceCodeFences(in text: String) -> String {
        let fenceCount = text.components(separatedBy: "```").count - 1
        guard fenceCount % 2 != 0 else { return text }
        return text + "\n```"
    }

    private static func shouldPreferPlainText(for text: String) -> Bool {
        guard !text.isEmpty else { return false }
        let lineCount = text.split(whereSeparator: \.isNewline).count
        if lineCount > self.structuredTextMaxLines {
            return true
        }
        if text.count > self.structuredTextMaxCharacters {
            return true
        }
        let lines = text.split(whereSeparator: \.isNewline)
        let longestLine = lines.map(\.count).max() ?? 0
        if longestLine > self.structuredTextMaxLineLength {
            return true
        }

        // Fenced code blocks with high line/char counts have been unstable in some SwiftUI
        // rich-markdown render paths on device. Render those as plain text.
        let codeFenceCount = text.components(separatedBy: "```").count - 1
        if codeFenceCount >= 2,
           text.count >= self.plainTextCodeFenceCharsThreshold,
           lineCount >= self.plainTextCodeFenceLineThreshold
        {
            return true
        }
        return false
    }
}
