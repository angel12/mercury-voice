import Foundation
import Testing

@testable import HermesKit
@testable import VoiceEngine

// MARK: - Support

/// Splits text the way a provider streams it, so a test can prove the
/// composition does not depend on where the deltas fall.
private func deltas(_ text: String, size: Int) -> [String] {
    var out: [String] = []
    var rest = Substring(text)
    while !rest.isEmpty {
        out.append(String(rest.prefix(size)))
        rest = rest.dropFirst(size)
    }
    return out
}

/// Everything the segmenter produces for `text`, fed one delta at a time.
private func spoken(_ text: String, deltaSize: Int? = nil) -> [String] {
    var segmenter = SpeechSegmenter()
    var out: [String] = []
    let chunks = deltaSize.map { deltas(text, size: $0) } ?? [text]
    for chunk in chunks { out += segmenter.accept(chunk, flush: false) }
    out += segmenter.accept("", flush: true)
    return out
}

private let ttsConfig: DirectTTSConfig = {
    let json = try! JSONDecoder().decode(
        JSONValue.self,
        from: Data(
            """
            {"mode": "direct", "wire": "openai-speech", "provider": "openai",
             "base_url": "https://api.example.com/v1/", "api_key": "sk-t"}
            """.utf8))
    return DirectTTSConfig(json: json)!
}()

/// Records the sentences handed to the provider. One byte of "audio" per
/// call — `RecordingClipPlayer` never decodes it.
private final class RecordingSynthesizer: SpeechSynthesizing, @unchecked Sendable {
    private let lock = NSLock()
    private nonisolated(unsafe) var _texts: [String] = []

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    var texts: [String] { locked { _texts } }

    func synthesize(config: DirectTTSConfig, text: String) async throws -> Data {
        locked { _texts.append(text) }
        return Data([0x01])
    }
}

// MARK: - The composition

/// Issue #68. Each sentence is sanitized on its own, so anything the
/// sanitizer reads across a sentence boundary is read wrong. Fenced code is
/// the case that bites: the code is spoken and the prose after the block is
/// swallowed. These drive `SentenceCutter` and `SpeechText` composed exactly
/// as `DirectSpeechSession.ingest` composes them.
@Suite("Speech segmenter (streamed markdown)")
struct SpeechSegmenterTests {
    /// The reported reproduction: a sentence boundary inside the code.
    /// Pre-fix this speaks `This line is code. print(x)` and loses the
    /// closing prose entirely.
    @Test func fencedCodeIsNotSpokenAndTheProseAfterItSurvives() {
        let reply = """
            Here is the code you asked for:
            ```swift
            let x = 1. This line is code.
            print(x)
            ```
            And then the prose continues after the block.
            """

        for size in [nil, 1, 7, 64] as [Int?] {
            let out = spoken(reply, deltaSize: size)
            let all = out.joined(separator: " ")
            #expect(!all.contains("This line is code"), "delta size \(String(describing: size))")
            #expect(!all.contains("print"), "delta size \(String(describing: size))")
            #expect(!all.contains("let x"), "delta size \(String(describing: size))")
            #expect(all.contains("And then the prose continues after the block."))
            #expect(all.contains(SpeechText.codeBlockSummary.trimmingCharacters(in: .whitespaces)))
            // Where the deltas fall never changes what is spoken.
            #expect(out == spoken(reply), "delta size \(String(describing: size))")
        }
    }

