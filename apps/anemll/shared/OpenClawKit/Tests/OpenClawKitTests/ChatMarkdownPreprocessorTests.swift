import Testing
@testable import OpenClawChatUI

@Suite("ChatMarkdownPreprocessor")
struct ChatMarkdownPreprocessorTests {
    @Test func extractsDataURLImages() {
        let base64 = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVQIHWP4////GQAJ+wP/2hN8NwAAAABJRU5ErkJggg=="
        let markdown = """
        Hello

        ![Pixel](data:image/png;base64,\(base64))
        """

        let result = ChatMarkdownPreprocessor.preprocess(markdown: markdown)

        #expect(result.cleaned == "Hello")
        #expect(result.images.count == 1)
        #expect(result.images.first?.image != nil)
        #expect(result.prefersPlainText == false)
    }

    @Test func inlineImageIDsAreStableAcrossParses() {
        let base64 = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVQIHWP4////GQAJ+wP/2hN8NwAAAABJRU5ErkJggg=="
        let markdown = """
        ![One](data:image/png;base64,\(base64))
        ![Two](data:image/png;base64,\(base64))
        """

        let first = ChatMarkdownPreprocessor.preprocess(markdown: markdown)
        let second = ChatMarkdownPreprocessor.preprocess(markdown: markdown)

        #expect(first.images.map(\.id) == [0, 1])
        #expect(second.images.map(\.id) == [0, 1])
        #expect(first.prefersPlainText == false)
        #expect(second.prefersPlainText == false)
    }

    @Test func extractsImagesWhenPrefixContainsEmoji() {
        let base64 = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVQIHWP4////GQAJ+wP/2hN8NwAAAABJRU5ErkJggg=="
        let markdown = """
        Hello 👋
        ![Pixel](data:image/png;base64,\(base64))
        """

        let result = ChatMarkdownPreprocessor.preprocess(markdown: markdown)

        #expect(result.cleaned == "Hello 👋")
        #expect(result.images.count == 1)
        #expect(result.prefersPlainText == false)
    }

    @Test func stripsControlCharactersFromMarkdown() {
        let markdown = "Hello\u{0000}\u{0008}\nWorld\t!"
        let result = ChatMarkdownPreprocessor.preprocess(markdown: markdown)
        #expect(result.cleaned == "Hello\nWorld\t!")
        #expect(result.prefersPlainText == false)
    }

    @Test func balancesUnclosedCodeFence() {
        let markdown = """
        Before
        ```json
        {"ok":true}
        """
        let result = ChatMarkdownPreprocessor.preprocess(markdown: markdown)
        #expect(result.cleaned.hasSuffix("\n```"))
        #expect(result.prefersPlainText == false)
    }

    @Test func prefersPlainTextForPathologicallyLongLine() {
        let longLine = String(repeating: "a", count: 2100)
        let result = ChatMarkdownPreprocessor.preprocess(markdown: longLine)
        #expect(result.prefersPlainText == true)
    }

    @Test func prefersPlainTextForLargeFencedCodeBlock() {
        let codeLines = (0..<180).map { idx in "print(\"line \(idx)\")" }.joined(separator: "\n")
        let markdown = """
        Here is code:

        ```python
        \(codeLines)
        ```
        """
        let result = ChatMarkdownPreprocessor.preprocess(markdown: markdown)
        #expect(result.prefersPlainText == true)
    }
}
