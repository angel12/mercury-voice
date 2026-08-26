import Foundation
import Testing

@testable import HermesKit
@testable import VoiceEngine

@Suite("Sentence cutter (client-direct TTS)")
struct SentenceCutterTests {
    @Test func emitsCompleteSentencesAndHoldsTheTail() {
        let cut = SentenceCutter.cut(
            "This is the first full sentence. And here is the still-streaming ta", flush: false)
        #expect(cut.sentences == ["This is the first full sentence."])
        #expect(cut.rest == "And here is the still-streaming ta")
    }

    @Test func flushEmitsTheTail() {
        let cut = SentenceCutter.cut("A short trailing fragment", flush: true)
        #expect(cut.sentences == ["A short trailing fragment"])
        #expect(cut.rest.isEmpty)
    }

    @Test func shortFragmentsStayBufferedUntilExtended() {
        // "e.g. " style boundaries under the minimum stay buffered rather
        // than firing a provider call per abbreviation.
        let short = SentenceCutter.cut("e.g. the", flush: false)
        #expect(short.sentences.isEmpty)
        #expect(short.rest == "e.g. the")

        let extended = SentenceCutter.cut(
            "e.g. the thing that makes this long enough to speak. next", flush: false)
        #expect(extended.sentences == ["e.g. the thing that makes this long enough to speak."])
        #expect(extended.rest == "next")
    }

    @Test func questionBoundaryCutsAndShortCJKStaysBuffered() {
        // The CJK sentence is under the 24-char minimum (character count, not
        // bytes — desktop parity), so it waits for more text or the flush.
        let cut = SentenceCutter.cut(
            "Is this a complete question sentence? 这是一个足够长的中文句子。 tail", flush: false)
        #expect(cut.sentences == ["Is this a complete question sentence?"])
        #expect(cut.rest == "这是一个足够长的中文句子。 tail")

        let flushed = SentenceCutter.cut("这是一个足够长的中文句子。 tail", flush: true)
        #expect(flushed.sentences == ["这是一个足够长的中文句子。 tail"])
    }

    @Test func closingQuotesRideAlong() {
        let cut = SentenceCutter.cut(
            "He said \"this is the whole reply.\" And then the tail", flush: false)
        #expect(cut.sentences == ["He said \"this is the whole reply.\""])
    }
}

