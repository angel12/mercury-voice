import Foundation

@testable import VoiceEngine

// MARK: - Manual clock

/// A manually-advanced clock so engine timers are deterministic in tests.
final class TestClock: Clock, @unchecked Sendable {
    struct Instant: InstantProtocol {
        var offset: Duration
        func advanced(by duration: Duration) -> Instant { Instant(offset: offset + duration) }
        func duration(to other: Instant) -> Duration { other.offset - offset }
        static func < (lhs: Instant, rhs: Instant) -> Bool { lhs.offset < rhs.offset }
    }

    private struct Sleeper {
        let id: UUID
        let deadline: Instant
        let continuation: CheckedContinuation<Void, any Error>
    }

    private let lock = NSLock()
    private var currentNow = Instant(offset: .zero)
    private var sleepers: [Sleeper] = []

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    var now: Instant { locked { currentNow } }
    var minimumResolution: Duration { .zero }

    /// How many tasks are currently parked in `sleep` — lets tests wait for a
    /// timer to actually arm before advancing (advancing first would leave
    /// the late sleeper with a pushed-out deadline).
    var sleeperCount: Int { locked { sleepers.count } }

    func sleep(until deadline: Instant, tolerance: Duration?) async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<Void, any Error>) in
                let immediate: Result<Void, any Error>? = locked {
                    // Cancellation can run before this continuation exists.
                    // Check under the same lock used by onCancel so it cannot
                    // slip between this check and sleeper registration.
                    if Task.isCancelled { return .failure(CancellationError()) }
                    if deadline.offset <= currentNow.offset { return .success(()) }
                    sleepers.append(
                        Sleeper(id: id, deadline: deadline, continuation: continuation))
                    return nil
                }
                if let immediate { continuation.resume(with: immediate) }
            }
        } onCancel: {
            let cancelled: Sleeper? = locked {
                guard let index = sleepers.firstIndex(where: { $0.id == id }) else {
                    return nil
                }
                return sleepers.remove(at: index)
            }
            cancelled?.continuation.resume(throwing: CancellationError())
        }
    }

    func advance(by duration: Duration) {
        let due: [Sleeper] = locked {
            currentNow = currentNow.advanced(by: duration)
            let ready = sleepers.filter { $0.deadline.offset <= currentNow.offset }
            sleepers.removeAll { $0.deadline.offset <= currentNow.offset }
            return ready
        }
        for sleeper in due { sleeper.continuation.resume() }
    }

    deinit {
        for sleeper in sleepers { sleeper.continuation.resume(throwing: CancellationError()) }
    }
}

// MARK: - Fakes

final class FakeRecorder: VoiceRecording, @unchecked Sendable {
    private let lock = NSLock()
    private var _startCount = 0
    private var _onAutoStop: (@Sendable () -> Void)?
    private var _nextResult: RecordedUtterance?
    private var _startError: (any Error)?

    private func locked<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }

    var startCount: Int { locked { _startCount } }
    var nextResult: RecordedUtterance? {
        get { locked { _nextResult } }
        set { locked { _nextResult = newValue } }
    }
    var startError: (any Error)? {
        get { locked { _startError } }
        set { locked { _startError = newValue } }
    }

    func start(vad: VADParameters, onAutoStop: @escaping @Sendable () -> Void) async throws {
        try locked {
            if let error = _startError { throw error }
            _startCount += 1
            _onAutoStop = onAutoStop
        }
    }

    func stop() async -> RecordedUtterance? {
        locked {
            _onAutoStop = nil
            return _nextResult
        }
    }

    func cancel() async {
        locked { _onAutoStop = nil }
    }

    /// Simulate the VAD ending the turn.
    func fireAutoStop() {
        let handler = locked { _onAutoStop }
        handler?()
    }
}

/// In-memory capture used with the real `BargeInMonitor` so tests can assert
/// consumer lifetime without starting `AVAudioEngine`.
final class FakeAudioCapture: AudioCaptureStreaming, @unchecked Sendable {
    private let lock = NSLock()
    private var streams: [UUID: AsyncStream<AudioChunk>.Continuation] = [:]
    private var _openCount = 0
    private var _closeCount = 0

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    var openCount: Int { locked { _openCount } }
    var closeCount: Int { locked { _closeCount } }
    var activeCount: Int { locked { streams.count } }
    /// True once a started stream has been closed (the hardware-mic analogue).
    var streamClosed: Bool { locked { _openCount > 0 && streams.isEmpty } }

    func openStream() throws -> (id: UUID, stream: AsyncStream<AudioChunk>) {
        let id = UUID()
        var continuation: AsyncStream<AudioChunk>.Continuation!
        let stream = AsyncStream<AudioChunk>(bufferingPolicy: .bufferingNewest(64)) {
            continuation = $0
        }
        locked {
            streams[id] = continuation
            _openCount += 1
        }
        return (id, stream)
    }

