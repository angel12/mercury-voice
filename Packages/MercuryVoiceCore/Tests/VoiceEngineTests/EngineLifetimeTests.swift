import Foundation
import Testing

@testable import VoiceEngine

private actor GatedSubmitAgent: AgentInterfacing {
    let gate = GatedTranscriber()
    var submitting = false
    var isBusy: Bool { submitting }

    func pendingSpeech() -> PendingSpeech? { nil }
    func consumePendingSpeech() {}
    func interrupt() {}

    func submit(text: String, interrupted: Bool) async throws {
        submitting = true
        _ = try await gate.transcribe(makeUtterance())
    }
}

@Suite("Engine lifetime isolation")
struct EngineLifetimeTests {
    @Test(arguments: [false, true])
    func endDuringSubmitCannotRestoreThinkingOrReportFailure(fails: Bool) async {
        let recorder = FakeRecorder()
        recorder.nextResult = makeUtterance()
        let transcriber = FakeTranscriber()
        transcriber.queue("hello there")
        let agent = GatedSubmitAgent()
        let gate = agent.gate
        gate.armGate()
        if fails { gate.queueFailure(URLError(.notConnectedToInternet)) }
        let notices = NoticeBox()
        let engine = ConversationEngine(
            recorder: recorder, bargeMonitor: FakeBargeMonitor(),
            transcriber: transcriber, speech: FakeSpeech(), agent: agent,
            callbacks: ConversationCallbacks(onNotice: { notices.append($0) }),
            clock: TestClock())
        await engine.start()
        let turn = Task { await engine.stopTurnNow() }
        #expect(await eventually { await agent.submitting })
        await engine.end()
        gate.release()
        await turn.value

        #expect(await engine.status == .idle)
        #expect(await engine.uiState.enabled == false)
        #expect(notices.list.isEmpty)
        await engine.end()
    }

    @Test(arguments: [false, true])
    func releasingThinkingEngineWithoutEndCancelsChime(afterTick: Bool) async throws {
        let clock = TestClock()
        let recorder = FakeRecorder()
        recorder.nextResult = makeUtterance()
        let transcriber = FakeTranscriber()
        transcriber.queue("hello there")
        let ticks = ConversationEngineTests.Harness.CountBox()
        var engine: ConversationEngine<TestClock>? = ConversationEngine(
            recorder: recorder, bargeMonitor: FakeBargeMonitor(),
            transcriber: transcriber, speech: FakeSpeech(), agent: FakeAgent(),
            callbacks: ConversationCallbacks(onThinkingTick: { ticks.bump() }),
            clock: clock)
        await engine?.start()
        // Await the entire close/drive path, not merely the .thinking status
        // publication: no caller-owned task may still retain the engine.
        await engine?.stopTurnNow()
        #expect(await engine?.status == .thinking)
        try #require(await eventually { clock.sleeperCount == 1 })
        if afterTick {
            clock.advance(by: VoiceConstants.thinkingChimeInterval)
            try #require(await eventually { ticks.count == 1 })
            try #require(await eventually { clock.sleeperCount == 1 })
        }

        weak var releasedEngine = engine
        engine = nil
        // Do not advance time or call end() to make these assertions pass.
        #expect(await eventually { releasedEngine == nil })
        #expect(clock.sleeperCount == 0)
        let countAtRelease = ticks.count
        clock.advance(by: VoiceConstants.thinkingChimeInterval)
        #expect(ticks.count == countAtRelease)

        // Clean up the deliberately leaking baseline after recording RED.
        await releasedEngine?.end()
        releasedEngine = nil
    }

    @Test func lateAgentReplyAfterEndCannotRestartSpeech() async {
        let h = ConversationEngineTests.Harness()
        await h.enterThinking()
        await h.engine.end()
        h.agent.setPending(PendingSpeech(id: "late", text: "Late reply", pending: false))
        h.agent.setBusy(false)
        await h.engine.agentStateChanged()

        #expect(await h.engine.status == .idle)
        #expect(!h.barge.isActive)
        await h.engine.end()
    }
}
