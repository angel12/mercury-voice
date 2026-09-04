import Foundation
import HermesKit

/// The real `SpeechPlaying`. Session ladder (desktop parity): client-direct
/// synthesis with the profile's own TTS (lowest hops — reply text is already
/// streaming here, audio goes provider → speaker without touching the
/// gateway link) → the gateway speak-stream WS relay → whole-clip REST
/// fallback. Stop/sequence protocol per the engine's settle logic.
public actor HermesSpeechOutput: SpeechPlaying {
    private let rest: HermesRESTClient
    private let profile: String?
    private let voiceConfig: VoiceConfigStore?
    private let synthesizeClip: @Sendable (String) async -> Data?
    private let makeFallbackPlayer: @Sendable () -> any FallbackClipPlaying

    private var current: SpeakStreamSession?
    private var currentDirect: DirectSpeechSession?
    private var fallback: (any FallbackClipPlaying)?
    public private(set) var sequence = 0

    public init(rest: HermesRESTClient, profile: String?, voiceConfig: VoiceConfigStore? = nil) {
        self.init(
            rest: rest, profile: profile, voiceConfig: voiceConfig,
            synthesize: { text in
                guard let clip = try? await rest.speak(text: text, profile: profile) else {
                    return nil
                }
                return FallbackClipPlayer.decodeDataURL(clip.dataURL)
            },
            makeFallbackPlayer: { FallbackClipPlayer() })
    }

    /// Seam init: the whole-clip synthesis request and the clip player are
    /// injectable so the fallback path can be driven without a server or an
    /// audio device (issue #34).
    init(
        rest: HermesRESTClient,
        profile: String?,
        voiceConfig: VoiceConfigStore?,
        synthesize: @escaping @Sendable (String) async -> Data?,
        makeFallbackPlayer: @escaping @Sendable () -> any FallbackClipPlaying
    ) {
        self.rest = rest
        self.profile = profile
        self.voiceConfig = voiceConfig
        self.synthesizeClip = synthesize
        self.makeFallbackPlayer = makeFallbackPlayer
    }

    public func startStream() async -> (any SpeechStreaming)? {
        // Contract: exactly one sequence bump per start (the engine's +1
        // accounting detects user Stops racing this setup).
        await stopPlayback()
        if let tts = await voiceConfig?.tts() {
            let session = DirectSpeechSession(config: tts)
            currentDirect = session
            return session
        }
        // Gated mode mints a single-use ticket per dial; a mint failure
        // falls back to the whole-clip REST path.
        guard let url = try? await rest.speakStreamURL(profile: profile) else {
            return nil
        }
        let session = SpeakStreamSession(url: url)
        await session.begin()
        current = session
        return session
    }

    public func playFallback(text: String) async -> Bool {
        // Client-side sanitization mirrors the desktop's playSpeechText; the
        // streaming path sends raw deltas because the server strips markdown
        // per sentence itself.
        let sanitized = SpeechText.sanitizeForSpeech(text)
        guard !sanitized.isEmpty else { return false }
        // The synthesis request is a suspension point the user can Stop
        // inside, and there is no player for stopPlayback to reach yet: carry
        // the sequence across the request and drop a clip that arrives after
        // a Stop rather than starting playback the user cancelled (#34).
        let generation = sequence
        guard let data = await synthesizeClip(sanitized) else { return false }
        guard sequence == generation else { return false }

        let player = makeFallbackPlayer()
        fallback = player
        let finished = await player.play(data: data)
        if fallback === player { fallback = nil }
        return finished
    }

    public func stopPlayback() async {
        sequence += 1
        if let current {
            self.current = nil
            await current.stopNow()
        }
        if let currentDirect {
            self.currentDirect = nil
            await currentDirect.stopNow()
        }
        if let fallback {
            self.fallback = nil
            fallback.stop()
        }
    }

    public var isSpeaking: Bool {
        get async {
            if let current, await current.isAudiblyPlaying { return true }
            if let currentDirect, await currentDirect.isAudiblyPlaying { return true }
            return fallback?.isPlaying ?? false
        }
    }
}

/// The real `Transcribing`: provider-direct when the gateway hands out a
/// client-callable STT config, `POST /api/audio/transcribe` relay otherwise.
/// Empty transcript = silence (success). A direct provider REJECTION throws
/// rather than silently relaying — the configured provider said no, and
/// re-running the same request through the gateway would just fail again
/// slower and hide the real error (desktop parity).
public struct RestTranscriber: Transcribing {
    private let rest: HermesRESTClient
    private let profile: String?
    private let voiceConfig: VoiceConfigStore?
    private let direct = DirectVoiceClient()

    public init(rest: HermesRESTClient, profile: String?, voiceConfig: VoiceConfigStore? = nil) {
        self.rest = rest
        self.profile = profile
        self.voiceConfig = voiceConfig
    }

    public func transcribe(_ utterance: RecordedUtterance) async throws -> String {
        if let config = await voiceConfig?.stt() {
            return try await direct.transcribe(
                config: config, audio: utterance.audio, mimeType: utterance.mimeType)
        }
        return try await rest.transcribe(
            audio: utterance.audio, mimeType: utterance.mimeType, profile: profile
        ).transcript
    }
}
