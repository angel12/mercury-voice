import Foundation
import Testing

@testable import VoiceEngine

/// Issue #146 item 2: `SpeechText` pinned to upstream's current
/// `apps/desktop/src/lib/speech-text.ts` (9b761903b9, 529d27e5be) — these
/// cases are ported one for one from `speech-text.test.ts`. Unspeakable
/// tokens are silence, never an English placeholder word (#86602 upstream).
@Suite("SpeechText upstream parity")
struct SpeechTextParityTests {
    private func spoken(_ text: String) -> String { SpeechText.sanitizeForSpeech(text) }

    @Test func fencedCodeIsSilenceAndItsColonCloses() {
        #expect(spoken("Here is code:\n```ts\nconst x = 1\n```\nDone.") == "Here is code. Done.")
    }

    @Test func inlineCodeStaysReadable() {
        #expect(spoken("Use `git status` after the change.") == "Use git status after the change.")
    }

    @Test func tableHeaderIsReadNotItsData() {
        let text = """
            Here is the quick takeaway: the totals remain unchanged.

            | Item | Value | Notes |
            | --- | ---: | --- |
            | Example A | 10 | first row |
            | Example B | 20 | second row |

            Full detail stays visible on screen.
            """
        #expect(
            spoken(text)
                == "Here is the quick takeaway: the totals remain unchanged. Item, Value, Notes. Full detail stays visible on screen."
        )
    }

    @Test func nonEnglishReplyGetsNoEnglishWords() {
        let text = """
            对比如下：

            | 模型 | 价格 |
            | --- | ---: |
            | 甲 | 10 |

            代码：
            ```py
            print(1)
            ```
            详情见 https://example.com/docs
            """
        let out = spoken(text)
        #expect(out.contains("模型, 价格"))
        #expect(out.range(of: "[A-Za-z]", options: .regularExpression) == nil)
    }

    @Test func tableWithEmptyHeaderIsSilent() {
        let text = """
            Before the table.

            |   |   |
            | --- | --- |
            | a | b |

            After the table.
            """
        #expect(spoken(text) == "Before the table. After the table.")
    }

    @Test func proseWithAPipeIsKept() {
        let text = "Use the summary first | keep the table on screen when it matters."
        #expect(spoken(text) == text)
    }

    @Test func paragraphBreakDoesNotDuplicatePunctuation() {
        #expect(spoken("First sentence.\n\nSecond sentence.") == "First sentence. Second sentence.")
    }

    @Test(arguments: [
        ("**First sentence.**\n\nSecond sentence.", "First sentence. Second sentence."),
        ("“First sentence.”\n\nSecond sentence.", "“First sentence.” Second sentence."),
        ("(First sentence.)\n\nSecond sentence.", "(First sentence.) Second sentence."),
    ])
    func noDuplicatePunctuationAfterClosers(text: String, expected: String) {
        #expect(spoken(text) == expected)
    }

    @Test func mediaFileTokensAreSilent() {
        let text =
            "The files are below.\nMEDIA:/Users/ricardo/Documents/inference-server-shopping-list.xlsx\nBye."
        #expect(spoken(text) == "The files are below. Bye.")
        #expect(spoken("See MEDIA:/tmp/report-2026-q3.xlsx. Then reply.") == "See. Then reply.")
    }

    @Test func urlsAreSilence() {
        #expect(spoken("See https://example.com/a-huge-page for details") == "See for details")
    }

    @Test func strikethroughStaysReadable() {
        #expect(spoken("This ~~is~~ old.") == "This is old.")
    }

    @Test func orphanedColonsClose() {
        #expect(spoken("The file is below: MEDIA:/tmp/x.py") == "The file is below.")
        #expect(
            spoken("One line added to the regex list:\n```ts\nconst x = 1\n```\nBye.")
                == "One line added to the regex list. Bye.")
        #expect(spoken("The regex list:") == "The regex list.")
    }

    @Test func tableWithoutOuterPipes() {
        let text = """
            Main takeaway: total is unchanged.

            Item | Value
            --- | ---:
            Example A | 10
            Example B | 20

            Done.
            """
        #expect(spoken(text) == "Main takeaway: total is unchanged. Item, Value. Done.")
    }

    @Test func tableInsideBlockquote() {
        let text = """
            Before the table.

            > | Item | Value |
            > | --- | ---: |
            > | Example A | 10 |
            > | Example B | 20 |

            After the table.
            """
        #expect(spoken(text) == "Before the table. Item, Value. After the table.")
    }

    @Test func blockquoteMarkerPaddingPlusThreeSpaces() {
        let text = """
            Before the table.

            >    | Item | Value |
            >    | --- | ---: |
            >    | Example A | 10 |

            After the table.
            """
        #expect(spoken(text) == "Before the table. Item, Value. After the table.")
    }

    @Test func singleColumnTable() {
        let text = """
            Before the table.

            | Item |
            | --- |
            | Example A |

            After the table.
            """
        #expect(spoken(text) == "Before the table. Item. After the table.")
    }

    @Test func rowsOutsideTheBlockquoteSurvive() {
        let text = """
            > | Item | Value |
            > | --- | ---: |
            > | Example A | 10 |
            Outside | prose
            """
        #expect(spoken(text) == "Item, Value. Outside | prose")
    }

    @Test func mismatchedColumnCountsAreNotATable() {
        let text = """
            Heading | Detail
            --- | --- | ---
            Keep this prose.
            """
        #expect(spoken(text).contains("Heading | Detail"))
    }

    @Test func bodyRowsWithOtherCellCountsAreStillSkipped() {
        let text = """
            Before the table.

            | Item | Value |
            | --- | ---: |
            | Example A |
            | Example B | 20 | ignored |

            After the table.
            """
        #expect(spoken(text) == "Before the table. Item, Value. After the table.")
    }

    @Test func escapedPipesInTheHeader() {
        let text = """
            Before the table.

            | Item \\| detail | Value |
            | --- | ---: |
            | Example A | 10 |

            After the table.
            """
        #expect(spoken(text) == "Before the table. Item detail, Value. After the table.")
    }

    @Test func indentedCodeThatLooksLikeATableIsKept() {
        let text = "    Item | Value\n    --- | ---\n    Example A | 10"
        #expect(spoken(text).contains("Item | Value"))
    }
}

