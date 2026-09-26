import SwiftUI

/// Presentation only: Foundation parses Markdown; SwiftUI lays out its block intents.
/// The original reply remains untouched for history and speech.
struct AssistantMarkdown {
    struct Table {
        var rows: [[AttributedString]] = []
        var hasHeader = false
        private var rowIDs: [Int] = []

        var columnCount: Int { rows.map(\.count).max() ?? 0 }

        /// Places one inline run into its cell; a cell can span several runs.
        mutating func add(_ text: AttributedString, intents: [PresentationIntent.IntentType]) {
            var column = 0
            var rowID = 0
            for intent in intents {
                switch intent.kind {
                case .tableCell(let index): column = index
                case .tableHeaderRow: rowID = intent.identity; hasHeader = true
                case .tableRow: rowID = intent.identity
                default: break
                }
            }
            if rowIDs.last != rowID {
                rowIDs.append(rowID)
                rows.append([])
            }
            while rows[rows.count - 1].count <= column { rows[rows.count - 1].append(AttributedString()) }
            rows[rows.count - 1][column].append(text)
        }
    }

    struct Block: Identifiable {
        let id: Int
        var text: AttributedString
        var components: [PresentationIntent.Kind]
        var listMarker: String?
        var table: Table?

        var headingLevel: Int? {
            for case .header(let level) in components { return level }
            return nil
        }

        var isCode: Bool {
            components.contains { if case .codeBlock = $0 { return true }; return false }
        }

        var isQuote: Bool { components.contains(.blockQuote) }

        var isThematicBreak: Bool { components.contains(.thematicBreak) }

        var listDepth: Int {
            components.filter { $0 == .orderedList || $0 == .unorderedList }.count
        }
    }

    let blocks: [Block]

    init(_ source: String) {
        // Full parsing also tolerates unfinished fences/emphasis while streaming.
        let original = (try? AttributedString(markdown: source)) ?? AttributedString(source)
        let prepared = (try? AttributedString(markdown: Self.preservingLineBreaks(source))) ?? original
        // The added hard breaks only change whitespace, so both parses have the same
        // code runs in the same order. Code must stay byte-exact, so take it from the
        // original parse; if the runs ever disagree, render the original unchanged.
        let originalCode = original.runs.filter(Self.isCode).map { AttributedString(original[$0.range]) }
        let useOriginal = prepared.runs.filter(Self.isCode).count != originalCode.count
        let parsed = useOriginal ? original : prepared
        var nextCode = originalCode.makeIterator()
        var result: [Block] = []
        var seenItems: Set<Int> = []
        for run in parsed.runs {
            let intents = run.presentationIntent?.components ?? []
            var text = !useOriginal && Self.isCode(run)
                ? nextCode.next() ?? AttributedString(parsed[run.range])
                : AttributedString(parsed[run.range])
            // Block semantics are handled below, not by Text's inline renderer.
            text.presentationIntent = nil
            // Every cell carries its own identity; group them under their table.
            if let table = intents.first(where: { if case .table = $0.kind { return true }; return false }) {
                if result.last?.id != table.identity {
                    result.append(Block(
                        id: table.identity, text: AttributedString(),
                        components: intents.map(\.kind), table: Table()
                    ))
                }
                result[result.count - 1].table?.add(text, intents: intents)
                continue
            }
            let id = intents.first?.identity ?? 0
            if result.last?.id == id {
                result[result.count - 1].text.append(text)
            } else {
                var marker: String?
                if let item = intents.first(where: { if case .listItem = $0.kind { return true }; return false }),
                   case .listItem(let ordinal) = item.kind,
                   seenItems.insert(item.identity).inserted
                {
                    let list = intents.first { $0.kind == .orderedList || $0.kind == .unorderedList }
                    marker = list?.kind == .orderedList ? "\(ordinal)." : "•"
                }
                result.append(Block(id: id, text: text, components: intents.map(\.kind), listMarker: marker))
            }
        }
        // Foundation keeps a fence's closing newline, which renders as a blank last line.
        for index in result.indices where result[index].isCode {
            let text = result[index].text
            if text.characters.last == "\n" {
                result[index].text.removeSubrange(text.characters.index(before: text.endIndex)..<text.endIndex)
            }
        }
        blocks = result
    }

