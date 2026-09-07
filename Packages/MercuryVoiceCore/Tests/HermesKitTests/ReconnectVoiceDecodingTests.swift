import Foundation
import Testing

@testable import HermesKit

@Suite("Voice-config decoding (client-direct)")
struct VoiceClientConfigDecodingTests {
    private func json(_ string: String) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: Data(string.utf8))
    }

    @Test func decodesDirectBothWays() throws {
        let config = VoiceClientConfig(
            json: try json(
                """
                {"ok": true,
                 "stt": {"mode": "direct", "wire": "openai-multipart", "provider": "groq",
                          "base_url": "https://api.groq.com/openai/v1", "api_key": "k1",
                          "model": "whisper-large-v3", "language": "en"},
                 "tts": {"mode": "direct", "wire": "elevenlabs-tts", "provider": "elevenlabs",
                          "base_url": "https://api.elevenlabs.io/v1", "api_key": "k2",
                          "model": "eleven_turbo_v2", "voice": "abc", "speed": null}}
                """))

        #expect(config.stt?.wire == .openAIMultipart)
        #expect(config.stt?.provider == "groq")
        #expect(config.stt?.model == "whisper-large-v3")
        #expect(config.tts?.wire == .elevenLabs)
        #expect(config.tts?.voice == "abc")
        #expect(config.tts?.speed == nil)
    }

    @Test func relayVerdictsAndUnknownWiresReadAsRelay() throws {
        let config = VoiceClientConfig(
            json: try json(
                """
                {"stt": {"mode": "relay", "reason": "local provider"},
                 "tts": {"mode": "direct", "wire": "future-wire-2027",
                          "base_url": "https://x.example", "api_key": "k"}}
                """))
        #expect(config.stt == nil)
        #expect(config.tts == nil)
    }

    @Test func missingKeyReadsAsRelay() throws {
        let noKey = DirectSTTConfig(
            json: try json(
                #"{"mode": "direct", "wire": "xai-stt", "base_url": "https://x.ai", "api_key": ""}"#
            ))
        #expect(noKey == nil)
    }

    @Test(arguments: ["not-a-url", "", "https:///", "file:///tmp/audio", "ftp://example.com"])
    func invalidProviderURLReadsAsRelay(base: String) {
        let fields: [String: JSONValue] = [
            "mode": "direct", "base_url": .string(base), "api_key": "test-key",
        ]
        var stt = fields
        stt["wire"] = "openai-multipart"
        var tts = fields
        tts["wire"] = "openai-speech"
        #expect(DirectSTTConfig(json: .object(stt)) == nil)
        #expect(DirectTTSConfig(json: .object(tts)) == nil)
    }

    @Test(arguments: ["http://127.0.0.1:8080/v1", "https://example.com/v1"])
    func absoluteHTTPProviderURLsRemainDirect(base: String) {
        let fields: [String: JSONValue] = [
            "mode": "direct", "base_url": .string(base), "api_key": "test-key",
        ]
        var stt = fields
        stt["wire"] = "openai-multipart"
        var tts = fields
        tts["wire"] = "openai-speech"
        #expect(DirectSTTConfig(json: .object(stt)) != nil)
        #expect(DirectTTSConfig(json: .object(tts)) != nil)
    }
}

