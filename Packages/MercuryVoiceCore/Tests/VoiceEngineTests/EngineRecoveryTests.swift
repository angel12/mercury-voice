import Foundation
import HermesKit
import Testing

@testable import VoiceEngine

// MARK: - Support

/// A queue-backed transcriber whose next call can be gated open, giving tests
/// a deterministic `.transcribing` window to land a Stop in (issue #5). With
/// the gate unarmed it behaves like FakeTranscriber.
final class GatedTranscriber: Transcribing, @unchecked Sendable {
    private let lock = NSLock()
    private var results: [Result<String, any Error>] = []
    private var gateArmed = false
    private var released = false
    private var waiter: CheckedContinuation<Void, Never>?

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

    /// The next transcribe() parks until `release()`.
    func armGate() {
        locked {
            gateArmed = true
            released = false
        }
    }

    func release() {
        let parked: CheckedContinuation<Void, Never>? = locked {
            released = true
            let parked = waiter
            waiter = nil
            return parked
        }
        parked?.resume()
    }

    func transcribe(_ utterance: RecordedUtterance) async throws -> String {
        let mustWait: Bool = locked {
            guard gateArmed else { return false }
            gateArmed = false
            return !released
        }
        if mustWait {
            await withCheckedContinuation { continuation in
                let resumeNow: Bool = locked {
                    if released { return true }
                    waiter = continuation
                    return false
                }
                if resumeNow { continuation.resume() }
            }
        }
        let next: Result<String, any Error> = locked {
            results.isEmpty ? .success("") : results.removeFirst()
        }
        return try next.get()
    }
}

final class NoticeBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _list: [String] = []
    var list: [String] {
        lock.lock()
        defer { lock.unlock() }
        return _list
    }
    func append(_ notice: String) {
        lock.lock()
        _list.append(notice)
        lock.unlock()
    }
}

private enum TestError: Error { case boom }

/// Like ConversationEngineTests.Harness, plus notice capture and the gated
/// transcriber — the pieces the recovery-path tests need.
private struct RecoveryHarness {
    let engine: ConversationEngine<TestClock>
    let clock: TestClock
    let recorder: FakeRecorder
    let barge: FakeBargeMonitor
    let transcriber: GatedTranscriber
    let speech: FakeSpeech
    let agent: FakeAgent
    let notices: NoticeBox

    init() {
        let clock = TestClock()
        let recorder = FakeRecorder()
        let barge = FakeBargeMonitor()
        let transcriber = GatedTranscriber()
        let speech = FakeSpeech()
        let agent = FakeAgent()
        let notices = NoticeBox()
        self.clock = clock
        self.recorder = recorder
        self.barge = barge
        self.transcriber = transcriber
        self.speech = speech
        self.agent = agent
        self.notices = notices
        self.engine = ConversationEngine(
            recorder: recorder,
            bargeMonitor: barge,
            transcriber: transcriber,
            speech: speech,
            agent: agent,
            callbacks: ConversationCallbacks(onNotice: { notices.append($0) }),
            clock: clock)
    }

    func status(is expected: ConversationStatus) async -> Bool {
        await eventually { await engine.status == expected }
    }

    func enterThinking(transcript: String = "hello there") async {
        recorder.nextResult = makeUtterance()
        transcriber.queue(transcript)
        await engine.start()
        #expect(await status(is: .listening))
        recorder.fireAutoStop()
        #expect(await status(is: .thinking))
    }
}

// MARK: - Failure recovery (issue #11)

/// The recovery paths the fakes were built for but never exercised: submit
/// failure, STT failure, stream-unavailable fallback, and fallback failure.
@Suite("Engine failure recovery")
struct EngineRecoveryTests {
    @Test func submitFailureNoticesAndRearms() async {
        let h = RecoveryHarness()
        h.agent.submitError = TestError.boom
        h.recorder.nextResult = makeUtterance()
        h.transcriber.queue("hello there")
        await h.engine.start()
        #expect(await h.status(is: .listening))
        h.recorder.fireAutoStop()

        #expect(await eventually { h.notices.list.contains { $0.hasPrefix("Send failed") } })
        #expect(h.agent.submissions.isEmpty)
        // Send failures re-arm: the user should get to just say it again.
        #expect(await h.status(is: .listening))
        #expect(await eventually { h.recorder.startCount == 2 })
    }

