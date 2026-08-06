import Foundation

/// Text sanitization for TTS — a faithful port of the desktop's
/// `lib/speech-text.ts`.
///
/// Pipeline order (must match): markdown tables → line breaks → fenced code →
/// thinking prefix → links → inline code → URLs → emoji → headings → emphasis
/// chars → list bullets → whitespace collapse → trim.
public enum SpeechText {
    static let codeBlockSummary = " code block omitted "

    private static func regex(_ pattern: String, options: NSRegularExpression.Options = [])
        -> NSRegularExpression
    {
        // Patterns are compile-time constants; a failure is programmer error.
        try! NSRegularExpression(pattern: pattern, options: options)
    }

    private static let fencedCode = regex(#"```[\s\S]*?(?:```|$)"#)
    private static let thinkingPrefix = regex(
        #"^\s*(?:\([^)\n]{1,48}\)\s*)?(?:processing|thinking|reasoning|analyzing|pondering|contemplating|musing|cogitating|ruminating|deliberating|mulling|reflecting|computing|synthesizing|formulating|brainstorming)\.\.\.\s*"#,
        options: [.caseInsensitive])
    private static let markdownLink = regex(#"\[([^\]]+)\]\(([^)]+)\)"#)
    private static let inlineCode = regex(#"`([^`]+)`"#)
    private static let url = regex(#"\bhttps?://\S+"#, options: [.caseInsensitive])
    private static let emoji = regex(
        #"(?:[\x{1F000}-\x{1FAFF}\x{2600}-\x{27BF}]|[\x{FE0F}\x{200D}]|[\x{E0020}-\x{E007F}])+"#)
    private static let heading = regex(#"^#{1,6}\s+"#, options: [.anchorsMatchLines])
    private static let emphasisChars = regex(#"[*_~>#]"#)
    private static let listBullet = regex(#"^\s*[-+*]\s+"#, options: [.anchorsMatchLines])
    private static let whitespaceRun = regex(#"\s+"#)

    // normalizeLineBreaks
    private static let crlf = regex(#"\r\n?"#)
    private static let hyphenWrap = regex(#"(\p{L})-\n(\p{L})"#)
    private static let punctuatedParagraphBreak = regex(
        #"([.!?])([*_~`>"'’”)\}\]]*)[ \t]*\n{2,}[ \t]*"#)
    private static let paragraphBreak = regex(#"[ \t]*\n{2,}[ \t]*"#)
    private static let softBreak = regex(#"[ \t]*\n[ \t]*"#)

    public static func sanitizeForSpeech(_ text: String) -> String {
        var out = normalizeLineBreaks(stripMarkdownTables(text))
        out = replace(out, fencedCode, with: codeBlockSummary)
        out = replace(out, thinkingPrefix, with: " ")
        out = replace(out, markdownLink, with: "$1")
        out = replace(out, inlineCode, with: "$1")
        out = replace(out, url, with: " link ")
        out = replace(out, emoji, with: " ")
        out = replace(out, heading, with: "")
        out = replace(out, emphasisChars, with: "")
        out = replace(out, listBullet, with: "")
        out = replace(out, whitespaceRun, with: " ")
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func replace(
        _ text: String, _ regex: NSRegularExpression, with template: String
    ) -> String {
        regex.stringByReplacingMatches(
            in: text, range: NSRange(text.startIndex..., in: text), withTemplate: template)
    }

    static func normalizeLineBreaks(_ text: String) -> String {
        var out = replace(text, crlf, with: "\n")
        out = replace(out, hyphenWrap, with: "$1$2")
        out = replace(out, punctuatedParagraphBreak, with: "$1$2 ")
        out = replace(out, paragraphBreak, with: ". ")
        out = replace(out, softBreak, with: " ")
        return out
    }

    // MARK: Markdown tables

    /// Runs first, on raw text (a pipe table inside a fenced code block is
    /// deleted as a table — matches the desktop).
    static func stripMarkdownTables(_ text: String) -> String {
        let lines = text.components(separatedBy: "\n")
        var removed = Set<Int>()

        var index = 1
        while index < lines.count {
            guard let delimiter = parseTableRow(lines[index]),
                delimiter.cells.allSatisfy(isDelimiterCell),
                let header = parseTableRow(lines[index - 1]),
                header.cells.count == delimiter.cells.count,
                header.blockquoteDepth == delimiter.blockquoteDepth
            else {
                index += 1
                continue
            }
            removed.insert(index - 1)
            removed.insert(index)
            var body = index + 1
            while body < lines.count,
                let row = parseTableRow(lines[body]),
                row.blockquoteDepth == delimiter.blockquoteDepth
            {
                removed.insert(body)
                body += 1
            }
            index = body + 1
        }

        guard !removed.isEmpty else { return text }
        return lines.enumerated()
            .filter { !removed.contains($0.offset) }
            .map(\.element)
            .joined(separator: "\n")
    }

    private static func isDelimiterCell(_ cell: String) -> Bool {
        var body = Substring(cell)
        if body.hasPrefix(":") { body = body.dropFirst() }
        if body.hasSuffix(":") { body = body.dropLast() }
        return body.count >= 3 && body.allSatisfy { $0 == "-" }
    }

    struct TableRow {
        var cells: [String]
        var blockquoteDepth: Int
    }

    static func parseTableRow(_ line: String) -> TableRow? {
        var rest = Substring(line)

        // Reject indentation with tabs or more than 3 spaces (indented code).
        var indent = 0
        while let first = rest.first, first == " " || first == "\t" {
            if first == "\t" { return nil }
            indent += 1
            if indent > 3 { return nil }
            rest = rest.dropFirst()
        }

        // Peel blockquote markers ('>' plus one optional following space).
        var depth = 0
        while rest.first == ">" {
            depth += 1
            rest = rest.dropFirst()
            if rest.first == " " { rest = rest.dropFirst() }
        }

        // trimEnd
        while let last = rest.last, last == " " || last == "\t" { rest = rest.dropLast() }
        guard rest.contains("|") else { return nil }

        // Unescaped pipe positions (backslash-parity).
        let chars = Array(rest)
        var pipeIndexes: [Int] = []
        for (i, char) in chars.enumerated() where char == "|" {
            var backslashes = 0
            var j = i - 1
            while j >= 0, chars[j] == "\\" {
                backslashes += 1
                j -= 1
            }
            if backslashes % 2 == 0 { pipeIndexes.append(i) }
        }
        guard !pipeIndexes.isEmpty else { return nil }

        let hasLeading = pipeIndexes.first == 0
        let hasTrailing = pipeIndexes.last == chars.count - 1

        var boundaries = pipeIndexes
        var start = 0
        var end = chars.count
        if hasLeading {
            start = 1
            boundaries.removeFirst()
        }
        if hasTrailing, !boundaries.isEmpty {
            end = chars.count - 1
            boundaries.removeLast()
        }

        var cells: [String] = []
        var cursor = start
        for boundary in boundaries {
            cells.append(
                String(chars[cursor..<boundary]).trimmingCharacters(in: .whitespaces))
            cursor = boundary + 1
        }
        if cursor <= end {
            cells.append(String(chars[cursor..<end]).trimmingCharacters(in: .whitespaces))
        }

        if cells.count < 2 {
            // Explicit single-column row needs both a leading and trailing pipe.
            guard hasLeading, hasTrailing, cells.count == 1 else { return nil }
        }
        return TableRow(cells: cells, blockquoteDepth: depth)
    }
}
