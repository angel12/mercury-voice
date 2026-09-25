import SwiftUI

/// Presentation only: Foundation parses Markdown; SwiftUI lays out its block intents.
/// The original reply remains untouched for history and speech.
struct AssistantMarkdown {
    struct Block: Identifiable {
        let id: Int
        var text: AttributedString
        var components: [PresentationIntent.Kind]
        var listMarker: String?

        var headingLevel: Int? {
            for case .header(let level) in components { return level }
            return nil
        }

        var isCode: Bool {
            components.contains { if case .codeBlock = $0 { return true }; return false }
        }

        var listDepth: Int {
            components.filter { $0 == .orderedList || $0 == .unorderedList }.count
        }
    }

    let blocks: [Block]

    init(_ source: String) {
        // Full parsing also tolerates unfinished fences/emphasis while streaming.
        let parsed = (try? AttributedString(markdown: source)) ?? AttributedString(source)
        var result: [Block] = []
        var seenItems: Set<Int> = []
        for run in parsed.runs {
            let intents = run.presentationIntent?.components ?? []
            let id = intents.first?.identity ?? 0
            var text = AttributedString(parsed[run.range])
            // Block semantics are handled below, not by Text's inline renderer.
            text.presentationIntent = nil
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
        blocks = result
    }
}

struct AssistantMarkdownView: View {
    let source: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(AssistantMarkdown(source).blocks) { block in
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

    @ViewBuilder
    private func blockContent(_ block: AssistantMarkdown.Block) -> some View {
        if block.isCode {
            ScrollView(.horizontal) {
                Text(block.text)
                    .font(.system(.callout, design: .monospaced))
                    .fixedSize(horizontal: true, vertical: false)
                    .padding(8)
            }
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
        } else if let level = block.headingLevel {
            Text(block.text)
                .font(level == 1 ? .title2.bold() : level == 2 ? .title3.bold() : .headline)
                .accessibilityAddTraits(.isHeader)
        } else {
            Text(block.text)
        }
    }
}