/// The shared corpus upstream pins both its speech normalizers to
/// (`tests/fixtures/identifier_speech_corpus.json`, 9b761903b9), copied
/// verbatim. Identifier-dense tokens — filenames, hashes, UUIDs, model and
/// version IDs, paths — are silence; prose, emails, dates and ratios pass.
@Suite("SpeechText identifier corpus")
struct SpeechTextIdentifierCorpusTests {
    static let identifierTokens: [(String, [String], [String])] = [
        ("Saved peyton-sample-20260922.wav and peyton-sample-20260922.ogg.",
         ["peyton", "20260922", ".wav", ".ogg"], ["Saved", "and"]),
        ("The digest is sha256:e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855 for the file.",
         ["e3b0c442", "7852b855", "sha256:"], ["The digest is", "for the file"]),
        ("Commit 73688014f78 landed.", ["73688014f78"], ["Commit", "landed"]),
        ("Trace id 550e8400-e29b-41d4-a716-446655440000 appears once.",
         ["550e8400", "446655440000"], ["Trace id", "appears once"]),
        ("Model meta-llama/Llama-3.3-70B-Instruct is large.",
         ["meta-llama/Llama-3.3-70B-Instruct", "70B"], ["Model", "is large"]),
        ("Config at ~/.config/hermes/config.yaml was read.",
         ["config.yaml", "~/.config"], ["Config at", "was read"]),
        ("Version v2.1.0-beta.3 shipped.", ["v2.1.0-beta.3"], ["Version", "shipped"]),
    ]

    static let passThroughTokens: [(String, [String])] = [
        ("The samples played cleanly, so listen again.", ["The samples played cleanly, so listen again"]),
        ("Use git status after the change.", ["Use git status after the change"]),
        ("Email me at user@example.com.", ["user@example.com"]),
        ("COVID-19 and well-known facts stay.", ["COVID-19", "well-known"]),
        ("Due 2026/06/02 and status N/A here.", ["2026/06/02", "N/A"]),
        ("The final score was 3:2.", ["3:2"]),
    ]

    @Test(arguments: identifierTokens.indices)
    func identifierTokensAreSilenced(index: Int) {
        let (text, mustNotContain, mustContain) = Self.identifierTokens[index]
        let out = SpeechText.sanitizeForSpeech(text)
        for needle in mustNotContain {
            #expect(!out.contains(needle), "\(needle) leaked from \(text): \(out)")
        }
        for needle in mustContain {
            #expect(out.contains(needle), "\(needle) lost from \(text): \(out)")
        }
    }

    @Test(arguments: passThroughTokens.indices)
    func ordinarySpeechPassesThrough(index: Int) {
        let (text, mustContain) = Self.passThroughTokens[index]
        let out = SpeechText.sanitizeForSpeech(text)
        for needle in mustContain {
            #expect(out.contains(needle), "\(needle) lost from \(text): \(out)")
        }
    }
}
