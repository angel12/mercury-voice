import Foundation
import Testing

@testable import VoiceEngine

/// Issue #150: a listening turn is transcribed live from mic open; the engine
/// closes it with the recorder's capture, or cancels it with the recording.
/// Barge-in captures arrive whole and never use it.
@Suite("Live transcription in the engine")
struct LiveTranscriptionEngineTests {
    typealias Harness = ConversationEngineTests.Harness

    private func listening(_ h: Harness) async {
        h.transcriber.liveEnabled = true
        h.recorder.nextResult = makeUtterance()
        await h.engine.start()
        #expect(await h.status(is: .listening))
        #expect(await eventually { h.transcriber.liveTurns.count == 1 })
    }

    @Test func aListeningTurnClosesThroughItsLiveTurn() async {
        let h = Harness()
        h.transcriber.queueLive("hello live")
        await listening(h)

        h.recorder.fireAutoStop()

        #expect(await eventually { h.agent.submissions.count == 1 })
        #expect(h.agent.submissions[0].text == "hello live")
        #expect(h.transcriber.liveTurns[0].finished)
        #expect(h.transcriber.transcribeCount == 0)
    }

    @Test func stopWhileListeningCancelsTheLiveTurn() async {
        let h = Harness()
        await listening(h)

        await h.engine.stopSpeech()

        #expect(h.transcriber.liveTurns[0].cancelled)
        #expect(!h.transcriber.liveTurns[0].finished)
    }

    @Test func muteCancelsTheLiveTurn() async {
        let h = Harness()
        await listening(h)

        await h.engine.toggleMute()

        #expect(h.transcriber.liveTurns[0].cancelled)
    }

    @Test func endCancelsTheLiveTurn() async {
        let h = Harness()
        await listening(h)

        await h.engine.end()

        #expect(h.transcriber.liveTurns[0].cancelled)
    }

    @Test func aTurnWithoutSpeechCancelsItsLiveTurnAndRelistens() async {
        let h = Harness()
        await listening(h)
        h.recorder.nextResult = makeUtterance(heardSpeech: false)

        h.recorder.fireAutoStop()

        #expect(await eventually { h.transcriber.liveTurns.count == 2 })
        #expect(h.transcriber.liveTurns[0].cancelled)
        #expect(!h.transcriber.liveTurns[0].finished)
        #expect(h.agent.submissions.isEmpty)
    }

    @Test func bargeCapturesUseTheWholeUtterance() async {
        let h = Harness()
        h.transcriber.queueLive("first")
        await listening(h)
        h.recorder.fireAutoStop()
        #expect(await h.status(is: .thinking))
        _ = await eventually { h.barge.isActive }

        h.barge.trip()
        #expect(await eventually { h.agent.interruptCount == 1 })
        h.agent.setBusy(false)
        h.transcriber.queue("no, the other one")
        h.barge.deliver(makeUtterance())

        #expect(await eventually { h.agent.submissions.count == 2 })
        #expect(h.agent.submissions[1].text == "no, the other one")
        #expect(h.transcriber.transcribeCount == 1)
        #expect(h.transcriber.liveTurns.count == 1)
    }
}
