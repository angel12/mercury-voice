import HermesKit
import Testing

@testable import MercuryVoice

/// prompt.submit reattach refusals (issue #125). The gateway answers 4007
/// ("session no longer live; retry resume") or 4009 ("disconnect interrupt
/// settling") BEFORE accepting the prompt, so exactly one resubmit is safe:
/// 4007 re-runs the reconnect resume first, 4009 waits 500 ms. A second
/// refusal surfaces as any other failure — never a loop.
@Suite(.timeLimit(.minutes(1)))
@MainActor
struct R34SubmitRecoveryTests {
    private static let notLive = HermesError.rpcError(
        code: 4007, message: "session no longer live; retry resume", data: nil)
    private static let settling = HermesError.rpcError(
        code: 4009, message: "session disconnect interrupt settling", data: nil)

    private func makeRecoveringController(
        service: ScriptedSessionService,
        submits: SubmitLog,
        delays: DelayLog,
        answers: [HermesError?],
        willResume: (@MainActor @Sendable (Bool) -> Void)? = nil
    ) -> ConversationController {
        ConversationController(
            connection: makeUndialedConnection(), profile: nil,
            sessionService: service, speech: RecordingSpeech(),
            submitPrompt: { sid, text, _ in
                let index = await submits.record(
                    sid: sid, text: text, resumesSoFar: service.resumedIDs.count)
                if index < answers.count, let error = answers[index] { throw error }
            },
            retryDelay: { await delays.record($0) },
            reattachRecoveryWillResume: willResume)
    }

    @Test func notLiveReResumesThenResubmitsOnce() async throws {
        let service = ScriptedSessionService()
        service.enqueueCreate(Fixtures.resumeResult(runtimeID: "runtime", storedID: "stored"))
        service.enqueueResume(Fixtures.resumeResult(runtimeID: "runtime-2", storedID: "stored"))
        let submits = SubmitLog()
        let delays = DelayLog()
        let controller = makeRecoveringController(
            service: service, submits: submits, delays: delays, answers: [Self.notLive, nil])
        try await controller.openSession(mode: .create(cwd: nil, title: nil))
        controller.submitTextPrompt("hello")
        await controller.textSubmissionTask?.value
        let calls = await submits.calls
        #expect(calls.map(\.text) == ["hello", "hello"])
        // One resume, between the two submits; the retry routes to its runtime.
        #expect(calls.map(\.resumesSoFar) == [0, 1])
        #expect(calls.map(\.sid) == ["runtime", "runtime-2"])
        #expect(service.resumedIDs == ["stored"])
        #expect(controller.failedText == nil)
        #expect(controller.devMessages.map(\.text) == ["hello"])
        // The refused prompt never ran, so the resume reports running=false;
        // the reset must still leave the resubmitted turn busy or the engine
        // re-arms the mic instead of awaiting the reply.
        #expect(await controller.diagnosticTrackerState().busy)
        // The user saw no disconnect.
        #expect(controller.notice != "Reconnected.")
        await controller.teardown()
    }

    @Test func failedReResumeSurfacesOneErrorWithoutResubmitting() async throws {
        let service = ScriptedSessionService()
        service.enqueueCreate(Fixtures.resumeResult(runtimeID: "runtime", storedID: "stored"))
        // No scripted resume: the re-resume fails.
        let submits = SubmitLog()
        let controller = makeRecoveringController(
            service: service, submits: submits, delays: DelayLog(), answers: [Self.notLive, nil])
        try await controller.openSession(mode: .create(cwd: nil, title: nil))
        controller.submitTextPrompt("hello")
        await controller.textSubmissionTask?.value
        #expect(await submits.calls.count == 1)
        #expect(service.resumedIDs == ["stored"])
        #expect(controller.failedText == "hello")
        #expect(controller.setupError == nil)
        #expect(await !controller.diagnosticTrackerState().busy)
        await controller.teardown()
    }