@Suite("Event replay decoding (reconnect contract)")
struct EventReplayDecodingTests {
    private func json(_ string: String) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: Data(string.utf8))
    }

    @Test func decodesSeqStampedFrames() throws {
        let batch = EventReplayBatch(
            result: try json(
                """
                {"events": [
                    {"type": "message.delta", "session_id": "s1", "seq": 7,
                     "payload": {"text": "hel"}},
                    {"type": "message.complete", "session_id": "s1", "seq": 8,
                     "payload": {"text": "hello", "status": "complete"}},
                    {"payload": {"orphan": true}}
                 ],
                 "latest_seq": 8, "truncated": false, "count": 2, "epoch": "abc123"}
                """))

        #expect(batch.events.count == 2)  // the typeless frame does not decode
        #expect(batch.events[0].type == "message.delta")
        #expect(batch.events[0].seq == 7)
        #expect(batch.events[0].sessionID == "s1")
        #expect(batch.events[1].payload["text"]?.stringValue == "hello")
        #expect(batch.latestSeq == 8)
        #expect(batch.truncated == false)
        #expect(batch.epoch == "abc123")
        // …and the frames that did decode are not the whole answer, so this
        // response cannot be replayed as one.
        #expect(batch.malformed)
        #expect(!batch.isLossless(under: "abc123"))
    }

    /// The shape the gateway actually answers with — `methods_session.py`
    /// writes events/latest_seq/truncated/count/epoch on every reply.
    @Test func aConformingAnswerReplaysLosslessly() throws {
        let batch = EventReplayBatch(
            result: try json(
                """
                {"events": [
                    {"type": "message.complete", "session_id": "s1", "seq": 11,
                     "payload": {"text": "hello"}}
                 ],
                 "latest_seq": 11, "truncated": false, "count": 1, "epoch": "abc123"}
                """))
        #expect(batch.events.count == 1)
        #expect(batch.isLossless(under: "abc123"))
    }

    /// Nothing missed is a perfectly good lossless answer.
    @Test func anEmptyConformingAnswerIsStillLossless() throws {
        let batch = EventReplayBatch(
            result: try json(
                #"{"events": [], "latest_seq": 10, "truncated": false, "count": 0, "epoch": "e1"}"#))
        #expect(batch.events.isEmpty)
        #expect(batch.isLossless(under: "e1"))
    }

    // MARK: Fail-closed decoding (issue #58, finding R05)

    /// `truncated` is the gateway's answer to "did the ring drop frames you
    /// asked for", and every gateway that serves the method writes it. A
    /// response that does not answer it has not said "no gap" — reading the
    /// absence as `false` is what let an unreadable reply pass as a lossless
    /// replay.
    @Test func aMissingTruncatedFlagReadsAsAGap() throws {
        let batch = EventReplayBatch(
            result: try json(#"{"events": [], "latest_seq": 4, "count": 0, "epoch": "e1"}"#))
        #expect(batch.truncated)
        #expect(!batch.isLossless(under: "e1"))
    }

    @Test(arguments: ["\"maybe\"", "null", "{}", "[]", "2"])
    func anUnreadableTruncatedFlagReadsAsAGap(literal: String) throws {
        let batch = EventReplayBatch(
            result: try json(
                """
                {"events": [], "latest_seq": 4, "count": 0, "epoch": "e1",
                 "truncated": \(literal)}
                """))
        #expect(batch.truncated)
        #expect(!batch.isLossless(under: "e1"))
    }

    /// Fail-closed is for answers that cannot be read, not for ones a Python
    /// backend spells loosely: `0`/`"false"` still mean false.
    @Test(arguments: ["false", "0", "\"false\""])
    func looseFalseTruncatedFlagsStillDecode(literal: String) throws {
        let batch = EventReplayBatch(
            result: try json(
                """
                {"events": [], "latest_seq": 4, "count": 0, "epoch": "e1",
                 "truncated": \(literal)}
                """))
        #expect(!batch.truncated)
        #expect(batch.isLossless(under: "e1"))
    }

    @Test(arguments: ["true", "1", "\"true\""])
    func looseTrueTruncatedFlagsStillDecode(literal: String) throws {
        let batch = EventReplayBatch(
            result: try json(
                """
                {"events": [], "latest_seq": 4, "count": 0, "epoch": "e1",
                 "truncated": \(literal)}
                """))
        #expect(batch.truncated)
        #expect(!batch.isLossless(under: "e1"))
    }

    /// No `events` array at all is an unread response, not an empty replay.
    @Test(arguments: [#"{"latest_seq": 4, "truncated": false, "epoch": "e1"}"#,
        #"{"events": {}, "latest_seq": 4, "truncated": false, "epoch": "e1"}"#])
    func absentOrNonArrayEventsIsUnusable(document: String) throws {
        let batch = EventReplayBatch(result: try json(document))
        #expect(batch.events.isEmpty)
        #expect(batch.malformed)
        #expect(!batch.isLossless(under: "e1"))
    }

    /// `count` is the gateway's own tally of the frames it put in `events`,
    /// so a disagreement means the batch in hand is not the batch sent.
    @Test(arguments: ["5", "\"1\"", "null"])
    func aCountDisagreeingWithTheFramesIsUnusable(literal: String) throws {
        let batch = EventReplayBatch(
            result: try json(
                """
                {"events": [
                    {"type": "message.complete", "session_id": "s1", "seq": 11, "payload": {}}
                 ],
                 "latest_seq": 11, "truncated": false, "count": \(literal), "epoch": "e1"}
                """))
        #expect(batch.events.count == 1)
        #expect(batch.malformed)
        #expect(!batch.isLossless(under: "e1"))
    }

    /// `epoch` is the identity of the numbering the watermark was taken
    /// under, and it has been echoed by this method since the same commit
    /// that first advertised `replay_epoch` at `gateway.ready` — so a caller
    /// that knows an epoch is talking to a gateway that sends one back, and
    /// an answer without it cannot be shown to be about the same numbering.
    @Test(arguments: ["", #""epoch": null,"#, #""epoch": 7,"#, #""epoch": "e2","#])
    func anEpochThatIsNotTheWatermarksIsNotAContinuation(fragment: String) throws {
        let batch = EventReplayBatch(
            result: try json(
                """
                {"events": [], "latest_seq": 4, "truncated": false, "count": 0, \(fragment)
                 "session_id": "s1"}
                """))
        #expect(!batch.isLossless(under: "e1"))
    }

    @Test func truncatedBatchSurvivesMissingFields() throws {
        let batch = EventReplayBatch(result: try json(#"{"truncated": true}"#))
        #expect(batch.events.isEmpty)
        #expect(batch.truncated)
        #expect(batch.latestSeq == nil)
        #expect(batch.epoch == nil)
    }

    @Test func liveFrameParamsCarrySeq() throws {
        let event = GatewayEvent(
            eventParams: try json(
                #"{"type": "thinking.delta", "session_id": "s9", "seq": 41, "payload": {}}"#))
        #expect(event?.seq == 41)
        #expect(event?.sessionID == "s9")

        // Old backends stamp nothing — seq stays nil, decoding still works.
        let legacy = GatewayEvent(
            eventParams: try json(#"{"type": "message.start", "session_id": "s9"}"#))
        #expect(legacy?.seq == nil)
    }
}