@Suite("Client-direct voice requests")
struct DirectVoiceRequestTests {
    private func json(_ string: String) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: Data(string.utf8))
    }

    private func sttConfig(wire: String, model: String? = "m1") throws -> DirectSTTConfig {
        var fields = """
            {"mode": "direct", "wire": "\(wire)", "provider": "p",
             "base_url": "https://api.example.com/v1", "api_key": "sk-test",
             "language": "en"
            """
        if let model { fields += #", "model": "\#(model)""# }
        fields += "}"
        return try #require(DirectSTTConfig(json: json(fields)))
    }

    @Test func openAIMultipartRequest() throws {
        let config = try sttConfig(wire: "openai-multipart")
        let request = DirectVoiceClient.sttRequest(
            config: config, audio: Data("AUDIO".utf8), mimeType: "audio/wav", boundary: "BND")

        #expect(request.url?.absoluteString == "https://api.example.com/v1/audio/transcriptions")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer sk-test")
        let body = String(decoding: request.httpBody ?? Data(), as: UTF8.self)
        #expect(body.contains("name=\"model\"\r\n\r\nm1"))
        #expect(body.contains("name=\"response_format\"\r\n\r\ntext"))
        #expect(body.contains("name=\"language\"\r\n\r\nen"))
        #expect(body.contains("filename=\"recording.wav\""))
        #expect(body.contains("Content-Type: audio/wav"))
        #expect(body.contains("AUDIO"))
    }

    @Test func xaiRequestSetsFormatFlagAndPath() throws {
        let config = try sttConfig(wire: "xai-stt", model: nil)
        let request = DirectVoiceClient.sttRequest(
            config: config, audio: Data("A".utf8), mimeType: "audio/wav", boundary: "BND")

        #expect(request.url?.absoluteString == "https://api.example.com/v1/stt")
        let body = String(decoding: request.httpBody ?? Data(), as: UTF8.self)
        #expect(body.contains("name=\"format\"\r\n\r\ntrue"))
        #expect(!body.contains("name=\"model\""))
    }

    @Test func elevenLabsRequestUsesXiKeyAndFieldNames() throws {
        let config = try sttConfig(wire: "elevenlabs-stt")
        let request = DirectVoiceClient.sttRequest(
            config: config, audio: Data("A".utf8), mimeType: "audio/wav", boundary: "BND")

        #expect(request.url?.absoluteString == "https://api.example.com/v1/speech-to-text")
        #expect(request.value(forHTTPHeaderField: "xi-api-key") == "sk-test")
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
        let body = String(decoding: request.httpBody ?? Data(), as: UTF8.self)
        #expect(body.contains("name=\"model_id\"\r\n\r\nm1"))
        #expect(body.contains("name=\"language_code\"\r\n\r\nen"))
    }

    @Test func sttResponseParsing() throws {
        #expect(
            DirectVoiceClient.parseSTTResponse(
                wire: .openAIMultipart, data: Data("  hello world \n".utf8)) == "hello world")
        #expect(
            DirectVoiceClient.parseSTTResponse(
                wire: .xai, data: Data(#"{"text": " hi "}"#.utf8)) == "hi")
        #expect(
            DirectVoiceClient.parseSTTResponse(wire: .elevenLabs, data: Data("junk".utf8)) == "")
    }

    @Test func openAISpeechRequest() throws {
        let config = try #require(
            DirectTTSConfig(
                json: try json(
                    """
                    {"mode": "direct", "wire": "openai-speech", "provider": "openai",
                     "base_url": "https://api.example.com/v1/", "api_key": "sk-t",
                     "model": "tts-1", "voice": "alloy", "speed": 1.2}
                    """)))
        let request = try DirectVoiceClient.ttsRequest(config: config, text: "Say this.")

        #expect(request.url?.absoluteString == "https://api.example.com/v1/audio/speech")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer sk-t")
        let body = try json(String(decoding: request.httpBody ?? Data(), as: UTF8.self))
        #expect(body["input"]?.stringValue == "Say this.")
        #expect(body["response_format"]?.stringValue == "mp3")
        #expect(body["model"]?.stringValue == "tts-1")
        #expect(body["voice"]?.stringValue == "alloy")
        #expect(body["speed"]?.doubleValue == 1.2)
    }

    @Test func elevenLabsSpeechRequestEncodesVoiceInPath() throws {
        let config = try #require(
            DirectTTSConfig(
                json: try json(
                    """
                    {"mode": "direct", "wire": "elevenlabs-tts", "provider": "elevenlabs",
                     "base_url": "https://api.eleven.io/v1", "api_key": "xi-k",
                     "model": "eleven_turbo", "voice": "Voice Id"}
                    """)))
        let request = try DirectVoiceClient.ttsRequest(config: config, text: "Hello.")

        #expect(
            request.url?.absoluteString == "https://api.eleven.io/v1/text-to-speech/Voice%20Id")
        #expect(request.value(forHTTPHeaderField: "xi-api-key") == "xi-k")
        let body = try json(String(decoding: request.httpBody ?? Data(), as: UTF8.self))
        #expect(body["text"]?.stringValue == "Hello.")
        #expect(body["model_id"]?.stringValue == "eleven_turbo")
        // No speed field on the ElevenLabs wire even when configured absent.
        #expect(body["speed"] == nil)
    }

    @Test func providerErrorDetailExtraction() {
        #expect(
            DirectVoiceClient.errorDetail(
                Data(#"{"error": {"message": "bad key"}}"#.utf8)) == "bad key")
        #expect(DirectVoiceClient.errorDetail(Data(#"{"detail": "nope"}"#.utf8)) == "nope")
        #expect(DirectVoiceClient.errorDetail(Data("plain failure".utf8)) == "plain failure")
    }

    @Test func fileNameFollowsMIME() {
        #expect(DirectVoiceClient.fileName(forMIME: "audio/wav") == "recording.wav")
        #expect(DirectVoiceClient.fileName(forMIME: "audio/mpeg") == "recording.mp3")
        #expect(DirectVoiceClient.fileName(forMIME: "audio/webm;codecs=opus") == "recording.webm")
    }
}
