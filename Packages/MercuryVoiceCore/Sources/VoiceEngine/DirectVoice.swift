import Foundation
import HermesKit

// Client-direct voice (upstream `tools/voice_client_config.py` + the desktop's
// `voice-client-direct.ts`): call the profile's own STT/TTS providers straight
// from this device, cutting the audio relay hop through the gateway. The
// gateway stays the source of truth for WHICH provider/credentials via
// `GET /api/audio/voice-config`; this file only executes the provider call.
// Keys live in memory only — never persisted, never logged.

// MARK: - Config fetch + cache

/// Per-conversation fetch/cache of the client-direct voice config. TTL'd so a
/// gateway config change propagates within a minute without a per-utterance
/// fetch; any fetch failure (older backend, transient error) reads as relay.
public actor VoiceConfigStore {
    private let rest: HermesRESTClient
    private let profile: String?
    private static let ttl: Duration = .seconds(60)

    private var cached: (config: VoiceClientConfig, at: ContinuousClock.Instant)?
    private var inflight: Task<VoiceClientConfig?, Never>?

    public init(rest: HermesRESTClient, profile: String?) {
        self.rest = rest
        self.profile = profile
    }

    public func stt() async -> DirectSTTConfig? { await config()?.stt }
    public func tts() async -> DirectTTSConfig? { await config()?.tts }

    private func config() async -> VoiceClientConfig? {
        if let cached, ContinuousClock.now - cached.at < Self.ttl {
            return cached.config
        }
        if let inflight { return await inflight.value }

        let rest = rest
        let profile = profile
        let task = Task { () -> VoiceClientConfig? in
            try? await rest.voiceConfig(profile: profile)
        }
        inflight = task
        let config = await task.value
        inflight = nil
        if let config { cached = (config, ContinuousClock.now) }
        return config
    }
}

// MARK: - Sentence cutter

/// Client-side port of the server's SentenceChunker contract (and the
/// desktop's `cutSentences`): emit complete sentences as they form, hold the
/// incomplete tail, flush everything at the end. Too-short fragments
/// ("e.g. ", "1. ") stay buffered so a provider call isn't fired per
/// abbreviation.
public enum SentenceCutter {
    static let minSentenceChars = 24
    private static let boundary = try! NSRegularExpression(
        pattern: #"[.!?…。！？]+["'”’)\]]*\s+"#)

    public static func cut(_ buffer: String, flush: Bool) -> (sentences: [String], rest: String) {
        var sentences: [String] = []
        let ns = buffer as NSString
        var start = 0
        for match in boundary.matches(in: buffer, range: NSRange(location: 0, length: ns.length)) {
            let end = match.range.location + match.range.length
            let candidate = ns.substring(with: NSRange(location: start, length: end - start))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if candidate.count >= minSentenceChars {
                sentences.append(candidate)
                start = end
            }
        }
        var rest = ns.substring(from: start)
        if flush {
            let tail = rest.trimmingCharacters(in: .whitespacesAndNewlines)
            if !tail.isEmpty { sentences.append(tail) }
            rest = ""
        }
        return (sentences, rest)
    }
}

// MARK: - Provider HTTP

public enum DirectVoiceError: Error, LocalizedError {
    /// The configured provider rejected the request. Deliberately NOT
    /// silently relayed for STT — re-running the same request through the
    /// gateway would fail the same way, slower, and hide the real error.
    case provider(name: String, status: Int, detail: String)

    public var errorDescription: String? {
        switch self {
        case .provider(let name, let status, let detail):
            return "\(name) error (HTTP \(status)): \(detail)"
        }
    }
}

/// Builds and performs the per-wire provider requests. Request construction
/// is pure static (unit-tested); only `perform` touches the network.
public struct DirectVoiceClient: Sendable {
    private let urlSession: URLSession

    public init() {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 60
        config.httpShouldSetCookies = false
        config.httpCookieAcceptPolicy = .never
        self.urlSession = URLSession(configuration: config)
    }

    // MARK: STT

    public func transcribe(
        config: DirectSTTConfig, audio: Data, mimeType: String
    ) async throws -> String {
        let boundary = "hermes-voice-\(UUID().uuidString)"
        let request = Self.sttRequest(
            config: config, audio: audio, mimeType: mimeType, boundary: boundary)
        let data = try await perform(request, provider: "\(config.provider) STT")
        return Self.parseSTTResponse(wire: config.wire, data: data)
    }