    @Test func transcriptionFailureNoticesAndRearms() async {
        let h = RecoveryHarness()
        h.recorder.nextResult = makeUtterance()
        h.transcriber.queueFailure(TestError.boom)
        await h.engine.start()
        #expect(await h.status(is: .listening))
        h.recorder.fireAutoStop()

        #expect(
            await eventually { h.notices.list.contains { $0.hasPrefix("Transcription failed") } })
        #expect(h.agent.submissions.isEmpty)
        #expect(await h.status(is: .listening))
        #expect(await eventually { h.recorder.startCount == 2 })
    }

    @Test func streamUnavailableFallsBackToWholeClip() async {
        let h = RecoveryHarness()
        await h.enterThinking()
        // A stream that can't open (e.g. the ticket mint failed) must reroute
        // to the whole-clip path, not settle as if the user pressed Stop —
        // startStream's own stopPlayback bumps the sequence once even on
        // failure, and that contract bump is not a Stop.
        h.speech.streamAvailable = false
        h.agent.setPending(PendingSpeech(id: "0", text: "Hi there.", pending: false))
        h.agent.setBusy(false)
        await h.engine.agentStateChanged()

        #expect(await eventually { h.speech.fallbackTexts == ["Hi there."] })
        // The reply was spoken (via fallback), so the loop re-arms.
        #expect(await h.status(is: .listening))
        #expect(await eventually { h.recorder.startCount == 2 })
    }

    @Test func fallbackFailureStillSettlesAndRearms() async {
        let h = RecoveryHarness()
        await h.enterThinking()
        h.speech.streamAvailable = false
        h.speech.fallbackResult = false
        h.agent.setPending(PendingSpeech(id: "0", text: "Hi there.", pending: false))
        h.agent.setBusy(false)
        await h.engine.agentStateChanged()

        // The clip failing to play is swallowed (current contract: the reply
        // text is still on screen); the loop must settle and re-arm rather
        // than hang in .speaking.
        #expect(await eventually { h.speech.fallbackTexts == ["Hi there."] })
        #expect(await h.status(is: .listening))
        #expect(await eventually { h.recorder.startCount == 2 })
    }

    @Test func streamFallbackOutcomeReroutesToClip() async {
        let h = RecoveryHarness()
        await h.enterThinking()
        h.agent.setPending(PendingSpeech(id: "0", text: "Hi! ", pending: true))
        await h.engine.agentStateChanged()
        #expect(await h.status(is: .speaking))
        #expect(await eventually { h.speech.currentStream != nil })
        let stream = h.speech.currentStream!
        // The server answers the stream's done with a fallback demand.
        stream.outcomeOnFinish = .fallback

        h.agent.setPending(PendingSpeech(id: "0", text: "Hi! All done.", pending: false))
        h.agent.setBusy(false)
        await h.engine.agentStateChanged()
        h.clock.advance(by: .milliseconds(150))
        #expect(await eventually { stream.finished })

        // The whole reply replays through the clip path, then the mic re-arms.
        #expect(await eventually { h.speech.fallbackTexts == ["Hi! All done."] })
        #expect(await h.status(is: .listening))
    }
}

// MARK: - Stop during turn close (issue #5)

