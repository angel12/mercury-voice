import Foundation
import Testing

@testable import VoiceEngine

/// The issue-#15 cue callbacks: `onTurnCaptured` when speech is sent for
/// transcription, and the periodic `onThinkingTick` while status stays
/// `.thinking`.
@Suite("Audio cues")
struct AudioCueTests {
    typealias Harness = ConversationEngineTests.Harness

    // MARK: Turn-captured cue

    @Test func turnCapturedFiresWhenSpeechIsSubmitted() async {
        let h = Harness()
        await h.enterThinking()
        #expect(h.turnCues.count == 1)
    }

    @Test func noCueWhenNothingWasHeard() async {
        let h = Harness()
        h.recorder.nextResult = makeUtterance(heardSpeech: false)
        await h.engine.start()
        #expect(await h.status(is: .listening))
        h.recorder.fireAutoStop()
        #expect(await eventually { h.recorder.startCount == 2 })
        #expect(h.turnCues.count == 0)
    }

    @Test func bargeCaptureFiresTurnCapturedCue() async {
        let h = Harness()
        await h.enterThinking()
        #expect(h.turnCues.count == 1)

        h.agent.setPending(PendingSpeech(id: "0", text: "Hi there!", pending: true))
        await h.engine.agentStateChanged()
        #expect(await h.status(is: .speaking))

        h.transcriber.queue("wait, actually")
        h.barge.trip()
        #expect(await eventually { h.agent.interruptCount == 1 })
        h.agent.setBusy(false)
        h.barge.deliver(makeUtterance())
        #expect(await eventually { h.turnCues.count == 2 })
    }

    @Test func abortedBargeCaptureDoesNotCue() async {
        let h = Harness()
        await h.enterThinking()
        h.agent.setPending(PendingSpeech(id: "0", text: "Hi there!", pending: true))
        await h.engine.agentStateChanged()
        #expect(await h.status(is: .speaking))

        h.barge.trip()
        #expect(await eventually { h.agent.interruptCount == 1 })
        h.agent.setBusy(false)
        h.barge.deliver(nil)  // nothing usable was captured
        #expect(await eventually { h.recorder.startCount == 2 })  // re-armed
        #expect(h.turnCues.count == 1)  // only the original turn
    }

    // MARK: Thinking chime

    @Test func thinkingChimeTicksOnCadence() async {
        let h = Harness()
        await h.enterThinking()
        #expect(h.thinkingTicks.count == 0)

        // Wait for the chime timer to arm before advancing (the cleared turn
        // timer is gone by now, so the chime is the only sleeper).
        #expect(await eventually { h.clock.sleeperCount == 1 })
        h.clock.advance(by: VoiceConstants.thinkingChimeInterval)
        #expect(await eventually { h.thinkingTicks.count == 1 })

        #expect(await eventually { h.clock.sleeperCount == 1 })
        h.clock.advance(by: VoiceConstants.thinkingChimeInterval)
        #expect(await eventually { h.thinkingTicks.count == 2 })
    }

    @Test func thinkingChimeStopsWhenSpeakingStarts() async {
        let h = Harness()
        await h.enterThinking()
        #expect(await eventually { h.clock.sleeperCount == 1 })

        h.agent.setPending(PendingSpeech(id: "0", text: "Hi!", pending: true))
        await h.engine.agentStateChanged()
        #expect(await h.status(is: .speaking))

        h.clock.advance(by: VoiceConstants.thinkingChimeInterval)
        try? await Task.sleep(for: .milliseconds(100))
        #expect(h.thinkingTicks.count == 0)
    }

    @Test func thinkingChimeSilencedWhilePaused() async {
        let h = Harness()
        await h.enterThinking()
        #expect(await eventually { h.clock.sleeperCount == 1 })

        await h.engine.setPaused(true)
        h.clock.advance(by: VoiceConstants.thinkingChimeInterval)
        // The tick fires silently and re-arms.
        #expect(await eventually { h.clock.sleeperCount == 1 })
        #expect(h.thinkingTicks.count == 0)

        await h.engine.setPaused(false)
        #expect(await eventually { h.clock.sleeperCount == 1 })
        h.clock.advance(by: VoiceConstants.thinkingChimeInterval)
        #expect(await eventually { h.thinkingTicks.count == 1 })
    }

    @Test func endingWhileThinkingStopsChime() async {
        let h = Harness()
        await h.enterThinking()
        #expect(await eventually { h.clock.sleeperCount == 1 })

        await h.engine.end()
        #expect(await h.status(is: .idle))
        h.clock.advance(by: VoiceConstants.thinkingChimeInterval)
        try? await Task.sleep(for: .milliseconds(100))
        #expect(h.thinkingTicks.count == 0)
    }
}
