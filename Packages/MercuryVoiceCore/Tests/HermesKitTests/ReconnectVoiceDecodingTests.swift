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

    @Test func missingKeyOrBadURLReadsAsRelay() throws {
        let noKey = DirectSTTConfig(
            json: try json(
                #"{"mode": "direct", "wire": "xai-stt", "base_url": "https://x.ai", "api_key": ""}"#
            ))
        #expect(noKey == nil)
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

        #expect(batch.events.count == 2)  // the typeless frame is dropped
        #expect(batch.events[0].type == "message.delta")
        #expect(batch.events[0].seq == 7)
        #expect(batch.events[0].sessionID == "s1")
        #expect(batch.events[1].payload["text"]?.stringValue == "hello")
        #expect(batch.latestSeq == 8)
        #expect(batch.truncated == false)
        #expect(batch.epoch == "abc123")
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
