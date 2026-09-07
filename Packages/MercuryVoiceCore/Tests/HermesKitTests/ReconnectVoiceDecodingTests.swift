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
        #expect(!batch.isLossless(under: "abc123", forSession: "s1", after: 6))
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
        #expect(batch.isLossless(under: "abc123", forSession: "s1", after: 10))
    }

    /// Nothing missed is a perfectly good lossless answer.
    @Test func anEmptyConformingAnswerIsStillLossless() throws {
        let batch = EventReplayBatch(
            result: try json(
                #"{"events": [], "latest_seq": 10, "truncated": false, "count": 0, "epoch": "e1"}"#))
        #expect(batch.events.isEmpty)
        #expect(batch.isLossless(under: "e1", forSession: "s1", after: 10))
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
        #expect(!batch.isLossless(under: "e1", forSession: "s1", after: 4))
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
        #expect(!batch.isLossless(under: "e1", forSession: "s1", after: 4))
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
        #expect(batch.isLossless(under: "e1", forSession: "s1", after: 4))
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
        #expect(!batch.isLossless(under: "e1", forSession: "s1", after: 4))
    }

    /// No `events` array at all is an unread response, not an empty replay.
    @Test(arguments: [#"{"latest_seq": 4, "truncated": false, "epoch": "e1"}"#,
        #"{"events": {}, "latest_seq": 4, "truncated": false, "epoch": "e1"}"#])
    func absentOrNonArrayEventsIsUnusable(document: String) throws {
        let batch = EventReplayBatch(result: try json(document))
        #expect(batch.events.isEmpty)
        #expect(batch.malformed)
        #expect(!batch.isLossless(under: "e1", forSession: "s1", after: 4))
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
        #expect(!batch.isLossless(under: "e1", forSession: "s1", after: 10))
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
        #expect(!batch.isLossless(under: "e1", forSession: "s1", after: 4))
    }

    // MARK: The numbering must be the one the watermark was taken in

    /// Session-ring eviction (`event_replay.py:57–59`) drops the ring *and*
    /// the counter, so the session restarts at seq 1 with `truncated` False
    /// (there is no ring to be truncated against). `latest_seq` below the
    /// watermark — 0 for a session that has emitted nothing since — is the
    /// only trace of it, and a conforming-looking empty batch that carries it
    /// is not a "nothing was missed".
    @Test(arguments: [0, 3, 9])
    func aLatestSeqBelowTheWatermarkIsARenumberedRing(latest: Int) throws {
        let batch = EventReplayBatch(
            result: try json(
                """
                {"events": [], "latest_seq": \(latest), "truncated": false, "count": 0,
                 "epoch": "e1"}
                """))
        #expect(!batch.isLossless(under: "e1", forSession: "s1", after: 10))
    }

    /// The gateway writes `latest_seq` on every answer; without a readable
    /// one there is no evidence about the numbering at all.
    @Test(arguments: ["", #""latest_seq": null,"#, #""latest_seq": "12","#,
        #""latest_seq": 11.5,"#, #""latest_seq": 1e19,"#])
    func anAbsentOrUnreadableLatestSeqIsUnusable(fragment: String) throws {
        let batch = EventReplayBatch(
            result: try json(
                """
                {"events": [], \(fragment) "truncated": false, "count": 0, "epoch": "e1"}
                """))
        #expect(batch.latestSeq == nil)
        #expect(!batch.isLossless(under: "e1", forSession: "s1", after: 10))
    }

    /// `latest_seq` is read after the frames, so it can legitimately be
    /// *ahead* of the last one (an event stamped in between; it arrives on
    /// the live socket). Behind the last frame it cannot be: that answer did
    /// not come from one ring.
    @Test func aLatestSeqBehindTheLastFrameIsUnusable() throws {
        let batch = EventReplayBatch(
            result: try json(
                """
                {"events": [
                    {"type": "message.complete", "session_id": "s1", "seq": 11, "payload": {}},
                    {"type": "message.complete", "session_id": "s1", "seq": 12, "payload": {}}
                 ],
                 "latest_seq": 11, "truncated": false, "count": 2, "epoch": "e1"}
                """))
        #expect(!batch.isLossless(under: "e1", forSession: "s1", after: 10))
    }

    // MARK: The frames must be the whole contiguous run after the watermark

    /// The ring ascends by exactly one per session and `truncated == false`
    /// means the first frame returned is `watermark + 1`, so anything else —
    /// a hole, a repeat, a reordering, a late start, a frame at or below the
    /// watermark — is not this gateway's answer, and the batch is refused
    /// whole rather than partially applied.
    @Test(arguments: [[12, 11], [11, 13], [11, 11], [15], [10, 11], [11, 12, 14]])
    func framesMustAscendByOneFromTheWatermark(seqs: [Int]) throws {
        let frames = seqs
            .map {
                #"{"type": "message.complete", "session_id": "s1", "seq": \#($0), "payload": {}}"#
            }
            .joined(separator: ",\n")
        let batch = EventReplayBatch(
            result: try json(
                """
                {"events": [\(frames)], "latest_seq": 20, "truncated": false,
                 "count": \(seqs.count), "epoch": "e1"}
                """))
        #expect(batch.events.count == seqs.count)
        #expect(!batch.isLossless(under: "e1", forSession: "s1", after: 10))
    }

    /// A contiguous run is the answer the gateway sends, and it still
    /// replays — including when `latest_seq` has moved on ahead of it.
    @Test(arguments: [12, 13, 99])
    func aContiguousRunStillReplays(latest: Int) throws {
        let batch = EventReplayBatch(
            result: try json(
                """
                {"events": [
                    {"type": "message.complete", "session_id": "s1", "seq": 11, "payload": {}},
                    {"type": "message.delta", "session_id": "s1", "seq": 12, "payload": {}}
                 ],
                 "latest_seq": \(latest), "truncated": false, "count": 2, "epoch": "e1"}
                """))
        #expect(batch.isLossless(under: "e1", forSession: "s1", after: 10))
    }

    /// Every replayed frame is stamped (`_stamp_event`), so one whose `seq`
    /// is missing, a string, fractional, negative or out of `Int` range
    /// cannot be placed in the run — and must not be applied, since the seq
    /// gate would let it through without advancing the watermark. Reading it
    /// must not trap either: the number is server-controlled. (A magnitude
    /// beyond `Double` — `1e400` — never reaches here at all: `JSONValue`
    /// itself refuses to decode it, so the RPC result throws and the caller
    /// takes the same fallback.)
    @Test(arguments: ["", #""seq": null,"#, #""seq": "12","#, #""seq": 11.5,"#,
        #""seq": -12,"#, #""seq": 1e19,"#])
    func aFrameWithoutAnIntegerSeqIsUnusable(fragment: String) throws {
        let batch = EventReplayBatch(
            result: try json(
                """
                {"events": [
                    {"type": "message.complete", "session_id": "s1", "seq": 11, "payload": {}},
                    {"type": "message.complete", "session_id": "s1", \(fragment)
                     "payload": {}}
                 ],
                 "latest_seq": 12, "truncated": false, "count": 2, "epoch": "e1"}
                """))
        #expect(batch.events.count == 2)  // it decodes as a live frame would
        #expect(!batch.isLossless(under: "e1", forSession: "s1", after: 10))
    }

    /// A Python backend may render a whole number as a float; that is still
    /// an integer seq and still replays.
    @Test func anIntegralFloatSeqStillReplays() throws {
        let batch = EventReplayBatch(
            result: try json(
                """
                {"events": [
                    {"type": "message.complete", "session_id": "s1", "seq": 11.0, "payload": {}}
                 ],
                 "latest_seq": 11.0, "truncated": false, "count": 1, "epoch": "e1"}
                """))
        #expect(batch.events[0].seq == 11)
        #expect(batch.isLossless(under: "e1", forSession: "s1", after: 10))
    }

    /// The replay path applies its frames directly, without the `ours` filter
    /// the live socket applies, so a frame belonging to another session (or
    /// to none) would land on this conversation. `events_since` reads one
    /// session's ring and `_stamp_event` records only frames that name a
    /// session, so such a frame is not this answer.
    @Test(arguments: ["", #""session_id": null,"#, #""session_id": "s2","#,
        #""session_id": 1,"#])
    func aFrameFromAnotherSessionIsUnusable(fragment: String) throws {
        let batch = EventReplayBatch(
            result: try json(
                """
                {"events": [
                    {"type": "message.complete", \(fragment) "seq": 11, "payload": {}}
                 ],
                 "latest_seq": 11, "truncated": false, "count": 1, "epoch": "e1"}
                """))
        #expect(!batch.isLossless(under: "e1", forSession: "s1", after: 10))
    }

    /// Bounds arithmetic on server-controlled numbers must not trap. A
    /// watermark beyond anything `latest_seq` can express is refused (not
    /// incremented into an overflow), and the largest watermark a JSON answer
    /// can actually carry is still evaluated normally.
    @Test func extremeWatermarksAreRefusedRatherThanOverflowed() throws {
        // 2^63 − 1024: the largest `Int` a JSON double expresses exactly.
        let edge = 9_223_372_036_854_774_784
        let batch = EventReplayBatch(
            result: try json(
                """
                {"events": [], "latest_seq": 9223372036854774784, "truncated": false,
                 "count": 0, "epoch": "e1"}
                """))
        #expect(batch.latestSeq == edge)
        #expect(batch.isLossless(under: "e1", forSession: "s1", after: edge))
        #expect(!batch.isLossless(under: "e1", forSession: "s1", after: Int.max))
        #expect(!batch.isLossless(under: "e1", forSession: "s1", after: -1))
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
