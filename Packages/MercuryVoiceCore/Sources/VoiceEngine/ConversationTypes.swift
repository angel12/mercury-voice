import Foundation

// Protocol seams for the conversation engine. The real implementations wrap
// AVFoundation + the Hermes gateway; tests inject fakes and a manual clock.

public enum ConversationStatus: String, Sendable, Equatable {
    case idle
    case listening
    case transcribing
    case thinking
    case speaking
}

public struct RecordedUtterance: Sendable, Equatable {
    public var audio: Data
    public var mimeType: String
    public var duration: Duration
    public var heardSpeech: Bool

    public init(audio: Data, mimeType: String, duration: Duration, heardSpeech: Bool) {
        self.audio = audio
        self.mimeType = mimeType
        self.duration = duration
        self.heardSpeech = heardSpeech
    }
}

public struct VADParameters: Sendable, Equatable {
    public var speechLevel: Double
    public var endOfTurnSilence: Duration
    public var idleGiveUp: Duration
    public var maxRecording: Duration

    public init(
        speechLevel: Double = VoiceConstants.speechLevel,
        endOfTurnSilence: Duration = VoiceConstants.endOfTurnSilence,
        idleGiveUp: Duration = VoiceConstants.idleGiveUp,
        maxRecording: Duration = VoiceConstants.maxRecording
    ) {
        self.speechLevel = speechLevel
        self.endOfTurnSilence = endOfTurnSilence
        self.idleGiveUp = idleGiveUp
        self.maxRecording = maxRecording
    }
}

/// The listening-phase microphone: capture + VAD endpointing.
public protocol VoiceRecording: Sendable {
    /// Begin capturing. `onAutoStop` fires once when VAD ends the turn
    /// (trailing silence after speech, or idle give-up with none). Throws when
    /// the microphone is unavailable.
    func start(vad: VADParameters, onAutoStop: @escaping @Sendable () -> Void) async throws
    /// Stop and return what was captured (nil if nothing usable).
    func stop() async -> RecordedUtterance?
    /// Discard without producing a result.
    func cancel() async
}

/// The full-duplex barge-in monitor (runs during thinking/speaking).
public protocol BargeMonitoring: Sendable {
    /// `onSpeech` fires once when sustained speech trips the monitor;
    /// `onUtterance` later delivers the endpointed capture (with pre-roll),
    /// nil when nothing usable. The monitor cleans itself up before
    /// delivering the utterance.
    func start(
        isPlaying: @escaping @Sendable () async -> Bool,
        onSpeech: @escaping @Sendable () -> Void,
        onUtterance: @escaping @Sendable (RecordedUtterance?) -> Void
    ) async throws
    func stop() async
    /// While suspended the monitor keeps its mic stream open but discards
    /// audio and resets detection — mute must not tear down the capture
    /// engine (a voice-processing unit stopping mid-TTS kills playback on
    /// macOS), it must only make the monitor deaf.
    func setSuspended(_ suspended: Bool) async
}

public protocol Transcribing: Sendable {
    /// Returns the transcript; empty string means silence (re-listen quietly).
    func transcribe(_ utterance: RecordedUtterance) async throws -> String
}

public enum SpeechStreamOutcome: Sendable, Equatable {
    case done
    /// The configured TTS provider has no chunked API — use the whole-clip
    /// fallback endpoint instead.
    case fallback
}

/// One speak-stream session (one spoken reply).
public protocol SpeechStreaming: Sendable {
    func append(_ text: String) async
    /// Send `{"done": true}` — only when the reply text is complete AND the
    /// turn is no longer busy.
    func finish() async
    /// Await the terminal outcome (stream ended + playback drained, or
    /// fallback requested before any audio).
    func waitDone() async -> SpeechStreamOutcome
}