    static func sttRequest(
        config: DirectSTTConfig, audio: Data, mimeType: String, boundary: String
    ) -> URLRequest {
        var fields: [(name: String, value: String)] = []
        let path: String
        switch config.wire {
        case .openAIMultipart:
            path = "/audio/transcriptions"
            if let model = config.model { fields.append(("model", model)) }
            // Plain-text response — no JSON parse can miss the transcript.
            fields.append(("response_format", "text"))
            if let language = config.language { fields.append(("language", language)) }
        case .xai:
            path = "/stt"
            fields.append(("format", "true"))
            if let language = config.language { fields.append(("language", language)) }
        case .elevenLabs:
            path = "/speech-to-text"
            if let model = config.model { fields.append(("model_id", model)) }
            if let language = config.language { fields.append(("language_code", language)) }
        }

        var request = URLRequest(url: Self.join(config.baseURL, path))
        request.httpMethod = "POST"
        switch config.wire {
        case .openAIMultipart, .xai:
            request.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization")
        case .elevenLabs:
            request.setValue(config.apiKey, forHTTPHeaderField: "xi-api-key")
        }
        request.setValue(
            "multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = Self.multipartBody(
            boundary: boundary,
            fields: fields,
            fileField: "file",
            fileName: Self.fileName(forMIME: mimeType),
            fileMIME: mimeType,
            fileData: audio)
        return request
    }

