import Foundation
import Testing

@testable import VoiceEngine

/// Behavioral tests for the conversation state machine, conceptually porting
/// the desktop's use-voice-conversation / rearm test suites.
@Suite("ConversationEngine")
struct ConversationEngineTests {
    struct Harness {
        let engine: ConversationEngine<TestClock>
        let clock: TestClock
        let recorder: FakeRecorder
        let barge: FakeBargeMonitor
        let transcriber: FakeTranscriber
        let speech: FakeSpeech
        let agent: FakeAgent
        let stopWords: StopWordBox

        final class StopWordBox: @unchecked Sendable {
            private let lock = NSLock()
            private var _count = 0
            var count: Int {
                lock.lock()
                defer { lock.unlock() }
                return _count
            }
            func bump() {
                lock.lock()
                _count += 1
                lock.unlock()
            }
        }

        init() {
            let clock = TestClock()
            let recorder = FakeRecorder()
            let barge = FakeBargeMonitor()
            let transcriber = FakeTranscriber()
            let speech = FakeSpeech()
            let agent = FakeAgent()
            let stopWords = StopWordBox()
            self.clock = clock
            self.recorder = recorder
            self.barge = barge
            self.transcriber = transcriber
            self.speech = speech
            self.agent = agent
            self.stopWords = stopWords
            self.engine = ConversationEngine(
                recorder: recorder,
                bargeMonitor: barge,
                transcriber: transcriber,
                speech: speech,
                agent: agent,
                callbacks: ConversationCallbacks(onStopWord: { stopWords.bump() }),
                clock: clock)
        }

        func status(is expected: ConversationStatus) async -> Bool {
            await eventually { await engine.status == expected }
        }

        /// start → listening → speak an utterance → submitted → thinking.
        func enterThinking(transcript: String = "hello there") async {
            recorder.nextResult = makeUtterance()
            transcriber.queue(transcript)
            await engine.start()
            #expect(await status(is: .listening))
            recorder.fireAutoStop()
            #expect(await status(is: .thinking))
        }
    }

    // MARK: Happy path

    @Test func fullLoopListensTranscribesSubmitsSpeaksAndRearms() async {
        let h = Harness()
        await h.enterThinking()
        #expect(h.agent.submissions.map(\.text) == ["hello there"])
        #expect(h.agent.submissions[0].interrupted == false)

        // First assistant text arrives → speaking, stream fed.
        h.agent.setPending(PendingSpeech(id: "0", text: "Hi! ", pending: true))
        await h.engine.agentStateChanged()
        #expect(await h.status(is: .speaking))
        #expect(
            await eventually { h.speech.currentStream?.appendedText == "Hi! " })

        // Reply completes; turn no longer busy → next feed tick finishes.
        h.agent.setPending(PendingSpeech(id: "0", text: "Hi! All done.", pending: false))
        h.agent.setBusy(false)
        await h.engine.agentStateChanged()
        let stream = h.speech.currentStream
        h.clock.advance(by: .milliseconds(150))
        #expect(await eventually { stream?.finished == true })
        #expect(stream?.appendedText == "Hi! All done.")