/// Speech output owner: the streaming path, the whole-clip fallback, and the
/// stop/sequence protocol the engine uses to detect user Stops.
public protocol SpeechPlaying: Sendable {
    /// Open a streaming session. Contract (the engine's +1 accounting relies
    /// on it): this bumps `sequence` exactly once via an internal
    /// `stopPlayback`. Returns nil when streaming can't even be attempted.
    func startStream() async -> (any SpeechStreaming)?
    /// Whole-clip fallback. Does NOT stop current playback or bump
    /// `sequence` — the engine stops + captures the sequence first, so a
    /// user Stop during fallback playback is detectable.
    func playFallback(text: String) async -> Bool
    /// Stop all playback immediately. Bumps `sequence`.
    func stopPlayback() async
    /// Monotonic count of stopPlayback calls — the stop-detection protocol.
    var sequence: Int { get async }
    /// True while audio is audibly playing (barge-in trigger clamp).
    var isSpeaking: Bool { get async }
}

/// What the engine can say/see about the current spoken reply. Mirrors the
/// desktop's `collectUnspokenTurnSpeech` selector.
public struct PendingSpeech: Sendable, Equatable {
    /// Id of the first unspoken assistant bubble — stable for the turn.
    public var id: String
    /// All unspoken bubbles joined with blank lines (a sentence boundary for
    /// the server's cutter). Must grow append-only within a turn.
    public var text: String
    /// True while the last bubble is still streaming.
    public var pending: Bool

    public init(id: String, text: String, pending: Bool) {
        self.id = id
        self.text = text
        self.pending = pending
    }
}

/// The agent seam: submit/interrupt plus turn-busy and unspoken-reply state.
public protocol AgentInterfacing: Sendable {
    var isBusy: Bool { get async }
    func pendingSpeech() async -> PendingSpeech?
    /// Advance the spoken watermark past everything currently visible.
    func consumePendingSpeech() async
    func submit(text: String, interrupted: Bool) async throws
    func interrupt() async
}

/// Out-of-band signals from the engine to its owner.
public struct ConversationCallbacks: Sendable {
    public var onStopWord: @Sendable () -> Void
    public var onFatalError: @Sendable (String) -> Void
    public var onNotice: @Sendable (String) -> Void
    /// A listening turn closed with speech that is being sent for
    /// transcription (both the VAD path and the barge-in capture path).
    /// Fires before the transcript exists — silence-only turns never fire it.
    public var onTurnCaptured: @Sendable () -> Void
    /// Periodic tick while the agent is thinking (status == .thinking),
    /// every `VoiceConstants.thinkingChimeInterval`; suppressed while paused.
    public var onThinkingTick: @Sendable () -> Void
    /// Whether a mic-start failure should end the conversation (default) or
    /// park the engine paused for a later resume. iOS refuses to START audio
    /// I/O from the background or during an interruption (issue #31) — those
    /// refusals are transient, unlike a missing device or permission.
    public var micFailureIsFatal: @Sendable () async -> Bool
    /// Fired when a mic-start failure parked the engine instead of ending
    /// the conversation; the owner resumes with `setPaused(false)`.
    public var onMicParked: @Sendable () -> Void

    public init(
        onStopWord: @escaping @Sendable () -> Void = {},
        onFatalError: @escaping @Sendable (String) -> Void = { _ in },
        onNotice: @escaping @Sendable (String) -> Void = { _ in },
        onTurnCaptured: @escaping @Sendable () -> Void = {},
        onThinkingTick: @escaping @Sendable () -> Void = {},
        micFailureIsFatal: @escaping @Sendable () async -> Bool = { true },
        onMicParked: @escaping @Sendable () -> Void = {}
    ) {
        self.onStopWord = onStopWord
        self.onFatalError = onFatalError
        self.onNotice = onNotice
        self.onTurnCaptured = onTurnCaptured
        self.onThinkingTick = onThinkingTick
        self.micFailureIsFatal = micFailureIsFatal
        self.onMicParked = onMicParked
    }
}

public struct ConversationUIState: Sendable, Equatable {
    public var status: ConversationStatus
    public var enabled: Bool
    public var muted: Bool
    public var paused: Bool
    public var lastTranscript: String?

    public init(
        status: ConversationStatus = .idle,
        enabled: Bool = false,
        muted: Bool = false,
        paused: Bool = false,
        lastTranscript: String? = nil
    ) {
        self.status = status
        self.enabled = enabled
        self.muted = muted
        self.paused = paused
        self.lastTranscript = lastTranscript
    }
}
