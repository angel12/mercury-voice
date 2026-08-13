import Foundation
import HermesKit

/// The real `SpeechPlaying`: speak-stream WebSocket first, whole-clip REST
/// fallback second, with the stop/sequence protocol the engine's settle logic
/// depends on.
public actor HermesSpeechOutput: SpeechPlaying {
    private let rest: HermesRESTClient
    private let profile: String?

    private var current: SpeakStreamSession?
    private var fallback: FallbackClipPlayer?
    public private(set) var sequence = 0

    public init(rest: HermesRESTClient, profile: String?) {
        self.rest = rest
        self.profile = profile
    }

    public func startStream() async -> (any SpeechStreaming)? {
        // Contract: exactly one sequence bump per start (the engine's +1
        // accounting detects user Stops racing this setup).
        await stopPlayback()
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
        guard let clip = try? await rest.speak(text: sanitized, profile: profile),
            let data = FallbackClipPlayer.decodeDataURL(clip.dataURL)
        else { return false }

        let player = FallbackClipPlayer()
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
        if let fallback {
            self.fallback = nil
            fallback.stop()
        }
    }

    public var isSpeaking: Bool {
        get async {
            if let current, await current.isAudiblyPlaying { return true }
            return fallback?.isPlaying ?? false
        }
    }
}

/// The real `Transcribing`: `POST /api/audio/transcribe` with the
/// conversation's profile. Empty transcript = silence (success).
public struct RestTranscriber: Transcribing {
    private let rest: HermesRESTClient
    private let profile: String?

    public init(rest: HermesRESTClient, profile: String?) {
        self.rest = rest
        self.profile = profile
    }

    public func transcribe(_ utterance: RecordedUtterance) async throws -> String {
        try await rest.transcribe(
            audio: utterance.audio, mimeType: utterance.mimeType, profile: profile
        ).transcript
    }
}