        // Stream done → settle → mic re-arms.
        #expect(await h.status(is: .listening))
        #expect(h.recorder.startCount == 2)
    }

    @Test func emptyTranscriptQuietlyRelistens() async {
        let h = Harness()
        h.recorder.nextResult = makeUtterance()
        h.transcriber.queue("")
        await h.engine.start()
        #expect(await h.status(is: .listening))
        h.recorder.fireAutoStop()

        #expect(await eventually { h.recorder.startCount == 2 })
        #expect(await h.status(is: .listening))
        #expect(h.agent.submissions.isEmpty)
    }

    @Test func noSpeechHeardRelistensWithoutTranscribing() async {
        let h = Harness()
        h.recorder.nextResult = makeUtterance(heardSpeech: false)
        await h.engine.start()
        #expect(await h.status(is: .listening))
        h.recorder.fireAutoStop()
        #expect(await eventually { h.recorder.startCount == 2 })
        #expect(h.agent.submissions.isEmpty)
    }

    @Test func stopWordEndsConversation() async {
        let h = Harness()
        h.recorder.nextResult = makeUtterance()
        h.transcriber.queue("hey hermes, stop.")
        await h.engine.start()
        #expect(await h.status(is: .listening))
        h.recorder.fireAutoStop()

        #expect(await eventually { h.stopWords.count == 1 })
        #expect(await h.status(is: .idle))
        #expect(h.agent.submissions.isEmpty)
        #expect(h.recorder.startCount == 1)  // no re-arm
    }

    @Test func hardCapClosesTheTurn() async {
        let h = Harness()
        h.recorder.nextResult = makeUtterance()
        h.transcriber.queue("long monologue")
        await h.engine.start()
        #expect(await h.status(is: .listening))
        h.clock.advance(by: .seconds(60))
        #expect(await h.status(is: .thinking))
        #expect(h.agent.submissions.map(\.text) == ["long monologue"])
    }

    @Test func toolOnlyTurnGoesBackToListening() async {
        let h = Harness()
        await h.enterThinking()
        // Turn completes with nothing speakable.
        h.agent.setBusy(false)
        await h.engine.agentStateChanged()
        #expect(await h.status(is: .listening))
        #expect(h.recorder.startCount == 2)
    }

    // MARK: Barge-in

    @Test func armsBargeMonitorDuringGeneration() async {
        let h = Harness()
        await h.enterThinking()
        #expect(await eventually { h.barge.startCount >= 1 })
    }

    @Test func bargeMonitorIsIdempotentPerTurn() async {
        let h = Harness()
        await h.enterThinking()
        _ = await eventually { h.barge.startCount >= 1 }
        await h.engine.agentStateChanged()
        await h.engine.agentStateChanged()
        #expect(h.barge.startCount == 1)
    }

    @Test func bargeDuringGenerationInterruptsTurn() async {
        let h = Harness()
        await h.enterThinking()
        _ = await eventually { h.barge.isActive }

        let seqBefore = await h.speech.sequence
        h.barge.trip()
        #expect(await eventually { h.agent.interruptCount == 1 })
        #expect(await h.speech.sequence > seqBefore)  // playback stopped
    }

    @Test func bargeDuringPlaybackDoesNotInterrupt() async {
        let h = Harness()
        await h.enterThinking()
        // Reply streaming, turn already finished server-side.
        h.agent.setPending(PendingSpeech(id: "0", text: "reply", pending: true))
        await h.engine.agentStateChanged()
        #expect(await h.status(is: .speaking))
        h.agent.setBusy(false)

        h.barge.trip()
        #expect(await eventually { await h.speech.sequence >= 2 })
        try? await Task.sleep(for: .milliseconds(50))
        #expect(h.agent.interruptCount == 0)
    }

    @Test func bargeCaptureSubmitsWithInterruptedFlag() async {
        let h = Harness()
        await h.enterThinking()
        _ = await eventually { h.barge.isActive }

        h.barge.trip()
        #expect(await eventually { h.agent.interruptCount == 1 })
        h.agent.setBusy(false)  // the interrupt settled

        h.transcriber.queue("no, do it differently")
        h.barge.deliver(makeUtterance())

        #expect(await eventually { h.agent.submissions.count == 2 })
        #expect(h.agent.submissions[1].text == "no, do it differently")
        #expect(h.agent.submissions[1].interrupted == true)
        #expect(await h.status(is: .thinking))
    }

    @Test func bargeStopWordEndsInsteadOfSubmitting() async {
        let h = Harness()
        await h.enterThinking()
        _ = await eventually { h.barge.isActive }

        h.barge.trip()
        h.agent.setBusy(false)
        h.transcriber.queue("stop")
        h.barge.deliver(makeUtterance())

        #expect(await eventually { h.stopWords.count == 1 })
        #expect(h.agent.submissions.count == 1)  // only the kickoff turn
        #expect(await h.status(is: .idle))
    }

    @Test func emptyBargeCaptureResumesListening() async {
        let h = Harness()
        await h.enterThinking()
        _ = await eventually { h.barge.isActive }

        h.barge.trip()
        h.agent.setBusy(false)
        h.transcriber.queue("")
        h.barge.deliver(makeUtterance())

        #expect(await h.status(is: .listening))
        #expect(h.agent.submissions.count == 1)
    }

    // MARK: Stop / re-arm rules

    @Test func userStopDuringStreamingDoesNotRearm() async {
        let h = Harness()
        await h.enterThinking()
        h.agent.setPending(PendingSpeech(id: "0", text: "reply text", pending: true))
        await h.engine.agentStateChanged()
        #expect(await h.status(is: .speaking))

        await h.engine.stopSpeech()
        #expect(await h.status(is: .idle))
        try? await Task.sleep(for: .milliseconds(100))
        #expect(h.recorder.startCount == 1)  // no second mic arm
    }

    @Test func stopWhileListeningGoesIdleWithoutRearm() async {
        let h = Harness()
        h.recorder.nextResult = makeUtterance()
        await h.engine.start()
        #expect(await h.status(is: .listening))
        await h.engine.stopSpeech()
        #expect(await h.status(is: .idle))
        #expect(h.recorder.startCount == 1)
    }

    @Test func muteCancelsMicAndUnmuteRearms() async {
        let h = Harness()
        h.recorder.nextResult = makeUtterance()
        await h.engine.start()
        #expect(await h.status(is: .listening))

        await h.engine.toggleMute()
        #expect(await h.status(is: .idle))

        await h.engine.toggleMute()
        #expect(await h.status(is: .listening))
        #expect(h.recorder.startCount == 2)
    }

    // MARK: Fallback TTS path

    @Test func fallbackOutcomePlaysWholeClipAndRearms() async {
        let h = Harness()
        h.speech.immediateFallback = true
        await h.enterThinking()

        h.agent.setPending(PendingSpeech(id: "0", text: "the full reply", pending: true))
        await h.engine.agentStateChanged()
        #expect(await h.status(is: .speaking))

        // Reply finishes; the fallback poll picks it up.
        h.agent.setPending(PendingSpeech(id: "0", text: "the full reply", pending: false))
        h.agent.setBusy(false)
        h.clock.advance(by: .milliseconds(250))

        #expect(await eventually { h.speech.fallbackTexts == ["the full reply"] })
        #expect(await h.status(is: .listening))
        #expect(h.recorder.startCount == 2)
    }

    @Test func forceEndTurnTranscribesImmediately() async {
        let h = Harness()
        h.recorder.nextResult = makeUtterance(heardSpeech: false)  // VAD saw nothing
        h.transcriber.queue("forced words")
        await h.engine.start()
        #expect(await h.status(is: .listening))

        await h.engine.stopTurnNow()
        #expect(await h.status(is: .thinking))
        #expect(h.agent.submissions.map(\.text) == ["forced words"])
    }
}
