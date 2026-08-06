import Foundation

/// Tuning constants for the voice pipeline. Values mirror the desktop client
/// (use-voice-conversation.ts, use-mic-recorder.ts, voice-barge-in.ts,
/// voice-playback.ts) — change them together with the reference or not at all.
public enum VoiceConstants {
    // MARK: Listening / VAD (use-voice-conversation.ts)

    /// Normalized level at/above which a sample counts as speech.
    public static let speechLevel: Double = 0.075
    /// Trailing silence after speech that ends the turn.
    public static let endOfTurnSilence: Duration = .milliseconds(1250)
    /// Give-up when no speech was ever heard.
    public static let idleGiveUp: Duration = .seconds(12)
    /// Hard cap on a listening turn.
    public static let turnHardCap: Duration = .seconds(60)
    /// Absolute recording ceiling.
    public static let maxRecording: Duration = .seconds(120)

    /// The desktop computes RMS over 8-bit-centered samples and normalizes
    /// with `min(1, rms / 42)`. Over float samples in [-1, 1] the equivalent
    /// divisor is 42/128.
    public static let rmsNormalizationDivisor: Double = 42.0 / 128.0
    /// RMS hop ~50 ms (the desktop is rAF-driven; a fixed hop is steadier).
    public static let levelHop: Duration = .milliseconds(50)

    // MARK: Turn orchestration (use-voice-conversation.ts)

    /// Cadence for feeding accumulated reply text into the speak-stream.
    public static let speechFeedInterval: Duration = .milliseconds(150)
    /// Poll cadence while waiting for the fallback reply text to finish.
    public static let fallbackPollInterval: Duration = .milliseconds(250)
    /// After a barge-in, wait up to this long for the interrupted turn to
    /// settle (busy to clear) before submitting; polls every 100 ms and
    /// submits anyway at the deadline.
    public static let interruptSettleTimeout: Duration = .seconds(5)
    public static let interruptSettlePoll: Duration = .milliseconds(100)
    /// A barge-in latch older than this no longer marks the next submit as
    /// `interrupted`.
    public static let interruptedLatchTTL: Duration = .seconds(120)

    // MARK: Barge-in monitor (voice-barge-in.ts)

    public static let bargeCalibration: Duration = .milliseconds(400)
    public static let bargeSustainedWindow: Duration = .milliseconds(300)
    public static let bargeSustainedMajority: Double = 0.8
    public static let bargeMinTriggerLevel: Double = 0.075
    public static let bargeFloorMultiplier: Double = 3.5
    /// While TTS is audibly playing, the trigger clamps into this band.
    public static let bargePlaybackMinTrigger: Double = 0.14
    public static let bargeTriggerCeiling: Double = 0.37
    /// Ignore the onset transient right after playback starts.
    public static let bargePlaybackGrace: Duration = .milliseconds(500)
    /// A playback gap must exceed this before a new grace window is armed
    /// (prevents inter-sentence flapping from chaining grace windows).
    public static let bargePlaybackGapForGrace: Duration = .seconds(1)
    /// Noise-floor median over at most this many quiet samples.
    public static let bargeFloorSampleCap = 200
    /// Pre-roll segment rotation while quiet, so the first syllable survives.
    public static let bargePreRollRestart: Duration = .seconds(5)
    /// Post-trip endpointing: trailing silence / hard cap.
    public static let bargeUtteranceSilence: Duration = .milliseconds(1250)
    public static let bargeUtteranceMax: Duration = .seconds(30)

    // MARK: Playback (voice-playback.ts)

    public static let defaultTTSSampleRate: Double = 24000
    /// Scheduling lead for the first PCM chunk after a gap.
    public static let playbackLead: TimeInterval = 0.05
    /// Extra pad after the scheduled tail before declaring speech done.
    public static let playbackDrainPad: Duration = .milliseconds(100)
    public static let fallbackStallTimeout: Duration = .seconds(15)
}
