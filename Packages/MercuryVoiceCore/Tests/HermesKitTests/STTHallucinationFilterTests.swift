import Foundation
import Testing

@testable import HermesKit

/// Issue #144 item 4 (upstream e49a6afe07): direct STT configs carry
/// `stt.hallucination_filter {phrases, repeat_regex}` — the relay path's
/// `is_whisper_hallucination` (tools/voice_mode_transcript.py) shipped to the
/// client, so "Thank you." on silence is silence on both paths.
@Suite("STT hallucination filter")
struct STTHallucinationFilterTests {
    /// The shape `stt_hallucination_filter()` actually serves.
    private static let upstreamFilter: JSONValue = [
        "phrases": [
            "amara.org", "bye", "please subscribe", "thank you", "thanks for watching",
            "the end", "you", "ご視聴ありがとうございました",
        ],
        "repeat_regex": .string(#"^(?:thank you|thanks|bye|you|ok|okay|the end|[.,!\s])+$"#),
    ]

    private func filter() throws -> STTHallucinationFilter {
        try #require(STTHallucinationFilter(json: Self.upstreamFilter))
    }

    private func sttJSON(filter: JSONValue?) -> JSONValue {
        var stt: [String: JSONValue] = [
            "mode": "direct", "wire": "openai-multipart", "provider": "openai",
            "base_url": "https://api.example.com/v1", "api_key": "sk-test",
        ]
        if let filter { stt["hallucination_filter"] = filter }
        return .object(stt)
    }

    // MARK: Decoding

    @Test func directConfigDecodesTheFilter() throws {
        let config = try #require(DirectSTTConfig(json: sttJSON(filter: Self.upstreamFilter)))
        let filter = try #require(config.hallucinationFilter)
        #expect(filter.phrases.contains("thank you"))
        #expect(filter.repeatRegex != nil)
    }

    @Test func olderBackendWithoutTheFieldHasNoFilter() throws {
        let config = try #require(DirectSTTConfig(json: sttJSON(filter: nil)))
        #expect(config.hallucinationFilter == nil)
    }

    @Test func nullOrMalformedFilterIsIgnored() throws {
        for value: JSONValue in [.null, "nope", .array([])] {
            let config = try #require(DirectSTTConfig(json: sttJSON(filter: value)))
            #expect(config.hallucinationFilter == nil)
        }
    }

    // MARK: Matching — mirrors is_whisper_hallucination

    @Test(arguments: [
        "", "   ", "Thank you.", "thank you!", "THANK YOU", " Bye. ", "you",
        "Thank you. Thank you. Thank you.", "OK. OK. OK.", "okay, okay", "...",
        "ご視聴ありがとうございました",
    ])
    func silenceHallucinationsAreFiltered(transcript: String) throws {
        #expect(try filter().matches(transcript))
    }

    @Test(arguments: [
        "Thank you for the help", "stop", "hello world", "thank you so much",
        // Python strips only TRAILING '.!' before the phrase lookup.
        "thank. you",
    ])
    func realSpeechPassesThrough(transcript: String) throws {
        #expect(try !filter().matches(transcript))
    }

    @Test func invalidRegexFallsBackToPhrasesOnly() throws {
        let filter = try #require(
            STTHallucinationFilter(json: ["phrases": ["bye"], "repeat_regex": "(unclosed"]))
        #expect(filter.matches("Bye!"))
        #expect(!filter.matches("bye bye"))
    }
}
