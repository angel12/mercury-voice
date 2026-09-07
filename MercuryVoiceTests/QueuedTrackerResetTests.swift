import Foundation
import HermesKit
import Testing
import VoiceEngine

@testable import MercuryVoice

/// Exercises the shipping controller pump and tracker without shared audio or a gateway.
@MainActor
@Suite("Queued tracker events versus reconnect reset", .timeLimit(.minutes(1)))
struct QueuedTrackerResetTests {
    @Test func queuedOldDeltaMustNotSurviveFallbackReset() async throws {
        try await exercise(replay: false, sessionOpen: false)
    }

    @Test func queuedOldDeltaMustNotSurviveSessionOpenReset() async throws {
        try await exercise(replay: false, sessionOpen: true)
    }

    @Test func successfulReplayPreservesQueuedDeltaInOrder() async throws {
        try await exercise(replay: true, sessionOpen: false)
    }

    @Test func supersededFallbackClosesSessionBeforeReturning() async throws {
        let gate = TrackerPumpGate()
        let requested = AsyncStream.makeStream(of: Void.self)
        var resetCount = 0
        let service = ScriptedSessionService()
        let controller = ConversationController(
            connection: makeUndialedConnection(), profile: nil,
            sessionService: service, speech: RecordingSpeech(),
            capture: AudioCaptureService(),
            beforeTrackerEvent: { _ in await gate.arrive() },
            trackerResetRequested: {
                resetCount += 1
                if resetCount == 2 { requested.continuation.finish() }
            })
        service.enqueueResume(Fixtures.resumeResult(runtimeID: "rt1", storedID: "st1"))
        do { try await controller.openSession(mode: .resume(storedID: "st1")) } catch {
            gate.release()
            await controller.teardown()
            throw error
        }
        controller.handle(
            event: Fixtures.event(
                Fixtures.eventParams(
                    type: GatewayEvent.Kind.messageStart, sessionID: "rt1", seq: 10)))
        await gate.waitUntilEntered()
        service.enqueueResume(Fixtures.resumeResult(runtimeID: "rt1", storedID: "st1"))
        service.enqueueBatchFailure()
        let reconnect = Task { await controller.connectionBecameReady(isReconnect: true) }
        for await _ in requested.stream {}
        controller.supersede()
        await reconnect.value
        #expect(service.closedIDs == ["rt1"])
        #expect(controller.notice != "Reconnected.")
        gate.release()
        await controller.diagnosticFinishTrackerEvents()
        await controller.teardown()
        #expect(service.closedIDs == ["rt1"])
    }

    @Test func cancelledBeginDoesNotPublishSetupFailure() async {
        let service = ScriptedSessionService()
        service.enqueueResume(Fixtures.resumeResult(runtimeID: "rt1", storedID: "st1"))
        let recorder = SilentRecorder()
        let speech = RecordingSpeech()
        let controller = ConversationController(
            connection: makeUndialedConnection(), profile: nil,
            sessionService: service, speech: speech,
            audio: .init(
                recorder: recorder, bargeMonitor: SilentBargeMonitor(),
                transcriber: SilentTranscriber(), microphone: AlwaysGrantedMicrophone()),
            capture: AudioCaptureService(),
            trackerResetRequested: { withUnsafeCurrentTask { $0?.cancel() } })
        let begin = Task { await controller.begin(mode: .resume(storedID: "st1")) }
        await begin.value
        #expect(controller.setupError == nil)
        #expect(recorder.startCalls == 0)
        #expect(speech.spoken.isEmpty)
        #expect(service.closedIDs == ["rt1"])
        await controller.teardown()
        #expect(service.closedIDs == ["rt1"])
    }

    @Test func teardownJoinsInFlightPumpWork() async throws {
        let gate = TrackerPumpGate()
        let joining = AsyncStream.makeStream(of: Void.self)
        // This independently owned waiter ignores cancellation of the pump,
        // modelling actor work already admitted before retirement.
        let service = ScriptedSessionService()
        let controller = ConversationController(
            connection: makeUndialedConnection(), profile: nil,
            sessionService: service, speech: RecordingSpeech(), capture: AudioCaptureService(),
            beforeTrackerEvent: { _ in
                let work = Task.detached { await gate.arrive() }
                await work.value
            },
            trackerPumpWillJoin: { joining.continuation.finish() })
        service.enqueueResume(Fixtures.resumeResult(runtimeID: "rt1", storedID: "st1"))
        do { try await controller.openSession(mode: .resume(storedID: "st1")) } catch {
            gate.release()
            await controller.teardown()
            throw error
        }
        controller.handle(
            event: Fixtures.event(
                Fixtures.eventParams(
                    type: GatewayEvent.Kind.messageStart, sessionID: "rt1", seq: 10)))
        await gate.waitUntilEntered()
        var returned = false
        let teardown = Task {
            await controller.teardown()
            returned = true
        }
        for await _ in joining.stream {}
        #expect(!returned, "teardown must join admitted pump work before returning")
        gate.release()
        await teardown.value
        await controller.diagnosticFinishTrackerEvents()
        #expect(returned)
        let state = await controller.diagnosticTrackerState()
        #expect(!state.busy)
        #expect(service.closedIDs == ["rt1"])
    }

