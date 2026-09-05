import Foundation

/// Both directions need HTTP URLs; relative or non-network URLs must relay.
private func directVoiceBaseURL(_ raw: String) -> URL? {
    guard let url = URL(string: raw),
        let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme),
        let host = url.host, !host.isEmpty
    else { return nil }
    return url
}

/// The active profile's STT/TTS resolution for CLIENT-DIRECT voice, from
/// `GET /api/audio/voice-config` (upstream `tools/voice_client_config.py`).
///
/// A direction is `nil` when the gateway answered `{"mode": "relay"}` (host-
/// only provider, missing credentials, `voice.client_direct` disabled) or with
/// a wire shape this app doesn't speak — the caller keeps using the
/// `/api/audio/*` relay endpoints, which remain the floor, not an error.
///
/// The embedded API keys live in memory only: never persist, never log.
public struct VoiceClientConfig: Sendable, Equatable {
    public var stt: DirectSTTConfig?
    public var tts: DirectTTSConfig?

    public init(json: JSONValue) {
        self.stt = (json["stt"]).flatMap(DirectSTTConfig.init(json:))
        self.tts = (json["tts"]).flatMap(DirectTTSConfig.init(json:))
    }

    public init(stt: DirectSTTConfig?, tts: DirectTTSConfig?) {
        self.stt = stt
        self.tts = tts
    }
}

/// One transcription request, provider-direct.
public struct DirectSTTConfig: Sendable, Equatable {
    public enum Wire: String, Sendable {
        /// `POST {base}/audio/transcriptions`, multipart, Bearer — OpenAI and
        /// compatibles (groq/mistral/deepinfra); requests plain text, but
        /// also accepts JSON `{text}` from providers ignoring that format.
        case openAIMultipart = "openai-multipart"
        /// `POST {base}/stt`, multipart + `format=true`, Bearer → `{text}`.
        case xai = "xai-stt"
        /// `POST {base}/speech-to-text`, multipart, `xi-api-key` → `{text}`.
        case elevenLabs = "elevenlabs-stt"
    }

    public var wire: Wire
    public var provider: String
    public var baseURL: URL
    public var apiKey: String
    public var model: String?
    public var language: String?

    /// nil for relay verdicts, unknown wires, or malformed configs — all of
    /// which mean "use the relay endpoint".
    public init?(json: JSONValue) {
        guard json["mode"]?.stringValue == "direct",
            let wire = json["wire"]?.stringValue.flatMap(Wire.init(rawValue:)),
            let base = json["base_url"]?.stringValue,
            let baseURL = directVoiceBaseURL(base),
            let apiKey = json["api_key"]?.stringValue, !apiKey.isEmpty
        else { return nil }
        self.wire = wire
        self.provider = json["provider"]?.stringValue ?? wire.rawValue
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.model = json["model"]?.stringValue
        self.language = json["language"]?.stringValue
    }
}

/// One synthesis request, provider-direct. Whole-clip per sentence (mp3);
/// sentence cutting happens client-side, mirroring the server pipeline.
public struct DirectTTSConfig: Sendable, Equatable {
    public enum Wire: String, Sendable {
        /// `POST {base}/audio/speech`, JSON, Bearer → mp3 bytes.
        case openAISpeech = "openai-speech"
        /// `POST {base}/text-to-speech/{voice}`, JSON, `xi-api-key` → mp3.
        case elevenLabs = "elevenlabs-tts"
    }

    public var wire: Wire
    public var provider: String
    public var baseURL: URL
    public var apiKey: String
    public var model: String?
    public var voice: String?
    public var speed: Double?

    public init?(json: JSONValue) {
        guard json["mode"]?.stringValue == "direct",
            let wire = json["wire"]?.stringValue.flatMap(Wire.init(rawValue:)),
            let base = json["base_url"]?.stringValue,
            let baseURL = directVoiceBaseURL(base),
            let apiKey = json["api_key"]?.stringValue, !apiKey.isEmpty
        else { return nil }
        self.wire = wire
        self.provider = json["provider"]?.stringValue ?? wire.rawValue
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.model = json["model"]?.stringValue
        self.voice = json["voice"]?.stringValue
        self.speed = json["speed"]?.doubleValue
    }
}
