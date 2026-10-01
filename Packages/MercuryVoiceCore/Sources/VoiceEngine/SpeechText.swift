import Foundation

/// Text sanitization for TTS — a faithful port of the desktop's
/// `lib/speech-text.ts` (upstream as of 9b761903b9).
///
/// Pipeline order (must match): markdown tables → line-final colons → line
/// breaks → fenced code → thinking prefix → links → inline code → URLs →
/// MEDIA: tokens → emoji → identifier-dense tokens → headings → emphasis
/// chars → list bullets → trailing colon → whitespace collapse → trim.
///
/// Unspeakable tokens are silence, never a placeholder word: an English
/// "code block omitted" / "link" is wrong for every non-English voice
/// (#86602 upstream).
public enum SpeechText {
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
    /// A file-link token ("MEDIA:/path/to/report.xlsx") renders as a chip on
    /// screen; spoken, its slug makes voices loop. Silence, but a
    /// sentence-final period/comma after it is kept ("see MEDIA:/x.py. Then").
    private static let mediaPath = regex(#"[ \t]*MEDIA:\S+?(?=[.,;:!?)\]]*(?:\s|$))"#)
    private static let emoji = regex(
        #"(?:[\x{1F000}-\x{1FAFF}\x{2600}-\x{27BF}]|[\x{FE0F}\x{200D}]|[\x{E0020}-\x{E007F}])+"#)
    private static let heading = regex(#"^#{1,6}\s+"#, options: [.anchorsMatchLines])
    private static let emphasisChars = regex(#"[*_~>#]"#)
    private static let listBullet = regex(#"^\s*[-+*]\s+"#, options: [.anchorsMatchLines])
    /// Closed before newlines are flattened, so "the regex list:" followed by
    /// a code block reads "the regex list." and the voice never hangs on it.
    private static let lineFinalColon = regex(#":\s*$"#, options: [.anchorsMatchLines])
    /// A colon orphaned at the very end once its link/code was stripped.
    private static let trailingColon = regex(#":\s*$"#)
    private static let whitespaceRun = regex(#"\s+"#)

    // normalizeLineBreaks
    private static let crlf = regex(#"\r\n?"#)
    private static let hyphenWrap = regex(#"(\p{L})-\n(\p{L})"#)
    private static let punctuatedParagraphBreak = regex(
        #"([.!?])([*_~`>"'’”)\}\]]*)[ \t]*\n{2,}[ \t]*"#)
    private static let paragraphBreak = regex(#"[ \t]*\n{2,}[ \t]*"#)
    private static let softBreak = regex(#"[ \t]*\n[ \t]*"#)

    public static func sanitizeForSpeech(_ text: String) -> String {
        // Tables first: their right-align marker is a trailing colon (":-"),
        // which the colon pass below would otherwise mangle.
        var out = replace(summarizeMarkdownTables(text), lineFinalColon, with: ".")
        out = normalizeLineBreaks(out)
        out = replace(out, fencedCode, with: "")
        out = replace(out, thinkingPrefix, with: " ")
        out = replace(out, markdownLink, with: "$1")
        out = replace(out, inlineCode, with: "$1")
        out = replace(out, url, with: "")
        out = replace(out, mediaPath, with: "")
        out = replace(out, emoji, with: " ")
        // After fences/links/URLs/MEDIA: are consumed, so their contents are
        // not double-processed.
        out = pruneIdentifierTokens(out)
        out = replace(out, heading, with: "")
        out = replace(out, emphasisChars, with: "")
        out = replace(out, listBullet, with: "")
        out = replace(out, trailingColon, with: ".")
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

    // MARK: Identifier-dense tokens

    // Filenames with extensions, hashes, UUIDs, dense model/version IDs and
    // paths are read character by character ("peyton-sample-20260922.wav" →
    // "peyton dash sample dash two zero two six…"). They become silence.
    // Mirrors upstream's `pruneIdentifierTokens` token for token; its shared
    // corpus is `SpeechTextIdentifierCorpusTests`.
    private static let filenameExtension = regex(
        #"[\w.-]{0,60}\.(?:wav|ogg|mp3|flac|m4a|aac|py|pyc|ts|tsx|js|jsx|mjs|cjs|json|yaml|yml|toml|md|mdx|txt|csv|xlsx|xls|pdf|png|jpg|jpeg|gif|webp|svg|log|sql|sh|bash|zsh|rs|go|java|rb|php|html|css|lock|tar|gz|zip|db|sqlite|sqlite3|onnx|pt|bin|env|ini|conf|cfg|xml)\b"#,
        options: [.caseInsensitive])
    private static let uuid = regex(
        #"[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}"#)
    private static let hashPrefixHex = regex(
        #"\b(?:sha(?:-?256|-?512|-?1|3)?|blake2[ab]?|md5|crc32?)[:\s]+[0-9a-fA-F]{7,64}"#,
        options: [.caseInsensitive])
    private static let hexRun = regex(#"[0-9a-fA-F]{7,64}"#)
    private static let identifierToken = regex(#"[A-Za-z0-9_./~@-]+"#)
    private static let dateToken = regex(#"^\d{4}[-/]\d{1,2}(?:[-/]\d{1,2})?$"#)
    private static let pathPrefix = regex(#"^(?:~/|\.\.?/|/)"#)
    private static let digit = regex(#"\d"#)

    private static func matches(_ regex: NSRegularExpression, _ text: String) -> Bool {
        regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    static func isDenseIdentifier(_ token: String) -> Bool {
        // Email addresses and dates ("2026-09-28", "2026/06/02") stay.
        if token.contains("@") || matches(dateToken, token) { return false }
        if matches(pathPrefix, token) { return true }  // filesystem paths
        let hasDigit = matches(digit, token)
        // Paths and dense model IDs ("meta-llama/Llama-3.3-70B-Instruct").
        if token.contains("/"), matches(filenameExtension, token) || hasDigit { return true }
        if matches(filenameExtension, token) || matches(uuid, token) { return true }
        // Hex-hash runs ("73688014f78"); digit-free runs ("defaced") are words.
        if matches(hexRun, token), hasDigit { return true }
        if !hasDigit { return false }
        let separators = ["_", ".", "/"].filter { token.contains($0) }.count
        let hyphens = token.filter { $0 == "-" }.count
        // v2.1.0-beta.3, Llama-3.3-70B, dated filename slugs.
        if separators >= 2 || hyphens >= 2 { return true }
        return token.contains("/") || (hyphens >= 1 && separators >= 1)
    }

    static func pruneIdentifierTokens(_ text: String) -> String {
        let withoutHashes = replace(text, hashPrefixHex, with: " ")
        let ns = withoutHashes as NSString
        var out = ""
        var cursor = 0
        for match in identifierToken.matches(
            in: withoutHashes, range: NSRange(location: 0, length: ns.length))
        {
            out += ns.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
            let token = ns.substring(with: match.range)
            out += isDenseIdentifier(token) ? " " : token
            cursor = match.range.location + match.range.length
        }
        out += ns.substring(from: cursor)
        return out
    }

    // MARK: Markdown tables

    /// Runs first, on raw text (a pipe table inside a fenced code block is
    /// treated as a table — matches the desktop). The header row is spoken in
    /// place of the table ("Model, Price, Context."): the listener learns a
    /// table is on screen and what it compares, in the reply's own language,
    /// without the body being read cell by cell. An all-empty header is
    /// silence.
    static func summarizeMarkdownTables(_ text: String) -> String {
        let lines = replace(text, crlf, with: "\n").components(separatedBy: "\n")
        var tableLines = Set<Int>()
        var headers: [Int: String] = [:]

        var index = 1
        while index < lines.count {
            guard let delimiter = parseTableRow(lines[index]),
                let header = parseTableRow(lines[index - 1]),
                delimiter.cells.allSatisfy(isDelimiterCell),
                header.cells.count == delimiter.cells.count,
                header.blockquoteDepth == delimiter.blockquoteDepth
            else {
                index += 1
                continue
            }
            tableLines.insert(index - 1)
            tableLines.insert(index)
            headers[index - 1] = speakableTableHeader(header.cells)
            var body = index + 1
            while body < lines.count,
                let row = parseTableRow(lines[body]),
                row.blockquoteDepth == delimiter.blockquoteDepth
            {
                tableLines.insert(body)
                body += 1
            }
            index = body
        }

        guard !tableLines.isEmpty else { return lines.joined(separator: "\n") }
        return lines.enumerated()
            .compactMap { offset, line in
                guard tableLines.contains(offset) else { return line }
                guard let header = headers[offset], !header.isEmpty else { return nil }
                return header
            }
            .joined(separator: "\n")
    }

    private static func speakableTableHeader(_ cells: [String]) -> String {
        let header = cells
            .map { $0.replacingOccurrences(of: "\\|", with: " ").trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: ", ")
        guard let last = header.last, !".!?:".contains(last) else { return header }
        return header + "."
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

        // Indentation, then blockquote markers ('>' plus one optional space),
        // repeatedly: tabs or more than 3 spaces at any level is indented code.
        var depth = 0
        while true {
            var indent = 0
            while let first = rest.first, first == " " || first == "\t" {
                if first == "\t" { return nil }
                indent += 1
                if indent > 3 { return nil }
                rest = rest.dropFirst()
            }
            guard rest.first == ">" else { break }
            depth += 1
            rest = rest.dropFirst()
            if rest.first == " " { rest = rest.dropFirst() }
        }

        // trimEnd
        while let last = rest.last, last.isWhitespace { rest = rest.dropLast() }

        // Unescaped pipe positions (backslash parity).
        let chars = Array(rest)
        func isUnescapedPipe(_ i: Int) -> Bool {
            var backslashes = 0
            var j = i - 1
            while j >= 0, chars[j] == "\\" {
                backslashes += 1
                j -= 1
            }
            return backslashes % 2 == 0
        }
        let pipeIndexes = chars.indices.filter { chars[$0] == "|" && isUnescapedPipe($0) }
        guard let firstPipe = pipeIndexes.first, let lastPipe = pipeIndexes.last else {
            return nil
        }

        let hasLeading = firstPipe == 0
        let hasTrailing = lastPipe == chars.count - 1
        var row = chars
        if hasLeading { row.removeFirst() }
        if hasTrailing, !row.isEmpty { row.removeLast() }

        // splitMarkdownTableCells, re-scanning the trimmed row.
        var cells: [String] = []
        var cellStart = 0
        for i in row.indices where row[i] == "|" {
            var backslashes = 0
            var j = i - 1
            while j >= 0, row[j] == "\\" {
                backslashes += 1
                j -= 1
            }
            guard backslashes % 2 == 0 else { continue }
            cells.append(String(row[cellStart..<i]).trimmingCharacters(in: .whitespaces))
            cellStart = i + 1
        }
        cells.append(String(row[cellStart...]).trimmingCharacters(in: .whitespaces))

        if cells.count < 2, !(hasLeading && hasTrailing && cells.count == 1) { return nil }
        return TableRow(cells: cells, blockquoteDepth: depth)
    }
}
