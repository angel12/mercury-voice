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

    public func playAnnouncement(text: String, expectedSequence: Int) async -> Bool {
        await playFallback(text: text, expectedSequence: expectedSequence, isAnnouncement: true)
    }

    public func playFallback(text: String, expectedSequence: Int) async -> Bool {
        await playFallback(text: text, expectedSequence: expectedSequence, isAnnouncement: false)
    }

    private func playFallback(
        text: String, expectedSequence: Int, isAnnouncement: Bool
    ) async -> Bool {
        // Client-side sanitization mirrors the desktop's playSpeechText; the
        // streaming path sends raw deltas because the server strips markdown
        // per sentence itself.
        let sanitized = SpeechText.sanitizeForSpeech(text)
        guard !sanitized.isEmpty else { return false }
        // Caller-supplied generation, not a fresh read: a Stop can land
        // after the engine snapshots the sequence and before we enter, and
        // adopting the newer value would play a clip the user cancelled.
        // Synthesis is also a suspension with no player yet, so the same
        // value is checked again when the clip arrives (#34).
        guard sequence == expectedSequence, !isAnnouncement || !Task.isCancelled else {
            return false
        }
        guard let data = await synthesizeClip(sanitized) else { return false }
        guard sequence == expectedSequence, !isAnnouncement || !Task.isCancelled else {
            return false
        }

        let player = makeFallbackPlayer()
        fallback = player
        let playback: ClipPlayback
        if isAnnouncement {
            // Registration also handles cancellation between synthesis and this
            // handoff. Stop is synchronous and terminal on this single-use sink,
            // so cancellation before play cannot be undone by a later start.
            // Capture the local player, never the shared/newer fallback slot.
            playback = await withTaskCancellationHandler {
                await player.play(data: data)
            } onCancel: {
                player.stop()
            }
        } else {
            playback = await player.play(data: data)
        }
        if fallback === player { fallback = nil }
        return playback == .completed
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
    /// nil without a lease name: no warm-up, as before issue #146.
    private let warmup: STTWarmup?

    /// `sttLease` names this surface's `POST /api/audio/stt-lease` claim
    /// (one per conversation); the owner releases it when the conversation
    /// ends.
    public init(
        rest: HermesRESTClient, profile: String?, voiceConfig: VoiceConfigStore? = nil,
        sttLease: String? = nil
    ) {
        self.rest = rest
        self.profile = profile
        self.voiceConfig = voiceConfig
        self.warmup = sttLease.map { lease in
            STTWarmup(
                // Client-direct STT never touches the backend's model.
                shouldWarm: { await voiceConfig?.stt() == nil },
                acquire: { await rest.sttLease(lease, active: true, profile: profile) })
        }
    }

    public func prepare() async {
        await warmup?.start()
    }

    public func transcribe(_ utterance: RecordedUtterance) async throws -> String {
        if let config = await voiceConfig?.stt() {
            return try await direct.transcribe(
                config: config, audio: utterance.audio, mimeType: utterance.mimeType)
        }
        // Send the audio only once the model is warm, so a cold load is not
        // charged to the transcribe request's timeout. Bounded by the
        // acquire's own 180 s budget; a failed or unsupported acquire simply
        // settles and transcription proceeds.
        await warmup?.ready()
        return try await rest.transcribe(
            audio: utterance.audio, mimeType: utterance.mimeType, profile: profile
        ).transcript
    }
}

/// Warm-up for the backend's local STT model (issue #146, upstream
/// `tools/stt_lease.py`). `start` runs at every listen start — idle-unload
/// can evict the model between turns — and joins a warm-up still in flight
/// rather than stacking another; `ready` waits for the current one to settle.
actor STTWarmup {
    private let shouldWarm: @Sendable () async -> Bool
    private let acquire: @Sendable () async -> Void
    private var inFlight: Task<Void, Never>?
    private var generation = 0

    init(
        shouldWarm: @escaping @Sendable () async -> Bool,
        acquire: @escaping @Sendable () async -> Void
    ) {
        self.shouldWarm = shouldWarm
        self.acquire = acquire
    }

    func start() {
        guard inFlight == nil else { return }
        generation += 1
        let generation = generation
        let shouldWarm = shouldWarm
        let acquire = acquire
        inFlight = Task {
            if await shouldWarm() { await acquire() }
            self.settled(generation)
        }
    }

    func ready() async {
        await inFlight?.value
    }

    private func settled(_ generation: Int) {
        if generation == self.generation { inFlight = nil }
    }
}