@Suite("Stop during turn close")
struct StopDuringTurnCloseTests {
    @Test func stopDuringTranscribingDropsTheTurn() async {
        let h = RecoveryHarness()
        h.recorder.nextResult = makeUtterance()
        h.transcriber.armGate()
        h.transcriber.queue("hello there")
        await h.engine.start()
        #expect(await h.status(is: .listening))
        h.recorder.fireAutoStop()
        #expect(await h.status(is: .transcribing))

        // Stop lands in the STT window; the transcript arrives after.
        await h.engine.stopSpeech()
        h.transcriber.release()

        #expect(await h.status(is: .idle))
        try? await Task.sleep(for: .milliseconds(100))
        #expect(h.agent.submissions.isEmpty)  // the pending transcript was dropped
        #expect(h.recorder.startCount == 1)  // and the mic did not re-arm

        // listenNow is the documented way back.
        await h.engine.listenNow()
        #expect(await h.status(is: .listening))
        #expect(h.recorder.startCount == 2)
    }

    @Test func stopDuringTranscribingSuppressesFailureNoticeAndRearm() async {
        let h = RecoveryHarness()
        h.recorder.nextResult = makeUtterance()
        h.transcriber.armGate()
        h.transcriber.queueFailure(TestError.boom)
        await h.engine.start()
        #expect(await h.status(is: .listening))
        h.recorder.fireAutoStop()
        #expect(await h.status(is: .transcribing))

        await h.engine.stopSpeech()
        h.transcriber.release()

        #expect(await h.status(is: .idle))
        try? await Task.sleep(for: .milliseconds(100))
        // The turn was voided by the Stop — the failure of a transcript that
        // was going to be dropped is not news, and must not re-arm.
        #expect(h.notices.list.isEmpty)
        #expect(h.recorder.startCount == 1)
    }

    @Test func stopDuringBargeCaptureTranscriptionDropsTheTurn() async {
        let h = RecoveryHarness()
        await h.enterThinking()
        h.agent.setPending(PendingSpeech(id: "0", text: "reply text", pending: true))
        await h.engine.agentStateChanged()
        #expect(await h.status(is: .speaking))
        #expect(await eventually { h.barge.isActive })

        h.barge.trip()
        #expect(await eventually { h.agent.interruptCount == 1 })
        h.agent.setBusy(false)
        h.transcriber.armGate()
        h.transcriber.queue("wait actually can you")
        h.barge.deliver(makeUtterance())
        #expect(await h.status(is: .transcribing))

        await h.engine.stopSpeech()
        h.transcriber.release()

        #expect(await h.status(is: .idle))
        try? await Task.sleep(for: .milliseconds(100))
        #expect(h.agent.submissions.count == 1)  // only the original turn
        #expect(h.recorder.startCount == 1)  // no re-arm after the Stop
    }
}

// MARK: - Stop during the whole-clip fallback wait (issue #34)

@Suite("Stop during fallback speech")
struct StopDuringFallbackTests {
    /// The poll that waits for the reply text to finish must not absorb a
    /// Stop. The old code re-captured the sequence baseline immediately
    /// before playback, so the Stop's bump vanished: the clip played and the
    /// mic re-armed.
    @Test func stopWhileWaitingForTheReplySkipsTheClipAndDoesNotRearm() async {
        let h = RecoveryHarness()
        await h.enterThinking()
        h.speech.streamAvailable = false
        // Still streaming, so the fallback path parks in its poll.
        h.agent.setPending(PendingSpeech(id: "0", text: "A reply", pending: true))
        await h.engine.agentStateChanged()
        #expect(await h.status(is: .speaking))
        #expect(await eventually { await h.speech.sequence == 1 && h.clock.sleeperCount > 0 })

        // Stop lands while the poll is parked — the sequence bump is the
        // only record of it.
        await h.engine.stopSpeech()

        // The reply completes afterwards; the poll wakes and must honor it.
        h.agent.setPending(PendingSpeech(id: "0", text: "A reply completed", pending: false))
        h.agent.setBusy(false)
        h.clock.advance(by: VoiceConstants.fallbackPollInterval)

        #expect(await h.status(is: .idle))
        try? await Task.sleep(for: .milliseconds(100))
        #expect(h.speech.fallbackTexts.isEmpty)
        #expect(h.recorder.startCount == 1)

        // listenNow is the documented way back, as after any other Stop.
        await h.engine.listenNow()
        #expect(await h.status(is: .listening))
        #expect(h.recorder.startCount == 2)
    }
}

