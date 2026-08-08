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
        let stopWords: CountBox
        let turnCues: CountBox
        let thinkingTicks: CountBox

        final class CountBox: @unchecked Sendable {
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
            let stopWords = CountBox()
            let turnCues = CountBox()
            let thinkingTicks = CountBox()
            self.clock = clock
            self.recorder = recorder
            self.barge = barge
            self.transcriber = transcriber
            self.speech = speech
            self.agent = agent
            self.stopWords = stopWords
            self.turnCues = turnCues
            self.thinkingTicks = thinkingTicks
            self.engine = ConversationEngine(
                recorder: recorder,
                bargeMonitor: barge,
                transcriber: transcriber,
                speech: speech,
                agent: agent,
                callbacks: ConversationCallbacks(
                    onStopWord: { stopWords.bump() },
                    onTurnCaptured: { turnCues.bump() },
                    onThinkingTick: { thinkingTicks.bump() }),
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

    @Test func bargeCaptureEchoingTheReplyIsDroppedNotSubmitted() async {
        // Issue #12: with speakers on, the mic hears the agent's own speech;
        // its transcript must never be submitted back as a user turn.
        let h = Harness()
        await h.enterThinking()
        h.agent.setPending(
            PendingSpeech(id: "0", text: "The weather today is sunny and warm.", pending: true))
        await h.engine.agentStateChanged()
        #expect(await h.status(is: .speaking))
        // Wait for a feed tick so the engine has snapshotted the reply text.
        #expect(await eventually { h.speech.currentStream?.appendedText.isEmpty == false })
        h.agent.setBusy(false)

        h.barge.trip()
        #expect(await eventually { await h.speech.sequence >= 2 })  // playback stopped
        h.transcriber.queue("the weather today is sunny")
        h.barge.deliver(makeUtterance())

        // The drop path re-arms the mic (a second recorder start) without
        // ever submitting the echo.
        #expect(await eventually { h.recorder.startCount == 2 })
        #expect(await h.status(is: .listening))
        #expect(h.agent.submissions.count == 1)  // only the kickoff turn

        // A genuine turn still goes through afterwards.
        h.recorder.nextResult = makeUtterance()
        h.transcriber.queue("actually, what about tomorrow?")
        h.recorder.fireAutoStop()
        #expect(await eventually { h.agent.submissions.count == 2 })
        #expect(h.agent.submissions.last?.text == "actually, what about tomorrow?")
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

    // MARK: Mute × barge-in (issue #7)

    @Test func muteWhileSpeakingSuspendsBargeMonitorButNotPlayback() async {
        let h = Harness()
        await h.enterThinking()
        h.agent.setPending(PendingSpeech(id: "0", text: "reply", pending: true))
        await h.engine.agentStateChanged()
        #expect(await h.status(is: .speaking))
        _ = await eventually { h.barge.isActive }

        await h.engine.toggleMute()
        #expect(await eventually { h.barge.isSuspended })
        // Playback is untouched — the monitor stays attached (tearing down
        // the mic engine mid-TTS kills playback) but goes deaf.
        #expect(h.barge.isActive)
        #expect(await h.engine.status == .speaking)
        #expect(await h.speech.isSpeaking)

        // A trip that raced the mute must not interrupt or stop playback.
        let seqBefore = await h.speech.sequence
        h.barge.trip()
        try? await Task.sleep(for: .milliseconds(50))
        #expect(h.agent.interruptCount == 0)
        #expect(await h.speech.sequence == seqBefore)
        #expect(await h.speech.isSpeaking)
    }

    @Test func unmuteWhileSpeakingResumesBargeMonitorWithoutRestart() async {
        let h = Harness()
        await h.enterThinking()
        h.agent.setPending(PendingSpeech(id: "0", text: "reply", pending: true))
        await h.engine.agentStateChanged()
        #expect(await h.status(is: .speaking))
        _ = await eventually { h.barge.isActive }

        await h.engine.toggleMute()
        #expect(await eventually { h.barge.isSuspended })

        await h.engine.toggleMute()
        #expect(await eventually { !h.barge.isSuspended })
        #expect(h.barge.startCount == 1)  // resumed, not restarted
        #expect(await h.engine.status == .speaking)

        // Barge-in works again end to end.
        h.barge.trip()
        #expect(await eventually { h.agent.interruptCount == 1 })
    }

    @Test func muteWhileThinkingSuspendsBargeMonitorAndUnmuteResumes() async {
        let h = Harness()
        await h.enterThinking()
        _ = await eventually { h.barge.isActive }

        await h.engine.toggleMute()
        #expect(await eventually { h.barge.isSuspended })

        await h.engine.toggleMute()
        #expect(await eventually { !h.barge.isSuspended })
        #expect(h.barge.startCount == 1)
    }

    @Test func pauseWhileSpeakingSuspendsBargeMonitorAndResumeResumes() async {
        let h = Harness()
        await h.enterThinking()
        h.agent.setPending(PendingSpeech(id: "0", text: "reply", pending: true))
        await h.engine.agentStateChanged()
        #expect(await h.status(is: .speaking))
        _ = await eventually { h.barge.isActive }

        await h.engine.setPaused(true)
        #expect(await eventually { h.barge.isSuspended })
        #expect(await h.engine.status == .speaking)
        #expect(await h.speech.isSpeaking)

        await h.engine.setPaused(false)
        #expect(await eventually { !h.barge.isSuspended })
        #expect(h.barge.startCount == 1)
    }

    @Test func speakingEnteredWhileMutedArmsMonitorOnUnmute() async {
        let h = Harness()
        await h.enterThinking()
        _ = await eventually { h.barge.isActive }

        // Trip, mute, and let the racing capture detach the monitor; the
        // turn then starts speaking while muted → monitor never armed.
        h.barge.trip()
        #expect(await eventually { h.agent.interruptCount == 1 })
        await h.engine.toggleMute()
        #expect(await eventually { h.barge.isSuspended })
        h.barge.deliver(makeUtterance())
        try? await Task.sleep(for: .milliseconds(50))

        h.agent.setPending(PendingSpeech(id: "0", text: "reply", pending: true))
        await h.engine.agentStateChanged()
        #expect(await h.status(is: .speaking))
        #expect(!h.barge.isActive)  // arming is refused while muted

        await h.engine.toggleMute()
        #expect(await eventually { h.barge.isActive && !h.barge.isSuspended })
        #expect(h.barge.startCount == 2)
    }

    @Test func muteAfterBargeTripCancelsPendingCapture() async {
        let h = Harness()
        await h.enterThinking()
        _ = await eventually { h.barge.isActive }

        h.barge.trip()
        #expect(await eventually { h.agent.interruptCount == 1 })

        await h.engine.toggleMute()
        #expect(await eventually { h.barge.isSuspended })

        // A capture already in flight when the mute landed must be dropped,
        // not submitted. (Let the engine process the delivery before the
        // unmute lands, as a real capture would resolve before a user taps.)
        h.transcriber.queue("should never be sent")
        h.barge.deliver(makeUtterance())
        try? await Task.sleep(for: .milliseconds(50))

        // The interrupted turn settles; unmute recovers to plain listening.
        h.agent.setBusy(false)
        await h.engine.toggleMute()
        #expect(await h.status(is: .listening))
        #expect(h.agent.submissions.count == 1)
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