    private static func isCode(_ run: AttributedString.Runs.Run) -> Bool {
        run.inlinePresentationIntent?.contains(.code) == true
            || run.presentationIntent?.components.contains { if case .codeBlock = $0.kind { return true }; return false } == true
    }

    /// Replies use single newlines as visible line breaks, but CommonMark folds them
    /// into spaces. Mark each one as a hard break instead. This also touches lines
    /// inside code, which is why `init` takes code content from an unmodified parse.
    static func preservingLineBreaks(_ source: String) -> String {
        var lines = source.components(separatedBy: "\n")
        for index in lines.indices where index + 1 < lines.count {
            let line = lines[index]
            let next = lines[index + 1]
            if line.trimmingCharacters(in: .whitespaces).isEmpty
                || next.trimmingCharacters(in: .whitespaces).isEmpty
                || line.hasSuffix("  ") || line.hasSuffix("\\")
            {
                continue
            }
            lines[index] = line + "  "
        }
        return lines.joined(separator: "\n")
    }
}

/// Views re-evaluate often (every streamed delta, every chat list update); reuse parses.
@MainActor
private enum AssistantMarkdownCache {
    private static var parsed: [String: [AssistantMarkdown.Block]] = [:]

    static func blocks(for source: String) -> [AssistantMarkdown.Block] {
        if let blocks = parsed[source] { return blocks }
        let blocks = AssistantMarkdown(source).blocks
        if parsed.count >= 64 { parsed.removeAll(keepingCapacity: true) }
        parsed[source] = blocks
        return blocks
    }
}

struct AssistantMarkdownView: View {
    let source: String
    /// Renders only the trailing blocks within roughly this many characters, for
    /// bottom-anchored viewports that never show the start of a long reply.
    var trailingCharacterLimit: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(visibleBlocks) { block in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    if block.listDepth > 0 {
                        Text(verbatim: block.listMarker ?? "")
                            .frame(minWidth: 20, alignment: .trailing)
                    }
                    blockContent(block)
                }
                .padding(.leading, CGFloat(max(0, block.listDepth - 1)) * 20)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var visibleBlocks: ArraySlice<AssistantMarkdown.Block> {
        let blocks = AssistantMarkdownCache.blocks(for: source)
        guard let limit = trailingCharacterLimit else { return blocks[...] }
        var start = blocks.endIndex
        var total = 0
        while start > blocks.startIndex {
            total += blocks[start - 1].text.characters.count
            if total > limit, start < blocks.endIndex { break }
            start -= 1
        }
        return blocks[start...]
    }

    @ViewBuilder
    private func blockContent(_ block: AssistantMarkdown.Block) -> some View {
        if let table = block.table {
            tableContent(table)
        } else if block.isCode {
            ScrollView(.horizontal) {
                Text(block.text)
                    .font(.system(.callout, design: .monospaced))
                    .fixedSize(horizontal: true, vertical: false)
                    .padding(8)
            }
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
        } else if block.isThematicBreak {
            Divider()
        } else if let level = block.headingLevel {
            Text(block.text)
                .font(level == 1 ? .title2.bold() : level == 2 ? .title3.bold() : .headline)
                .accessibilityAddTraits(.isHeader)
        } else if block.isQuote {
            Text(block.text)
                .foregroundStyle(.secondary)
                .padding(.leading, 10)
                .overlay(alignment: .leading) {
                    Capsule().fill(.tertiary).frame(width: 3)
                }
        } else {
            Text(block.text)
        }
    }

    private func tableContent(_ table: AssistantMarkdown.Table) -> some View {
        ScrollView(.horizontal) {
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
                ForEach(table.rows.indices, id: \.self) { row in
                    GridRow {
                        ForEach(0..<table.columnCount, id: \.self) { column in
                            let cells = table.rows[row]
                            Text(column < cells.count ? cells[column] : AttributedString())
                                .fontWeight(row == 0 && table.hasHeader ? .semibold : nil)
                        }
                    }
                    if row == 0 && table.hasHeader {
                        Divider()
                    }
                }
            }
            .padding(8)
        }
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
    }
}