// MARK: - Stop during the whole-clip fallback (issue #34)

/// A gated whole-clip synthesis request: holds `POST /api/audio/speak` open so
/// a test can land a Stop inside it.
final class ClipSynthesisGate: @unchecked Sendable {
    private let lock = NSLock()
    private var _requested: [String] = []
    private var _waiting = false
    private var released = false
    private var releasedData: Data?
    private var waiter: CheckedContinuation<Data?, Never>?

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    var requested: [String] { locked { _requested } }
    var isWaiting: Bool { locked { _waiting } }

    func synthesize(_ text: String) async -> Data? {
        locked { _requested.append(text) }
        return await withCheckedContinuation {
            (continuation: CheckedContinuation<Data?, Never>) in
            let immediate: Bool = locked {
                if released { return true }
                _waiting = true
                waiter = continuation
                return false
            }
            if immediate { continuation.resume(returning: locked { releasedData }) }
        }
    }

    /// Answer the parked request (the clip finally arrives).
    func release(_ data: Data?) {
        let parked: CheckedContinuation<Data?, Never>? = locked {
            released = true
            releasedData = data
            _waiting = false
            let parked = waiter
            waiter = nil
            return parked
        }
        parked?.resume(returning: data)
    }
}

/// A clip sink that records plays instead of touching an audio device.
final class RecordingClipPlayer: FallbackClipPlaying, @unchecked Sendable {
    private let lock = NSLock()
    private var _plays: [Data] = []
    private var _stopCount = 0

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    var plays: [Data] { locked { _plays } }
    var stopCount: Int { locked { _stopCount } }
    var isPlaying: Bool { false }

    func play(data: Data) async -> Bool {
        locked { _plays.append(data) }
        return true
    }

    func stop() {
        locked { _stopCount += 1 }
    }
}

@Suite("Stop during the whole-clip fallback")
struct FallbackStopTests {
    private func makeSpeech(
        gate: ClipSynthesisGate, player: RecordingClipPlayer
    ) -> HermesSpeechOutput {
        // The REST client is never called: synthesis goes through the gate.
        let rest = HermesRESTClient(
            endpoint: ServerEndpoint(baseURL: URL(string: "http://127.0.0.1:1")!), token: nil)
        return HermesSpeechOutput(
            rest: rest, profile: nil, voiceConfig: nil,
            synthesize: { text in await gate.synthesize(text) },
            makeFallbackPlayer: { player })
    }

    @Test func stopDuringSynthesisRequestNeverStartsPlayback() async {
        let gate = ClipSynthesisGate()
        let player = RecordingClipPlayer()
        let speech = makeSpeech(gate: gate, player: player)

        let play = Task { await speech.playFallback(text: "A reply completed") }
        #expect(await eventually { gate.isWaiting })

        // The Stop lands while the clip is still being synthesized — there is
        // no player to stop yet, so only the sequence records it. The clip
        // arriving afterwards must not start playing.
        await speech.stopPlayback()
        gate.release(Data([1, 2, 3]))

        #expect(await play.value == false)
        #expect(player.plays.isEmpty)
    }

    @Test func synthesizedClipPlaysWhenNoStopLands() async {
        let gate = ClipSynthesisGate()
        let player = RecordingClipPlayer()
        let speech = makeSpeech(gate: gate, player: player)

        let play = Task { await speech.playFallback(text: "A reply completed") }
        #expect(await eventually { gate.isWaiting })
        gate.release(Data([1, 2, 3]))

        #expect(await play.value == true)
        #expect(player.plays == [Data([1, 2, 3])])
        #expect(gate.requested == ["A reply completed"])
    }
}

// MARK: - Stop between sequence snapshot and playFallback (issue #34 review)