    /// A 4007 while the socket-driven reconnect resume is still suspended
    /// joins that resume: one resume, then one resubmit to its runtime.
    @Test func notLiveDuringReconnectJoinsTheInFlightResume() async throws {
        let service = ScriptedSessionService()
        service.enqueueCreate(Fixtures.resumeResult(runtimeID: "runtime", storedID: "stored"))
        service.enqueueResume(Fixtures.resumeResult(runtimeID: "runtime-2", storedID: "stored"))
        let resumeGate = CallGate()
        service.resumeGate = resumeGate
        let submits = SubmitLog()
        let joined = Signal()
        let joinedInFlight = JoinLog()
        let controller = makeRecoveringController(
            service: service, submits: submits, delays: DelayLog(), answers: [Self.notLive, nil],
            willResume: { inFlight in
                Task {
                    await joinedInFlight.record(inFlight)
                    await joined.signal()
                }
            })
        try await controller.openSession(mode: .create(cwd: nil, title: nil))
        let reconnect = Task { await controller.connectionBecameReady(isReconnect: true) }
        await resumeGate.waitUntilEntered()
        controller.submitTextPrompt("hello")
        await joined.wait()
        await resumeGate.release()
        await reconnect.value
        await controller.textSubmissionTask?.value
        #expect(await joinedInFlight.values == [true])
        #expect(service.resumedIDs == ["stored"])
        let calls = await submits.calls
        #expect(calls.map(\.sid) == ["runtime", "runtime-2"])
        #expect(controller.failedText == nil)
        #expect(await controller.diagnosticTrackerState().busy)
        await controller.teardown()
    }

    /// The reverse order: a 4007 recovery's resume is already in flight when
    /// the new socket reports ready. The socket still runs its own resume,
    /// but only after the recovery's has finished — two overlapping resumes
    /// would share the event hold, and the first one's drain would release
    /// it while the second was still deciding replay vs reset.
    @Test func socketReadyDuringRecoveryResumeWaitsForIt() async throws {
        let service = ScriptedSessionService()
        service.enqueueCreate(Fixtures.resumeResult(runtimeID: "runtime", storedID: "stored"))
        service.enqueueResume(Fixtures.resumeResult(runtimeID: "runtime-2", storedID: "stored"))
        service.enqueueResume(Fixtures.resumeResult(runtimeID: "runtime-2", storedID: "stored"))
        let recoveryGate = CallGate()
        service.resumeGate = recoveryGate
        let submits = SubmitLog()
        let controller = makeRecoveringController(
            service: service, submits: submits, delays: DelayLog(), answers: [Self.notLive, nil])
        try await controller.openSession(mode: .create(cwd: nil, title: nil))
        controller.submitTextPrompt("hello")
        await recoveryGate.waitUntilEntered()

        let socketGate = CallGate()
        service.resumeGate = socketGate
        let reconnect = Task { await controller.connectionBecameReady(isReconnect: true) }
        // A later main-actor job at the same priority runs after the
        // reconnect's first one, so by here it has either started its own
        // resume (the bug) or suspended on the recovery's.
        await Task { @MainActor in }.value
        await recoveryGate.release()
        await controller.textSubmissionTask?.value

        // The socket's resume starts only now, with the recovery's finished;
        // a live event landing while it is suspended is still held.
        await socketGate.waitUntilEntered()
        #expect(service.resumedIDs == ["stored", "stored"])
        #expect(await submits.calls.map(\.sid) == ["runtime", "runtime-2"])
        controller.handle(
            event: Fixtures.event(
                Fixtures.statusUpdate(sessionID: "runtime-2", seq: 1, kind: "compacting")))
        #expect(controller.toolTicker == nil)

        await socketGate.release()
        await reconnect.value
        #expect(controller.toolTicker == "Compacting context…")
        await controller.teardown()
    }

    @Test func settlingWaitsThenResubmitsWithoutResume() async throws {
        let service = ScriptedSessionService()
        service.enqueueCreate(Fixtures.resumeResult(runtimeID: "runtime", storedID: "stored"))
        let submits = SubmitLog()
        let delays = DelayLog()
        let controller = makeRecoveringController(
            service: service, submits: submits, delays: delays, answers: [Self.settling, nil])
        try await controller.openSession(mode: .create(cwd: nil, title: nil))
        controller.submitTextPrompt("hello")
        await controller.textSubmissionTask?.value
        #expect(await submits.calls.map(\.text) == ["hello", "hello"])
        #expect(service.resumedIDs.isEmpty)
        #expect(await delays.delays == [.milliseconds(500)])
        #expect(controller.failedText == nil)
        await controller.teardown()
    }