    enum ResetExit: CaseIterable, Sendable {
        case applied, cancelledBeforeRegistration, cancelledBeforeWait, cancelledWhileWaiting
        case superseded, tornDown, pumpCancelled, inputFinished
    }

    // Lifecycle characterizations of the same acknowledged shipping operation,
    // not a second queue implementation. Every case joins all owned work.
    @Test(arguments: ResetExit.allCases)
    func resetAcknowledgementHasFiniteLifetime(exit: ResetExit) async throws {
        let gate = TrackerPumpGate()
        let requested = AsyncStream.makeStream(of: Void.self)
        var resetCount = 0
        let service = ScriptedSessionService()
        let controller = ConversationController(
            connection: makeUndialedConnection(), profile: nil,
            sessionService: service, speech: RecordingSpeech(), capture: AudioCaptureService(),
            beforeTrackerEvent: { _ in await gate.arrive() },
            trackerResetRequested: {
                resetCount += 1
                if resetCount == 2 {
                    if exit == .cancelledBeforeWait { withUnsafeCurrentTask { $0?.cancel() } }
                    requested.continuation.finish()
                }
            })
        service.enqueueResume(Fixtures.resumeResult(runtimeID: "rt1", storedID: "st1"))
        do { try await controller.openSession(mode: .resume(storedID: "st1")) } catch {
            gate.release()
            await controller.teardown()
            throw error
        }
        controller.handle(
            event: Fixtures.event(
                Fixtures.eventParams(
                    type: GatewayEvent.Kind.messageStart, sessionID: "rt1", seq: 10)))
        await gate.waitUntilEntered()
        let reset = Task {
            if exit == .cancelledBeforeRegistration { withUnsafeCurrentTask { $0?.cancel() } }
            return await controller.resetTracker(busy: false)
        }
        if exit != .cancelledBeforeRegistration { for await _ in requested.stream {} }
        switch exit {
        case .applied, .inputFinished: gate.release()
        case .cancelledBeforeRegistration, .cancelledBeforeWait: break
        case .cancelledWhileWaiting: reset.cancel()
        case .superseded: controller.supersede()
        case .tornDown:
            gate.release()
            await controller.teardown()
        case .pumpCancelled: controller.diagnosticCancelTrackerEvents()
        }
        if exit == .inputFinished { await controller.diagnosticFinishTrackerEvents() }
        let applied = await reset.value
        #expect(applied == (exit == .applied || exit == .inputFinished))
        #expect(controller.diagnosticPendingTrackerResets == 0)
        if exit == .cancelledBeforeRegistration { #expect(resetCount == 1) }
        gate.release()
        await controller.diagnosticFinishTrackerEvents()
        // A finished/terminated yield must reject immediately, including after
        // the pump retired before this new registration attempt.
        #expect(await controller.resetTracker(busy: true) == false)
        #expect(controller.diagnosticPendingTrackerResets == 0)
        await controller.teardown()
        #expect(service.closedIDs == ["rt1"])
    }

    @Test(arguments: [false, true])
    func liveEventsAfterResetRemainOrdered(sessionOpen: Bool) async throws {
        let gate = TrackerPumpGate()
        let requested = AsyncStream.makeStream(of: Void.self)
        var resetCount = 0
        let service = ScriptedSessionService()
        let controller = ConversationController(
            connection: makeUndialedConnection(), profile: nil,
            sessionService: service, speech: RecordingSpeech(), capture: AudioCaptureService(),
            beforeTrackerEvent: { _ in await gate.arrive() },
            trackerResetRequested: {
                resetCount += 1
                if resetCount == 2 { requested.continuation.finish() }
            })
        service.enqueueResume(Fixtures.resumeResult(runtimeID: "rt1", storedID: "st1"))
        do { try await controller.openSession(mode: .resume(storedID: "st1")) } catch {
            gate.release()
            await controller.teardown()
            throw error
        }
        controller.handle(
            event: Fixtures.event(
                Fixtures.eventParams(
                    type: GatewayEvent.Kind.messageStart, sessionID: "rt1", seq: 10)))
        controller.handle(
            event: Fixtures.event(
                Fixtures.eventParams(
                    type: GatewayEvent.Kind.messageDelta, sessionID: "rt1", seq: 11,
                    payload: .object(["text": .string("OLD SOCKET")]))))
        await gate.waitUntilEntered()
        service.enqueueResume(Fixtures.resumeResult(runtimeID: "rt1", storedID: "st1"))
        service.enqueueBatchFailure()
        var returned = false
        let reset = Task {
            if sessionOpen {
                do { try await controller.openSession(mode: .resume(storedID: "st1")) } catch {
                    Issue.record(error)
                }
            } else {
                await controller.connectionBecameReady(isReconnect: true)
            }
            returned = true
        }
        for await _ in requested.stream {}
        #expect(!returned, "reset callers must wait for applied acknowledgement")
        // For reconnect these are held live events; for open they enter the
        // same stream immediately after reset. Both must survive that reset.
        controller.handle(
            event: Fixtures.event(
                Fixtures.eventParams(
                    type: GatewayEvent.Kind.messageDelta, sessionID: "rt1", seq: 1,
                    payload: .object(["text": .string("NEW")]))))
        gate.release()
        await reset.value
        controller.handle(
            event: Fixtures.event(
                Fixtures.eventParams(
                    type: GatewayEvent.Kind.messageDelta, sessionID: "rt1", seq: 2,
                    payload: .object(["text": .string(" LIVE")]))))
        await controller.diagnosticFinishTrackerEvents()
        let state = await controller.diagnosticTrackerState()
        #expect(state.text == "NEW LIVE")
        #expect(state.busy)
        #expect(state.pendingText == "NEW LIVE")
        #expect(controller.diagnosticPendingTrackerResets == 0)
        await controller.teardown()
    }

    private func exercise(replay: Bool, sessionOpen: Bool) async throws {
        let gate = TrackerPumpGate()
        let requested = AsyncStream.makeStream(of: Void.self)
        var resetCount = 0
        let service = ScriptedSessionService()
        let controller = ConversationController(
            connection: makeUndialedConnection(), profile: nil,
            sessionService: service, speech: RecordingSpeech(),
            capture: AudioCaptureService(),
            beforeTrackerEvent: { event in
                if event.type == GatewayEvent.Kind.messageStart { await gate.arrive() }
            },
            trackerResetRequested: {
                resetCount += 1
                if resetCount == 2 { requested.continuation.finish() }
            })
        do {
            service.enqueueResume(Fixtures.resumeResult(runtimeID: "rt1", storedID: "st1"))
            try await controller.openSession(mode: .resume(storedID: "st1"))
            controller.handle(
                event: Fixtures.event(
                    Fixtures.eventParams(
                        type: GatewayEvent.Kind.messageStart, sessionID: "rt1", seq: 10)))
            controller.handle(
                event: Fixtures.event(
                    Fixtures.eventParams(
                        type: GatewayEvent.Kind.messageDelta, sessionID: "rt1", seq: 11,
                        payload: .object(["text": .string("OLD SOCKET")]))))
            // Start has left the stream but not reached the tracker; the delta
            // is still buffered behind it. No scheduler timing decides this.
            await gate.waitUntilEntered()
            service.enqueueResume(Fixtures.resumeResult(runtimeID: "rt1", storedID: "st1"))
            if replay {
                service.enqueueBatch(Fixtures.replayBatch([], latestSeq: 11))
                service.enqueueActivation(
                    Fixtures.activateResult(runtimeID: "rt1", sessionKey: "st1"))
            } else {
                // An old backend refusing the replay RPC takes the exact same
                // fallback reset as an epoch change/cold resume/truncated ring.
                service.enqueueBatchFailure()
            }
            controller.connectionLost()
            let reconnect = Task {
                if sessionOpen {
                    do { try await controller.openSession(mode: .resume(storedID: "st1")) } catch {
                        Issue.record(error)
                    }
                } else {
                    await controller.connectionBecameReady(isReconnect: true)
                }
            }
            if replay {
                // Preserve the original control's queue across the entire
                // successful replay decision (which must not request reset).
                await reconnect.value
                gate.release()
            } else {
                for await _ in requested.stream {}
                gate.release()
                await reconnect.value
            }
            if !sessionOpen { #expect(controller.notice == "Reconnected.") }
            #expect(service.eventsSinceCalls.map(\.lastSeen) == (sessionOpen ? [] : [11]))
            #expect(service.activatedIDs == (replay ? ["rt1"] : []))

            gate.release()
            // Finish without cancellation: join guarantees every queued event
            // really applied before the negative assertion (also valid on RED).
            await controller.diagnosticFinishTrackerEvents()
            let final = await controller.diagnosticTrackerState()
            #expect(
                final.text == (replay ? "OLD SOCKET" : ""),
                "queued pre-hold delta must not repopulate the tracker after fallback reset")
            #expect(final.busy == replay, "fallback running=false must remain authoritative")
            #expect(
                final.pendingText == (replay ? "OLD SOCKET" : nil),
                "interrupted old text must not become speakable again after reset")
        } catch {
            gate.release()
            await controller.diagnosticFinishTrackerEvents()
            await controller.teardown()
            throw error
        }
        gate.release()
        await controller.diagnosticFinishTrackerEvents()
        await controller.teardown()
    }
}

/// One consumer per stream; finish is idempotent, wakes an existing waiter,
/// and works before registration. AsyncStream cancellation also ends waits.
private final class TrackerPumpGate: Sendable {
    private let entered = AsyncStream.makeStream(of: Void.self)
    private let released = AsyncStream.makeStream(of: Void.self)

    func arrive() async {
        entered.continuation.finish()
        for await _ in released.stream {}
    }

    func waitUntilEntered() async {
        for await _ in entered.stream {}
    }

    func release() { released.continuation.finish() }
}