    func closeStream(_ id: UUID) {
        let continuation: AsyncStream<AudioChunk>.Continuation? = locked {
            _closeCount += 1
            return streams.removeValue(forKey: id)
        }
        continuation?.finish()
    }

    /// Broadcast a chunk to every open consumer, like the engine's input tap.
    func emit(_ chunk: AudioChunk) {
        let continuations: [AsyncStream<AudioChunk>.Continuation] = locked {
            Array(streams.values)
        }
        for continuation in continuations { continuation.yield(chunk) }
    }
}

final class FakeBargeMonitor: BargeMonitoring, @unchecked Sendable {
    private let lock = NSLock()
    private var _startCount = 0
    private var _stopCount = 0
    private var _suspended = false
    private var _onSpeech: (@Sendable () -> Void)?
    private var _onUtterance: (@Sendable (RecordedUtterance?) -> Void)?

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    var startCount: Int { locked { _startCount } }
    var stopCount: Int { locked { _stopCount } }
    var isActive: Bool { locked { _onSpeech != nil } }
    var isSuspended: Bool { locked { _suspended } }
    /// True after `stop()` — analogue of the capture consumer being closed.
    var streamClosed: Bool { locked { _stopCount > 0 && _onSpeech == nil } }

    func start(
        isPlaying: @escaping @Sendable () async -> Bool,
        onSpeech: @escaping @Sendable () -> Void,
        onUtterance: @escaping @Sendable (RecordedUtterance?) -> Void
    ) async throws {
        locked {
            _startCount += 1
            _suspended = false
            _onSpeech = onSpeech
            _onUtterance = onUtterance
        }
    }

    func stop() async {
        locked {
            _stopCount += 1
            _suspended = false
            _onSpeech = nil
            _onUtterance = nil
        }
    }

    func setSuspended(_ newValue: Bool) async {
        locked { _suspended = newValue }
    }

    func trip() {
        let handler = locked { _onSpeech }
        handler?()
    }

    func deliver(_ utterance: RecordedUtterance?) {
        let handler: (@Sendable (RecordedUtterance?) -> Void)? = locked {
            let handler = _onUtterance
            _onSpeech = nil
            _onUtterance = nil
            return handler
        }
        handler?(utterance)
    }
}

final class FakeTranscriber: Transcribing, @unchecked Sendable {
    private let lock = NSLock()
    private var results: [Result<String, any Error>] = []

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    func queue(_ transcript: String) {
        locked { results.append(.success(transcript)) }
    }

    func queueFailure(_ error: any Error) {
        locked { results.append(.failure(error)) }
    }

    func transcribe(_ utterance: RecordedUtterance) async throws -> String {
        let next: Result<String, any Error> = locked {
            results.isEmpty ? .success("") : results.removeFirst()
        }
        return try next.get()
    }
}

final class FakeSpeechStream: SpeechStreaming, @unchecked Sendable {
    private let lock = NSLock()
    private var _appended: [String] = []
    private var _finished = false
    private var outcome: SpeechStreamOutcome?
    private var waiters: [CheckedContinuation<SpeechStreamOutcome, Never>] = []
    /// Outcome auto-resolved when `finish()` is called (mirrors the server
    /// sending `end` after done). Set nil to control settlement manually.
    var outcomeOnFinish: SpeechStreamOutcome? = .done

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    var appended: [String] { locked { _appended } }
    var appendedText: String { appended.joined() }
    var finished: Bool { locked { _finished } }

    func append(_ text: String) async {
        locked { _appended.append(text) }
    }

    func finish() async {
        let auto: SpeechStreamOutcome? = locked {
            let already = _finished
            _finished = true
            return already ? nil : outcomeOnFinish
        }
        if let auto { settle(auto) }
    }

    func waitDone() async -> SpeechStreamOutcome {
        if let existing = locked({ outcome }) { return existing }
        return await withCheckedContinuation { continuation in
            let resolved: SpeechStreamOutcome? = locked {
                if let outcome { return outcome }
                waiters.append(continuation)
                return nil
            }
            if let resolved { continuation.resume(returning: resolved) }
        }
    }

    func settle(_ result: SpeechStreamOutcome) {
        let pending: [CheckedContinuation<SpeechStreamOutcome, Never>] = locked {
            guard outcome == nil else { return [] }
            outcome = result
            let pending = waiters
            waiters.removeAll()
            return pending
        }
        for waiter in pending { waiter.resume(returning: result) }
    }
}