    @Test func secondNotLiveSurfacesWithoutLooping() async throws {
        let service = ScriptedSessionService()
        service.enqueueCreate(Fixtures.resumeResult(runtimeID: "runtime", storedID: "stored"))
        service.enqueueResume(Fixtures.resumeResult(runtimeID: "runtime-2", storedID: "stored"))
        let submits = SubmitLog()
        let delays = DelayLog()
        let controller = makeRecoveringController(
            service: service, submits: submits, delays: delays,
            answers: [Self.notLive, Self.notLive, nil])
        try await controller.openSession(mode: .create(cwd: nil, title: nil))
        controller.submitTextPrompt("hello")
        await controller.textSubmissionTask?.value
        #expect(await submits.calls.count == 2)
        #expect(service.resumedIDs == ["stored"])
        #expect(controller.failedText == "hello")
        #expect(controller.textSubmissionError != nil)
        #expect(controller.devMessages.isEmpty)
        await controller.teardown()
    }

    @Test func otherFailuresAreNotRetried() async throws {
        let service = ScriptedSessionService()
        service.enqueueCreate(Fixtures.resumeResult(runtimeID: "runtime", storedID: "stored"))
        let submits = SubmitLog()
        let delays = DelayLog()
        let controller = makeRecoveringController(
            service: service, submits: submits, delays: delays,
            answers: [.connectionClosed(nil), nil])
        try await controller.openSession(mode: .create(cwd: nil, title: nil))
        controller.submitTextPrompt("hello")
        await controller.textSubmissionTask?.value
        #expect(await submits.calls.count == 1)
        #expect(await delays.delays.isEmpty)
        #expect(controller.failedText == "hello")
        await controller.teardown()
    }

    /// The same refusal can answer the reconnect's own `session.resume`; one
    /// 500 ms retry keeps the reconnect from being abandoned for it.
    @Test func reconnectResumeRetriesOnceOnSettling() async throws {
        let service = ScriptedSessionService()
        service.enqueueCreate(Fixtures.resumeResult(runtimeID: "runtime", storedID: "stored"))
        service.enqueueResumeFailure(Self.settling)
        service.enqueueResume(Fixtures.resumeResult(runtimeID: "runtime", storedID: "stored"))
        let delays = DelayLog()
        let controller = makeRecoveringController(
            service: service, submits: SubmitLog(), delays: delays, answers: [])
        try await controller.openSession(mode: .create(cwd: nil, title: nil))
        await controller.connectionBecameReady(isReconnect: true)
        #expect(service.resumedIDs == ["stored", "stored"])
        #expect(await delays.delays == [.milliseconds(500)])
        #expect(controller.setupError == nil)
        await controller.teardown()
    }

    @Test func reconnectResumeGivesUpAfterSecondSettling() async throws {
        let service = ScriptedSessionService()
        service.enqueueCreate(Fixtures.resumeResult(runtimeID: "runtime", storedID: "stored"))
        service.enqueueResumeFailure(Self.settling)
        service.enqueueResumeFailure(Self.settling)
        service.enqueueResume(Fixtures.resumeResult(runtimeID: "runtime", storedID: "stored"))
        let controller = makeRecoveringController(
            service: service, submits: SubmitLog(), delays: DelayLog(), answers: [])
        try await controller.openSession(mode: .create(cwd: nil, title: nil))
        await controller.connectionBecameReady(isReconnect: true)
        #expect(service.resumedIDs.count == 2)
        #expect(controller.setupError != nil)
        await controller.teardown()
    }
}

private actor SubmitLog {
    struct Call: Sendable {
        let sid: String
        let text: String
        let resumesSoFar: Int
    }
    private(set) var calls: [Call] = []

    /// Returns this call's zero-based index.
    func record(sid: String, text: String, resumesSoFar: Int) -> Int {
        calls.append(Call(sid: sid, text: text, resumesSoFar: resumesSoFar))
        return calls.count - 1
    }
}

private actor DelayLog {
    private(set) var delays: [Duration] = []
    func record(_ delay: Duration) { delays.append(delay) }
}

private actor JoinLog {
    private(set) var values: [Bool] = []
    func record(_ value: Bool) { values.append(value) }
}
