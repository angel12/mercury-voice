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
    /// `stt.openai.timeout` — the gateway's own transcription-request
    /// deadline; nil when absent, zero, negative, or not a number (falls
    /// back to 60s at the call site, matching the desktop's
    /// `sttTimeoutSeconds`).
    public var timeoutS: Double?
    /// `stt.hallucination_filter` — the relay path's Whisper-silence filter
    /// shipped to the client; nil on older backends, which means "pass the
    /// transcript through".
    public var hallucinationFilter: STTHallucinationFilter?

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
        if let timeoutS = json["timeout_s"]?.doubleValue, timeoutS > 0 {
            self.timeoutS = timeoutS
        } else {
            self.timeoutS = nil
        }
        self.hallucinationFilter = json["hallucination_filter"].flatMap(
            STTHallucinationFilter.init(json:))
    }
}

/// Whisper commonly hallucinates "Thank you." and friends on silent audio. The
/// relay endpoint drops those server-side (`is_whisper_hallucination`,
/// tools/voice_mode_transcript.py); upstream e49a6afe07 ships the same
/// contract in voice-config so a client-direct transcript agrees with a
/// relayed one. Matching follows the Python, not the desktop TS: only
/// TRAILING `.`/`!` are stripped before the phrase lookup.
public struct STTHallucinationFilter: Sendable, Equatable {
    /// Exact known hallucinations, lowercase.
    public var phrases: Set<String>
    /// Repetitive filler ("Thank you. Thank you."), matched case-insensitively.
    /// nil when absent or not a pattern ICU compiles — phrases still apply.
    public var repeatRegex: String?

    /// nil unless `json` is an object; `{"phrases": [], ...}` still filters
    /// empty transcripts, as the relay does.
    public init?(json: JSONValue) {
        guard let object = json.objectValue else { return nil }
        let phrases = object["phrases"]?.arrayValue?.compactMap(\.stringValue) ?? []
        self.phrases = Set(phrases.map { $0.lowercased() })
        self.repeatRegex = object["repeat_regex"]?.stringValue.flatMap {
            (try? NSRegularExpression(pattern: $0)) == nil ? nil : $0
        }
    }

    /// True when `transcript` is silence or a known silence hallucination.
    public func matches(_ transcript: String) -> Bool {
        let cleaned = transcript.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if cleaned.isEmpty { return true }
        if phrases.contains(Self.droppingTrailingStops(cleaned)) { return true }
        guard let repeatRegex,
            let regex = try? NSRegularExpression(pattern: repeatRegex, options: .caseInsensitive)
        else { return false }
        let range = NSRange(cleaned.startIndex..., in: cleaned)
        return regex.firstMatch(in: cleaned, range: range) != nil
    }

    /// Python's `rstrip('.!')`.
    private static func droppingTrailingStops(_ text: String) -> String {
        var text = Substring(text)
        while let last = text.last, last == "." || last == "!" { text = text.dropLast() }
        return String(text)
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
    /// `tts.streaming.min_len` — shortest sentence (chars) the cutter emits
    /// on its own; nil when absent, zero, negative, or not a number (falls
    /// back to `SentenceCutter.minSentenceChars` at the call site).
    public var minLen: Int?
    /// `tts.openai` fields the server forwards verbatim (`lang_code`,
    /// `consent_attestation`, …) — openai-speech wire only. nil when absent
    /// or not a JSON object.
    public var extraBody: [String: JSONValue]?

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
        if let minLen = json["min_len"]?.intValue, minLen > 0 {
            self.minLen = minLen
        } else {
            self.minLen = nil
        }
        self.extraBody = json["extra_body"]?.objectValue
    }
}
