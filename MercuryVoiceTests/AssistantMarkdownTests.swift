import Foundation
import SwiftUI
import Testing
@testable import MercuryVoice

struct AssistantMarkdownTests {
    @Test func streamingFencePreservesLiteralCode() throws {
        let block = try #require(AssistantMarkdown("```swift\nlet value = \"**literal**\"").blocks.first)
        #expect(block.isCode)
        #expect(String(block.text.characters).contains("**literal**"))
    }

    @Test func incompleteInlineMarkupStaysReadable() {
        let source = "An **unfinished reply with [a link"
        #expect(AssistantMarkdown(source).blocks.map { String($0.text.characters) }.joined() == source)
    }

    @Test func nestedListsAndContinuationHaveStableMarkers() {
        let blocks = AssistantMarkdown("3. Outer\n\n   Continued\n\n   - Inner\n4. Next").blocks
        #expect(blocks.map(\.listMarker) == ["3.", nil, "•", "4."])
        #expect(blocks.map(\.listDepth) == [1, 1, 2, 1])
    }

    @Test func inlineRunsStayInOneBlock() throws {
        let blocks = AssistantMarkdown("A **bold** and `code` paragraph").blocks
        #expect(blocks.count == 1)
        let block = try #require(blocks.first)
        #expect(String(block.text.characters) == "A bold and code paragraph")
        #expect(block.text.runs.contains { $0.inlinePresentationIntent?.contains(.code) == true })
    }

    @MainActor @Test func nativeViewRendersBlockLayout() throws {
        let renderer = ImageRenderer(content: AssistantMarkdownView(
            source: "# Heading\n\n- **Bold** and *emphasis*\n- [Link](https://example.com)\n\n```swift\nlet x = 1\n```"
        ).frame(width: 320).padding())
        let image = try #require(renderer.cgImage)
        #expect(image.width > 300)
        #expect(image.height > 100)
    }

    @Test func blockStructure() {
        let blocks = AssistantMarkdown("# Heading\n\n- First **bold**\n- Second\n\n3. Third\n\n```swift\nlet x = \"**literal**\"\n```\n\nLast paragraph").blocks
        #expect(blocks.count == 6)
        #expect(blocks.first?.components.contains(.header(level: 1)) == true)
        #expect(blocks.contains { $0.components.contains(.unorderedList) })
        #expect(blocks.contains { $0.components.contains(.listItem(ordinal: 3)) })
        #expect(blocks.contains { $0.components.contains(.codeBlock(languageHint: "swift")) && String($0.text.characters).contains("**literal**") })
    }

    @MainActor @Test func captionPreservesCompleteMarkdownSource() {
        let source = "```swift\n" + String(repeating: "let value = 1\n", count: 80) + "```"
        #expect(ConversationController.captionSource(source) == source)
    }

    @Test func inlineFormattingAndLinks() throws {
        let block = try #require(AssistantMarkdown("**Bold** and *emphasis* with [link](https://example.com)").blocks.first)
        #expect(String(block.text.characters) == "Bold and emphasis with link")
        #expect(block.text.runs.contains { $0.inlinePresentationIntent?.contains(.stronglyEmphasized) == true })
        #expect(block.text.runs.contains { $0.inlinePresentationIntent?.contains(.emphasized) == true })
        #expect(block.text.runs.contains { $0.link == URL(string: "https://example.com") })
    }
}