/// Forwards to a real `HermesSpeechOutput` but parks the sequence read that
/// immediately follows the engine's pre-clip `stopPlayback` (the second stop
/// of the turn: startStream's contract bump is the first). That is the
/// handoff window Astra reproduced: Stop can complete after the engine has
/// already read its final snapshot but before `playFallback` begins.
final class SequenceSnapshotGate: SpeechPlaying, @unchecked Sendable {
    private let inner: HermesSpeechOutput
    private let lock = NSLock()
    private var stopCount = 0
    private var delayArmed = false
    private var waiting = false
    private var released = false
    private var parkedValue: Int?
    private var waiter: CheckedContinuation<Int, Never>?

    init(_ inner: HermesSpeechOutput) {
        self.inner = inner
    }

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    var isWaiting: Bool { locked { waiting } }

    func release() {
        let parked: (CheckedContinuation<Int, Never>, Int)? = locked {
            released = true
            waiting = false
            guard let waiter, let parkedValue else { return nil }
            self.waiter = nil
            self.parkedValue = nil
            return (waiter, parkedValue)
        }
        if let parked { parked.0.resume(returning: parked.1) }
    }

    func startStream() async -> (any SpeechStreaming)? {
        // Avoid a real speak-stream dial; keep the +1 contract via stopPlayback.
        await stopPlayback()
        return nil
    }

    func playFallback(text: String, expectedSequence: Int) async -> Bool {
        await inner.playFallback(text: text, expectedSequence: expectedSequence)
    }

    func stopPlayback() async {
        await inner.stopPlayback()
        locked {
            stopCount += 1
            if stopCount == 2 { delayArmed = true }
        }
    }

    var sequence: Int {
        get async {
            let value = await inner.sequence
            let shouldDelay: Bool = locked {
                guard delayArmed else { return false }
                delayArmed = false
                return true
            }
            guard shouldDelay else { return value }
            return await withCheckedContinuation {
                (continuation: CheckedContinuation<Int, Never>) in
                let immediate: Int? = locked {
                    if released { return parkedValue ?? value }
                    waiting = true
                    parkedValue = value
                    waiter = continuation
                    return nil
                }
                if let immediate { continuation.resume(returning: immediate) }
            }
        }
    }

    var isSpeaking: Bool {
        get async { await inner.isSpeaking }
    }
}

@Suite("Stop between fallback sequence snapshot and playFallback")
struct FallbackSequenceHandoffTests {
    @Test func stopAfterFinalSequenceSnapshotMustNotPlay() async {
        let player = RecordingClipPlayer()
        let rest = HermesRESTClient(
            endpoint: ServerEndpoint(baseURL: URL(string: "http://127.0.0.1:1")!), token: nil)
        let inner = HermesSpeechOutput(
            rest: rest, profile: nil, voiceConfig: nil,
            synthesize: { _ in Data([1, 2, 3]) },
            makeFallbackPlayer: { player })
        let speech = SequenceSnapshotGate(inner)

        let clock = TestClock()
        let recorder = FakeRecorder()
        let barge = FakeBargeMonitor()
        let transcriber = GatedTranscriber()
        let agent = FakeAgent()
        let engine = ConversationEngine(
            recorder: recorder,
            bargeMonitor: barge,
            transcriber: transcriber,
            speech: speech,
            agent: agent,
            clock: clock)

        recorder.nextResult = makeUtterance()
        transcriber.queue("hello there")
        await engine.start()
        #expect(await eventually { await engine.status == .listening })
        recorder.fireAutoStop()
        #expect(await eventually { await engine.status == .thinking })

        agent.setPending(PendingSpeech(id: "0", text: "A reply completed", pending: false))
        agent.setBusy(false)
        await engine.agentStateChanged()
        #expect(await eventually { await engine.status == .speaking })
        #expect(await eventually { speech.isWaiting })

        await engine.stopSpeech()
        speech.release()

        #expect(await eventually { await engine.status == .idle })
        try? await Task.sleep(for: .milliseconds(100))
        #expect(player.plays.isEmpty)
        #expect(recorder.startCount == 1)
    }
}