    static func parseSTTResponse(wire: DirectSTTConfig.Wire, data: Data) -> String {
        switch wire {
        case .openAIMultipart:
            return (String(data: data, encoding: .utf8) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        case .xai, .elevenLabs:
            let json = try? JSONDecoder().decode(JSONValue.self, from: data)
            return (json?["text"]?.stringValue ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    // MARK: TTS

    /// Synthesize one sentence to audio bytes (mp3). Throws on provider
    /// rejection; the speech session decides fallback semantics.
    public func synthesize(config: DirectTTSConfig, text: String) async throws -> Data {
        let request = try Self.ttsRequest(config: config, text: text)
        return try await perform(request, provider: "\(config.provider) TTS")
    }

    static func ttsRequest(config: DirectTTSConfig, text: String) throws -> URLRequest {
        switch config.wire {
        case .openAISpeech:
            var body: [String: JSONValue] = [
                "input": .string(text),
                "response_format": .string("mp3"),
            ]
            if let model = config.model { body["model"] = .string(model) }
            if let voice = config.voice { body["voice"] = .string(voice) }
            if let speed = config.speed, speed != 1 { body["speed"] = .number(speed) }

            var request = URLRequest(url: join(config.baseURL, "/audio/speech"))
            request.httpMethod = "POST"
            request.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONEncoder().encode(JSONValue.object(body))
            return request

        case .elevenLabs:
            let voice = config.voice?.addingPercentEncoding(
                withAllowedCharacters: .urlPathAllowed) ?? ""
            var body: [String: JSONValue] = ["text": .string(text)]
            if let model = config.model { body["model_id"] = .string(model) }

            var request = URLRequest(url: join(config.baseURL, "/text-to-speech/\(voice)"))
            request.httpMethod = "POST"
            request.setValue(config.apiKey, forHTTPHeaderField: "xi-api-key")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("audio/mpeg", forHTTPHeaderField: "Accept")
            request.httpBody = try JSONEncoder().encode(JSONValue.object(body))
            return request
        }
    }

    // MARK: Plumbing

    /// Join base + path the way the desktop does (string level): a base URL
    /// like `https://api.openai.com/v1` must keep its path segment, which
    /// URL.appendingPathComponent would percent-mangle for pre-encoded parts.
    static func join(_ base: URL, _ path: String) -> URL {
        var raw = base.absoluteString
        while raw.hasSuffix("/") { raw.removeLast() }
        return URL(string: raw + path) ?? base
    }

    static func fileName(forMIME mimeType: String) -> String {
        let subtype = mimeType.split(separator: ";").first?
            .split(separator: "/").last.map(String.init)?.lowercased() ?? "wav"
        return "recording.\(subtype == "mpeg" ? "mp3" : subtype)"
    }

    static func multipartBody(
        boundary: String,
        fields: [(name: String, value: String)],
        fileField: String,
        fileName: String,
        fileMIME: String,
        fileData: Data
    ) -> Data {
        var body = Data()
        func append(_ string: String) { body.append(Data(string.utf8)) }
        for (name, value) in fields {
            append("--\(boundary)\r\n")
            append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n")
            append("\(value)\r\n")
        }
        append("--\(boundary)\r\n")
        append(
            "Content-Disposition: form-data; name=\"\(fileField)\"; filename=\"\(fileName)\"\r\n")
        append("Content-Type: \(fileMIME)\r\n\r\n")
        body.append(fileData)
        append("\r\n--\(boundary)--\r\n")
        return body
    }

    private func perform(_ request: URLRequest, provider: String) async throws -> Data {
        let (data, response) = try await urlSession.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw DirectVoiceError.provider(name: provider, status: -1, detail: "no HTTP response")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw DirectVoiceError.provider(
                name: provider, status: http.statusCode, detail: Self.errorDetail(data))
        }
        return data
    }

    /// Provider error text without dumping whole bodies (mirrors the
    /// desktop's `providerErrorText`).
    static func errorDetail(_ data: Data) -> String {
        if let json = try? JSONDecoder().decode(JSONValue.self, from: data) {
            let detail =
                json["error"]?["message"]?.stringValue
                ?? json["detail"]?.stringValue
                ?? json["error"]?.stringValue
            if let detail, !detail.isEmpty { return detail }
        }
        return String(decoding: data.prefix(300), as: UTF8.self)
    }
}

// MARK: - Direct speech session

/// The client-direct `SpeechStreaming`: sentence-cut the streaming reply
/// text, synthesize each sentence with the profile's own TTS provider, play
/// clips sequentially. Mirrors the desktop's `openClientDirectSpeechSession`
/// outcome contract: `.fallback` only when NO audio was ever produced; a
/// provider rejection after audio played settles `.done` (what played counts
/// — re-speaking from the start would stutter).
public actor DirectSpeechSession: SpeechStreaming {
    private let config: DirectTTSConfig
    private let client: DirectVoiceClient

    private var buffer = ""
    private var finished = false
    private var started = false
    private var queue: [String] = []
    private var pumping = false
    private var player: FallbackClipPlayer?
    private var outcome: SpeechStreamOutcome?
    private var waiters: [CheckedContinuation<SpeechStreamOutcome, Never>] = []

    public init(config: DirectTTSConfig, client: DirectVoiceClient = DirectVoiceClient()) {
        self.config = config
        self.client = client
    }

    public var isAudiblyPlaying: Bool { player?.isPlaying ?? false }

    // MARK: SpeechStreaming

    public func append(_ text: String) {
        guard !text.isEmpty, !finished, outcome == nil else { return }
        buffer += text
        ingest(flush: false)
    }

    public func finish() {
        guard !finished, outcome == nil else { return }
        finished = true
        ingest(flush: true)
    }

    public func waitDone() async -> SpeechStreamOutcome {
        if let outcome { return outcome }
        return await withCheckedContinuation { waiters.append($0) }
    }

    /// Barge-in / user stop: abort synthesis and playback immediately.
    public func stopNow() {
        player?.stop()
        settle(.done)
    }

    // MARK: Internals

    private func ingest(flush: Bool) {
        let cut = SentenceCutter.cut(buffer, flush: flush)
        buffer = cut.rest
        for sentence in cut.sentences {
            // Sanitize per sentence — same granularity as the server pipeline
            // (markdown constructs can span delta boundaries, sentences can't).
            let speakable = SpeechText.sanitizeForSpeech(sentence)
            if !speakable.isEmpty { queue.append(speakable) }
        }
        if !queue.isEmpty {
            pumpIfNeeded()
        } else if flush, !pumping, outcome == nil {
            settle(started ? .done : .fallback)
        }
    }

    private func pumpIfNeeded() {
        guard !pumping, outcome == nil else { return }
        pumping = true
        Task { await self.pump() }
    }

    private func pump() async {
        while outcome == nil, !queue.isEmpty {
            let sentence = queue.removeFirst()
            let bytes: Data
            do {
                bytes = try await client.synthesize(config: config, text: sentence)
            } catch {
                settle(started ? .done : .fallback)
                break
            }
            if outcome != nil { break }

            started = true
            let clip = FallbackClipPlayer()
            player = clip
            let playedThrough = await clip.play(data: bytes)
            if player === clip { player = nil }
            if !playedThrough, outcome == nil {
                // Decode/route failure mid-reply (a stop settles first and
                // never reaches here) — keep what played, don't restart.
                settle(.done)
                break
            }
        }
        pumping = false
        if outcome == nil {
            if !queue.isEmpty {
                pumpIfNeeded()  // deltas that landed while the last clip played
            } else if finished {
                settle(started ? .done : .fallback)
            }
        }
    }

    private func settle(_ result: SpeechStreamOutcome) {
        guard outcome == nil else { return }
        outcome = result
        player?.stop()
        player = nil
        buffer = ""
        queue.removeAll()
        for waiter in waiters { waiter.resume(returning: result) }
        waiters.removeAll()
    }
}