    /// A code comment ending in a period is the everyday trigger — the code
    /// does not have to look like prose.
    @Test func aSentenceEndingCommentInsideTheFenceIsNotACutPoint() {
        let reply = """
            Here is how you do it:

            ```swift
            // Sets the value.
            let x = 1
            print(x)
            ```

            That prints one. Anything else?
            """

        #expect(
            spoken(reply, deltaSize: 7) == [
                "Here is how you do it:. code block omitted . That prints one.",
                "Anything else?",
            ])
    }

    /// The whole point of cutting: prose is still spoken as it completes, not
    /// held until the reply ends.
    @Test func proseWithoutFencesStillStreamsSentenceBySentence() {
        var segmenter = SpeechSegmenter()
        #expect(segmenter.accept("The first sentence is long enough to speak. ", flush: false)
            == ["The first sentence is long enough to speak."])
        #expect(segmenter.accept("And a second one, also long enough. ", flush: false)
            == ["And a second one, also long enough."])
        #expect(segmenter.accept("A tail", flush: true) == ["A tail"])
    }

    /// The cost of keeping fences whole, asserted rather than assumed: once a
    /// fence opens, nothing more is spoken until it closes. Inside the block
    /// there is nothing worth saying, but the prose after it does wait.
    @Test func nothingIsSpokenWhileAFenceIsStillOpen() throws {
        var segmenter = SpeechSegmenter()
        #expect(segmenter.accept("First a sentence that is long enough. ", flush: false)
            == ["First a sentence that is long enough."])

        #expect(segmenter.accept("```swift\nlet x = 1. More code here. ", flush: false) == [])
        #expect(segmenter.accept("Still inside the block. ", flush: false) == [])

        let released = segmenter.accept("```\nAnd the tail sentence follows. ", flush: false)
        try #require(released.count == 1)
        #expect(released[0].contains("code block omitted"))
        #expect(released[0].hasSuffix("And the tail sentence follows."))
        #expect(!released[0].contains("More code here"))
    }

    /// The cut point can sit exactly where a fence opens — "…done.\n```" is
    /// an everyday shape — and that sentence is complete, so it is spoken
    /// now rather than held for the block that follows it.
    @Test func aSentenceEndingWhereAFenceOpensIsSpokenAtOnce() {
        var segmenter = SpeechSegmenter()
        #expect(
            segmenter.accept("Here is the thing you wanted.\n```swift\n", flush: false)
                == ["Here is the thing you wanted."])
    }

    /// A fence that never closes is summarised at flush, matching
    /// `SpeechText.unterminatedFenceIsStripped` for whole text.
    @Test func anUnclosedFenceAtFlushIsStillSummarised() {
        let out = spoken("Look at this:\n```python\nprint('hi')", deltaSize: 5)
        #expect(out == ["Look at this: code block omitted"])
    }

    /// The subtle one. A boundary at the very end of the buffer sits inside a
    /// fence that has not closed *yet*; cutting there speaks the opening
    /// fence now and strands its closer in a later sentence, where the
    /// sanitizer reads it as an opener and swallows the rest of the reply.
    @Test func anUnclosedFenceNeverStrandsItsCloserInALaterSentence() throws {
        var segmenter = SpeechSegmenter()
        #expect(segmenter.accept("Look at this snippet:\n```python\nprint('hi'). ", flush: false)
            == [])

        let out = segmenter.accept("more(). \n```\nDone with that one now. ", flush: false)
        try #require(out.count == 1)
        #expect(!out[0].contains("print"))
        #expect(!out[0].contains("more()"))
        #expect(out[0].hasSuffix("Done with that one now."))
    }

    @Test func twoFencedBlocksInOneReply() {
        let reply = """
            First block coming up now.
            ```sh
            ls -la. Look at that.
            ```
            Between the blocks there is prose. Second block now.
            ```sh
            rm -rf /tmp/x. Careful there.
            ```
            And a closing sentence.
            """
        let all = spoken(reply, deltaSize: 3).joined(separator: " ")
        #expect(!all.contains("ls -la"))
        #expect(!all.contains("rm -rf"))
        #expect(!all.contains("Careful there"))
        #expect(all.contains("Between the blocks there is prose."))
        #expect(all.contains("And a closing sentence."))
    }

    /// A sentence the sanitizer empties out is dropped rather than queued as
    /// an empty synthesis request. `###` is markdown furniture with no text
    /// behind it; a code block is not this case, it speaks its summary.
    @Test func aSentenceThatSanitizesToNothingIsNotSpoken() {
        #expect(spoken("###", deltaSize: 1) == [])
        #expect(spoken("```\njust code\n```", deltaSize: 3) == ["code block omitted"])
    }
}

// MARK: - The call site

/// The segmenter is only worth anything if the shipping session uses it.
/// These drive `append`/`finish` on the real actor and read back exactly what
/// reached the provider.
@Suite("Direct speech session speaks the composed segments")
struct DirectSpeechSessionCompositionTests {
    private func run(_ reply: String, deltaSize: Int) async -> (
        texts: [String], outcome: SpeechStreamOutcome, plays: Int
    ) {
        let synth = RecordingSynthesizer()
        let clip = RecordingClipPlayer()
        let session = DirectSpeechSession(
            config: ttsConfig, client: synth, makePlayer: { clip })

        for chunk in deltas(reply, size: deltaSize) { await session.append(chunk) }
        await session.finish()
        let outcome = await session.waitDone()
        return (synth.texts, outcome, clip.plays.count)
    }

    @Test func fencedCodeNeverReachesTheProvider() async throws {
        let reply = """
            Here is the code you asked for:
            ```swift
            let x = 1. This line is code.
            print(x)
            ```
            And then the prose continues after the block.
            """
        let result = await run(reply, deltaSize: 7)

        #expect(result.texts == spoken(reply, deltaSize: 7))
        try #require(result.texts.count == 1)
        #expect(!result.texts[0].contains("print"))
        #expect(!result.texts[0].contains("This line is code"))
        #expect(result.texts[0].contains("And then the prose continues after the block."))
        #expect(result.outcome == .done)
        #expect(result.plays == 1)
    }

    @Test func everySpokenSegmentIsTheSegmenterOutput() async {
        let reply = """
            Here is how you do it:

            ```swift
            // Sets the value.
            let x = 1
            ```

            That prints one. Anything else?
            """
        let result = await run(reply, deltaSize: 4)

        #expect(result.texts == spoken(reply, deltaSize: 4))
        #expect(result.texts.count == 2)
        #expect(result.plays == 2)
        #expect(result.outcome == .done)
    }

    /// Nothing speakable means nothing was ever played, which is the
    /// `.fallback` contract — preserved, not introduced. A code-only reply is
    /// not this case: it still speaks the summary and settles `.done`.
    @Test func aReplyWithNothingSpeakableFallsBack() async {
        let empty = await run("😀 😀 😀", deltaSize: 2)
        #expect(empty.texts.isEmpty)
        #expect(empty.plays == 0)
        #expect(empty.outcome == .fallback)

        let codeOnly = await run("```\njust code\n```", deltaSize: 3)
        #expect(codeOnly.texts == ["code block omitted"])
        #expect(codeOnly.outcome == .done)
    }
}