final class FakeSpeech: SpeechPlaying, @unchecked Sendable {
    private let lock = NSLock()
    private var _sequence = 0
    private var _isSpeaking = false
    private var _currentStream: FakeSpeechStream?
    private var _fallbackTexts: [String] = []
    private var _streamAvailable = true
    private var _immediateFallback = false
    private var _fallbackResult = true

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    /// When false, startStream returns nil (stream unavailable).
    var streamAvailable: Bool {
        get { locked { _streamAvailable } }
        set { locked { _streamAvailable = newValue } }
    }
    /// Set to make new streams request fallback the moment they're polled.
    var immediateFallback: Bool {
        get { locked { _immediateFallback } }
        set { locked { _immediateFallback = newValue } }
    }
    var fallbackResult: Bool {
        get { locked { _fallbackResult } }
        set { locked { _fallbackResult = newValue } }
    }

    var sequence: Int {
        get async { locked { _sequence } }
    }

    var isSpeaking: Bool {
        get async { locked { _isSpeaking } }
    }

    var currentStream: FakeSpeechStream? { locked { _currentStream } }
    var fallbackTexts: [String] { locked { _fallbackTexts } }

    func setSpeaking(_ speaking: Bool) {
        locked { _isSpeaking = speaking }
    }

    func startStream() async -> (any SpeechStreaming)? {
        await stopPlayback()  // the +1 contract
        let made: (stream: FakeSpeechStream?, fallbackNow: Bool) = locked {
            guard _streamAvailable else { return (nil, false) }
            let stream = FakeSpeechStream()
            _currentStream = stream
            _isSpeaking = true
            return (stream, _immediateFallback)
        }
        guard let stream = made.stream else { return nil }
        if made.fallbackNow { stream.settle(.fallback) }
        return stream
    }

    func playFallback(text: String, expectedSequence: Int) async -> Bool {
        locked {
            _fallbackTexts.append(text)
            return _fallbackResult
        }
    }

    func stopPlayback() async {
        let stream: FakeSpeechStream? = locked {
            _sequence += 1
            _isSpeaking = false
            let stream = _currentStream
            _currentStream = nil
            return stream
        }
        stream?.settle(.done)
    }
}

final class FakeAgent: AgentInterfacing, @unchecked Sendable {
    private let lock = NSLock()
    private var _busy = false
    private var _pending: PendingSpeech?
    private var _submissions: [(text: String, interrupted: Bool)] = []
    private var _interruptCount = 0
    private var _submitError: (any Error)?
    private var _submitSetsBusy = true

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    var submitError: (any Error)? {
        get { locked { _submitError } }
        set { locked { _submitError = newValue } }
    }
    /// When true (default), submit flips busy on like the real seam.
    var submitSetsBusy: Bool {
        get { locked { _submitSetsBusy } }
        set { locked { _submitSetsBusy = newValue } }
    }

    var isBusy: Bool {
        get async { locked { _busy } }
    }

    var submissions: [(text: String, interrupted: Bool)] { locked { _submissions } }
    var interruptCount: Int { locked { _interruptCount } }

    func setBusy(_ busy: Bool) {
        locked { _busy = busy }
    }

    func setPending(_ pending: PendingSpeech?) {
        locked { _pending = pending }
    }

    func pendingSpeech() async -> PendingSpeech? {
        locked { _pending }
    }

    func consumePendingSpeech() async {
        locked { _pending = nil }
    }

    func submit(text: String, interrupted: Bool) async throws {
        let error: (any Error)? = locked {
            if let error = _submitError { return error }
            _submissions.append((text, interrupted))
            if _submitSetsBusy { _busy = true }
            return nil
        }
        if let error { throw error }
    }

    func interrupt() async {
        locked { _interruptCount += 1 }
    }
}

// MARK: - Polling helper

/// Wait (in real time) for an async condition driven by actor hops; the
/// engine's own timers run on the TestClock so this never races them.
func eventually(
    timeout: TimeInterval = 2,
    _ condition: @escaping () async -> Bool
) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return await condition()
}

func makeUtterance(heardSpeech: Bool = true) -> RecordedUtterance {
    RecordedUtterance(
        audio: Data([1, 2, 3]), mimeType: "audio/wav", duration: .seconds(1),
        heardSpeech: heardSpeech)
}

final class FakeMicrophoneAuthorizer: MicrophoneAuthorizing, @unchecked Sendable {
    private let lock = NSLock()
    private var _authorization: MicrophoneAuthorization
    private var _requestCount = 0

    init(_ authorization: MicrophoneAuthorization = .granted) {
        _authorization = authorization
    }

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    /// What the next `request()` resolves to (the "user answered the
    /// system prompt" outcome, or the already-decided state).
    var authorization: MicrophoneAuthorization {
        get { locked { _authorization } }
        set { locked { _authorization = newValue } }
    }
    var requestCount: Int { locked { _requestCount } }

    func request() async -> MicrophoneAuthorization {
        locked {
            _requestCount += 1
            return _authorization
        }
    }
}
