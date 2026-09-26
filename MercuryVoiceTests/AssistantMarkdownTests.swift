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

    @Test func singleNewlinesStayLineBreaks() throws {
        let block = try #require(AssistantMarkdown("Step one: open Settings\nStep two: tap Wi-Fi").blocks.first)
        #expect(String(block.text.characters) == "Step one: open Settings\nStep two: tap Wi-Fi")
    }

    @Test func lineBreaksLeaveCodeAndExistingBreaksAlone() {
        let source = "a\\\nb\n\n```\nx\ny\n```\n``inline``\nnext"
        let blocks = AssistantMarkdown(source).blocks
        #expect(blocks.map { String($0.text.characters) } == ["a\nb", "x\ny", "inline\nnext"])
    }

    /// Line-break preservation must never alter code content (copied code,
    /// whitespace-sensitive strings), wherever the code sits.
    @Test(arguments: [
        ("> ```\n> let a = 1\n> let b = 2\n> ```", "let a = 1\nlet b = 2"),
        ("Text:\n\n    let a = 1\n    let b = 2", "let a = 1\nlet b = 2"),
        ("````\n```\nlet a = 1\nlet b = 2\n````", "```\nlet a = 1\nlet b = 2"),
        ("```\nkeep one \nkeep two  \nlast\n```", "keep one \nkeep two  \nlast"),
        ("- item\n\n  ```\n  let a = 1\n  let b = 2\n  ```", "let a = 1\nlet b = 2"),
    ])
    func codeBlockContentIsExact(source: String, code: String) throws {
        let block = try #require(AssistantMarkdown(source).blocks.first { $0.isCode })
        #expect(String(block.text.characters) == code)
    }

    @Test func inlineCodeAcrossLinesIsExact() throws {
        let block = try #require(AssistantMarkdown("Use `a\nb` here\nthen more").blocks.first)
        let code = block.text.runs.filter { $0.inlinePresentationIntent?.contains(.code) == true }
        #expect(code.map { String(block.text[$0.range].characters) } == ["a b"])
        #expect(String(block.text.characters) == "Use a b here\nthen more")
    }

    @Test func tablesKeepRowsAndColumns() throws {
        let blocks = AssistantMarkdown("| Name | Qty |\n|---|---|\n| **Apples** | 3 |\n| Pears | |").blocks
        #expect(blocks.count == 1)
        let table = try #require(blocks.first?.table)
        #expect(table.hasHeader)
        #expect(table.columnCount == 2)
        #expect(table.rows.map { $0.map { String($0.characters) } } == [["Name", "Qty"], ["Apples", "3"], ["Pears"]])
    }

    @Test func quotesAndBreaksAreMarked() {
        let blocks = AssistantMarkdown("> quoted\n\n---\n\nafter").blocks
        #expect(blocks.map(\.isQuote) == [true, false, false])
        #expect(blocks.map(\.isThematicBreak) == [false, true, false])
    }

    @Test func codeBlockDropsClosingNewline() throws {
        let block = try #require(AssistantMarkdown("```\nlet x = 1\n```").blocks.first)
        #expect(String(block.text.characters) == "let x = 1")
    }

    /// The caption budget must count table cells; tables keep no `text` of their own.
    @Test func largeTableFallsOutsideCaptionBudget() {
        let rows = (1...100).map { "| row \($0) | value \($0) |" }.joined(separator: "\n")
        let blocks = AssistantMarkdown("| Name | Value |\n|---|---|\n" + rows + "\n\nFinal paragraph").blocks
        let visible = AssistantMarkdown.trailingBlocks(blocks, limit: 30)
        #expect(visible.count == 1)
        #expect(visible.allSatisfy { $0.table == nil })
        #expect(visible.map { String($0.text.characters) } == ["Final paragraph"])
    }

    @Test func smallTableAndParagraphFitTogether() {
        let blocks = AssistantMarkdown("| a | b |\n|---|---|\n| 1 | 2 |\n\nAfter").blocks
        let visible = AssistantMarkdown.trailingBlocks(blocks, limit: 30)
        #expect(visible.count == 2)
        #expect(visible.first?.table != nil)
        #expect(visible.last.map { String($0.text.characters) } == "After")
    }

    @Test func finalTableStaysVisibleOverBudget() {
        let rows = (1...100).map { "| row \($0) | value \($0) |" }.joined(separator: "\n")
        let blocks = AssistantMarkdown("Intro\n\n| Name | Value |\n|---|---|\n" + rows).blocks
        let visible = AssistantMarkdown.trailingBlocks(blocks, limit: 30)
        #expect(visible.count == 1)
        #expect(visible.first?.table?.rows.count == 101)
    }

    @MainActor @Test func nativeViewBoundsCaptionAfterLargeTable() throws {
        let rows = (1...100).map { "| row \($0) | value \($0) |" }.joined(separator: "\n")
        let renderer = ImageRenderer(content: AssistantMarkdownView(
            source: "| Name | Value |\n|---|---|\n" + rows + "\n\nFinal paragraph",
            trailingCharacterLimit: 30
        ).frame(width: 320).padding())
        let image = try #require(renderer.cgImage)
        #expect(image.height < 200)
    }

    /// Block rows sit in an HStack, where a plain Divider would draw vertically.
    @MainActor @Test func thematicBreakRendersHorizontally() throws {
        let renderer = ImageRenderer(content: AssistantMarkdownView(source: "---").frame(width: 320))
        let image = try #require(renderer.cgImage)
        #expect(image.width >= 320)
        #expect(image.height <= 4)
    }

    @MainActor @Test func nativeViewRendersTableAndBoundedCaption() throws {
        let long = (1...200).map { "Paragraph \($0)" }.joined(separator: "\n\n")
        let renderer = ImageRenderer(content: VStack {
            AssistantMarkdownView(source: "| a | b |\n|---|---|\n| 1 | 2 |\n\n> quote\n\n---")
            AssistantMarkdownView(source: long, trailingCharacterLimit: 60)
        }.frame(width: 320).padding())
        let image = try #require(renderer.cgImage)
        #expect(image.height > 100)
        // 200 paragraphs would be thousands of points tall; the bound keeps only the tail.
        #expect(image.height < 1200)
    }

    @Test func inlineFormattingAndLinks() throws {
        let block = try #require(AssistantMarkdown("**Bold** and *emphasis* with [link](https://example.com)").blocks.first)
        #expect(String(block.text.characters) == "Bold and emphasis with link")
        #expect(block.text.runs.contains { $0.inlinePresentationIntent?.contains(.stronglyEmphasized) == true })
        #expect(block.text.runs.contains { $0.inlinePresentationIntent?.contains(.emphasized) == true })
        #expect(block.text.runs.contains { $0.link == URL(string: "https://example.com") })
    }
}
