import Foundation
import HermesKit
import Testing

@testable import MercuryVoice

/// Issue #75 (audit finding R23) — snapshot/replay ordering on reconnect.
///
/// `connectionBecameReady` used to take a `session.resume` **snapshot**,
/// apply every **replayed event** newer than the watermark, and then
/// reconcile the prompt sheets **from that same snapshot**. The snapshot is
/// necessarily older than the events, so reconciling from it last let a stale
/// fact overwrite a newer one in both directions: a question that arrived
/// during the outage was cleared, or one that was answered during it was put
/// back on screen. The live socket could not repair either mistake — the
/// corrective frame is usually the same frame the batch already carried, and
/// the seq watermark drops it as a duplicate when the held events drain.
///
/// The fix reads prompt state **after** the batch, from `session.activate`,
/// and the batch is only applied once that read has succeeded and been
/// identity-checked. These tests pin that order, both directions of the
/// original bug, and every path where the second read is unusable.
@MainActor
@Suite("R23 resume snapshot vs replay ordering")
struct R23ReplayOrderingTests {

    static let runtimeID = "rt1"
    static let storedID = "st1"
    static let watermark = 10

    /// A controller with a live session open at `watermark`, exactly as it
    /// would be just before the socket dropped.
    private func openedController(
        service: ScriptedSessionService,
        speech: RecordingSpeech = RecordingSpeech(),
        pendingClarify: JSONValue? = nil
    ) async throws -> ConversationController {
        service.enqueueResume(
            Fixtures.resumeResult(
                runtimeID: Self.runtimeID, storedID: Self.storedID,
                pendingClarify: pendingClarify))
        let controller = makeController(service: service, speech: speech)
        try await controller.openSession(mode: .resume(storedID: Self.storedID))
        // Everything up to `watermark` was seen before the outage.
        controller.handle(
            event: Fixtures.event(
                Fixtures.messageComplete(sessionID: Self.runtimeID, seq: Self.watermark)))
        return controller
    }

    /// The reconnect's `session.resume` answer.
    private func enqueueReconnectResume(
        _ service: ScriptedSessionService,
        pendingApproval: JSONValue? = nil,
        pendingClarify: JSONValue? = nil
    ) {
        service.enqueueResume(
            Fixtures.resumeResult(
                runtimeID: Self.runtimeID, storedID: Self.storedID,
                pendingApproval: pendingApproval, pendingClarify: pendingClarify))
    }

    /// The post-batch `session.activate` answer for the same session.
    private func enqueuePromptRead(
        _ service: ScriptedSessionService,
        status: String = "idle",
        pendingApproval: JSONValue? = nil,
        pendingClarify: JSONValue? = nil
    ) {
        service.enqueueActivation(
            Fixtures.activateResult(
                runtimeID: Self.runtimeID, sessionKey: Self.storedID, status: status,
                pendingApproval: pendingApproval, pendingClarify: pendingClarify))
    }

    // MARK: An older snapshot must not clear a newly replayed prompt

    @Test("a question raised during the outage is on screen after the reconnect")
    func replayedClarifyIsNotClearedByTheOlderSnapshot() async throws {
        let service = ScriptedSessionService()
        let controller = try await openedController(service: service)

        // The resume snapshot was taken before the agent asked; the question
        // is in the replay batch and still pending at the post-batch read.
        enqueueReconnectResume(service)
        service.enqueueBatch(
            Fixtures.replayBatch([
                Fixtures.clarifyRequest(
                    sessionID: Self.runtimeID, seq: 11, requestID: "q1",
                    question: "Which branch?")
            ]))
        enqueuePromptRead(
            service, status: "waiting",
            pendingClarify: Fixtures.clarifyPayload(requestID: "q1", question: "Which branch?"))

        await controller.connectionBecameReady(isReconnect: true)

        #expect(controller.clarify?.requestID == "q1")
        #expect(controller.clarify?.question == "Which branch?")
        #expect(service.eventsSinceCalls.map(\.lastSeen) == [Self.watermark])
        // The prompt read is taken after the batch, not instead of it.
        #expect(service.activatedIDs == [Self.runtimeID])
    }

    @Test("an approval raised during the outage is on screen after the reconnect")
    func replayedApprovalIsNotClearedByTheOlderSnapshot() async throws {
        let service = ScriptedSessionService()
        let controller = try await openedController(service: service)

        enqueueReconnectResume(service)
        service.enqueueBatch(
            Fixtures.replayBatch([
                Fixtures.approvalRequest(
                    sessionID: Self.runtimeID, seq: 11, command: "rm -rf /tmp/build",
                    requestID: "a1")
            ]))
        enqueuePromptRead(
            service,
            pendingApproval: Fixtures.approvalPayload(
                command: "rm -rf /tmp/build", requestID: "a1"))

        await controller.connectionBecameReady(isReconnect: true)

        #expect(controller.approval?.command == "rm -rf /tmp/build")
        #expect(controller.approval?.requestID == "a1")
    }

    // MARK: An older snapshot must not resurrect a resolved prompt

    @Test("a question answered during the outage is not put back on screen")
    func expiredClarifyIsNotResurrectedByTheOlderSnapshot() async throws {
        let service = ScriptedSessionService()
        let controller = try await openedController(service: service)

        // The resume snapshot still lists q1; the expiry is newer, and the
        // post-batch read agrees nothing is pending.
        enqueueReconnectResume(
            service,
            pendingClarify: Fixtures.clarifyPayload(requestID: "q1", question: "Which branch?"))
        service.enqueueBatch(
            Fixtures.replayBatch([
                Fixtures.clarifyExpire(sessionID: Self.runtimeID, seq: 11, requestID: "q1")
            ]))
        enqueuePromptRead(service)

        await controller.connectionBecameReady(isReconnect: true)

        #expect(controller.clarify == nil)
    }

    @Test("a superseded approval is not restored over the newer one")
    func supersededApprovalIsNotRestoredByTheOlderSnapshot() async throws {
        let service = ScriptedSessionService()
        let controller = try await openedController(service: service)

        enqueueReconnectResume(
            service, pendingApproval: Fixtures.approvalPayload(command: "git status"))
        service.enqueueBatch(
            Fixtures.replayBatch([
                Fixtures.approvalRequest(
                    sessionID: Self.runtimeID, seq: 11, command: "git push --force",
                    requestID: "a2")
            ]))
        enqueuePromptRead(
            service,
            pendingApproval: Fixtures.approvalPayload(
                command: "git push --force", requestID: "a2"))

        await controller.connectionBecameReady(isReconnect: true)

        #expect(controller.approval?.command == "git push --force")
    }

    /// The counterexample that defeats every scheme which classifies replayed
    /// frames against a marker taken *before* them: the client is at
    /// watermark 10 and drops; the agent registers approval A; another client
    /// approves A before A's frame is emitted (the gateway appends to the
    /// queue, releases the lock, runs the `pre_approval_request` hook, and
    /// only then emits); A's frame is stamped seq 11. On reconnect the resume
    /// snapshot has no pending approval and the batch carries A at seq 11, so
    /// "frames above the snapshot win" shows a dead sheet.
    ///
    /// Reading prompt state after the batch answers it without a rule: the
    /// read happens after the resolution, so it reports nothing pending.
    @Test("an approval resolved before its own frame does not open a dead sheet")
    func approvalResolvedBeforeItsFrameIsNotPresented() async throws {
        let service = ScriptedSessionService()
        let controller = try await openedController(service: service)

        enqueueReconnectResume(service)
        service.enqueueBatch(
            Fixtures.replayBatch([
                Fixtures.approvalRequest(
                    sessionID: Self.runtimeID, seq: 11, command: "rm -rf /", requestID: "a3")
            ]))
        enqueuePromptRead(service)  // A was answered; nothing is pending.

        await controller.connectionBecameReady(isReconnect: true)

        #expect(controller.approval == nil)
    }

    // MARK: A request racing the prompt read — before and after it

    @Test("a request that reaches the read is presented once, not twice")
    func requestArrivingBeforeThePromptReadIsPresentedOnce() async throws {
        let service = ScriptedSessionService()
        let controller = try await openedController(service: service)

        enqueueReconnectResume(service)
        service.enqueueBatch(
            Fixtures.replayBatch([
                Fixtures.messageComplete(sessionID: Self.runtimeID, seq: 11)
            ]))
        // The read is taken after the frame was emitted, so it lists a1 too.
        enqueuePromptRead(
            service,
            pendingApproval: Fixtures.approvalPayload(command: "deploy", requestID: "a1"))

        let gate = CallGate()
        service.activateGate = gate
        let ready = Task { await controller.connectionBecameReady(isReconnect: true) }
        await gate.waitUntilEntered()
        // The live frame for the same approval, held until the drain. Its
        // command differs only so the assertion can tell the two copies
        // apart — a real duplicate is identical.
        controller.handle(
            event: Fixtures.event(
                Fixtures.approvalRequest(
                    sessionID: Self.runtimeID, seq: 12, command: "deploy-live",
                    requestID: "a1")))
        await gate.release()
        await ready.value

        // "deploy" means the drain recognised a1 as the sheet already up and
        // left it alone; a second presentation would have bumped the response
        // epoch (discarding an answer in flight) and re-spoken the notice.
        #expect(controller.approval?.command == "deploy")
        #expect(controller.approval?.requestID == "a1")
    }

    @Test("a request that misses the read is still presented by the drain")
    func requestArrivingAfterThePromptReadIsStillPresented() async throws {
        let service = ScriptedSessionService()
        let controller = try await openedController(service: service)

        enqueueReconnectResume(service)
        service.enqueueBatch(
            Fixtures.replayBatch([
                Fixtures.messageComplete(sessionID: Self.runtimeID, seq: 11)
            ]))
        // Read taken before the request was registered: nothing pending.
        enqueuePromptRead(service)

        let gate = CallGate()
        service.activateReturnGate = gate
        let ready = Task { await controller.connectionBecameReady(isReconnect: true) }
        await gate.waitUntilEntered()
        controller.handle(
            event: Fixtures.event(
                Fixtures.approvalRequest(
                    sessionID: Self.runtimeID, seq: 12, command: "later", requestID: "a4")))
        await gate.release()
        await ready.value

        // The read cleared the sheets; the held frame is newer than the read
        // and must not be dropped by that clear.
        #expect(controller.approval?.command == "later")
    }

    // MARK: The prompt read fails — the batch must leave no trace

    @Test("a failed prompt read discards the batch and keeps the resume snapshot")
    func failedPromptReadDiscardsTheBatch() async throws {
        let service = ScriptedSessionService()
        let controller = try await openedController(service: service)

        enqueueReconnectResume(
            service, pendingApproval: Fixtures.approvalPayload(command: "make install"))
        service.enqueueBatch(
            Fixtures.replayBatch([
                Fixtures.clarifyRequest(
                    sessionID: Self.runtimeID, seq: 11, requestID: "q-batch",
                    question: "From the batch?"),
                Fixtures.messageComplete(sessionID: Self.runtimeID, seq: 12, text: "batched"),
            ]))
        // The runtime session went away between the two calls (4001), or the
        // backend does not have the method at all.
        service.enqueueActivationFailure(
            HermesError.rpcError(code: 4001, message: "session not found", data: nil))

        let gate = CallGate()
        service.resumeGate = gate
        let ready = Task { await controller.connectionBecameReady(isReconnect: true) }
        await gate.waitUntilEntered()
        // A live frame at the same seq as one the batch carried. On the
        // fallback path the batch is never applied, so the watermark never
        // advanced past it and this must still be applied on the drain.
        controller.handle(
            event: Fixtures.event(
                Fixtures.clarifyRequest(
                    sessionID: Self.runtimeID, seq: 11, requestID: "q-live",
                    question: "From the socket?")))
        await gate.release()
        await ready.value

        // The resume snapshot is the only prompt authority on this path.
        #expect(controller.approval?.command == "make install")
        // Nothing from the batch reached the UI…
        #expect(!controller.devMessages.contains { $0.text == "batched" })
        // …and the held frame was neither dropped nor swallowed by a
        // watermark the discarded batch would have advanced.
        #expect(controller.clarify?.requestID == "q-live")
    }

    // MARK: Identity and epoch across the read

    @Test("a prompt read for a different session incarnation is refused")
    func startedAtMismatchRoutesToTheFallback() async throws {
        let service = ScriptedSessionService()
        let controller = try await openedController(service: service)

        enqueueReconnectResume(
            service, pendingApproval: Fixtures.approvalPayload(command: "make install"))
        service.enqueueBatch(
            Fixtures.replayBatch([
                Fixtures.messageComplete(sessionID: Self.runtimeID, seq: 11, text: "batched")
            ]))
        // Same short runtime id, reminted for a different session inside one
        // process: the batch belongs to the earlier one.
        service.enqueueActivation(
            Fixtures.activateResult(
                runtimeID: Self.runtimeID, sessionKey: Self.storedID,
                startedAt: 1_700_009_999))

        await controller.connectionBecameReady(isReconnect: true)

        #expect(controller.approval?.command == "make install")
        #expect(!controller.devMessages.contains { $0.text == "batched" })
    }

    @Test("a backend restart discovered after the prompt read is refused")
    func epochChangeAcrossThePromptReadRoutesToTheFallback() async throws {
        let service = ScriptedSessionService()
        let controller = try await openedController(service: service)

        enqueueReconnectResume(
            service, pendingApproval: Fixtures.approvalPayload(command: "make install"))
        service.enqueueBatch(
            Fixtures.replayBatch([
                Fixtures.messageComplete(sessionID: Self.runtimeID, seq: 11, text: "batched")
            ]))
        enqueuePromptRead(service)
        // The epoch the fetch-time checks saw is gone by the time the read
        // answers, so nothing may be applied across it.
        service.setEpochAfterActivate("epoch-2")

        await controller.connectionBecameReady(isReconnect: true)

        #expect(controller.approval?.command == "make install")
        #expect(!controller.devMessages.contains { $0.text == "batched" })
    }

    @Test("an unrecognised prompt-read payload is refused, not read as empty")
    func malformedPromptReadRoutesToTheFallback() async throws {
        let service = ScriptedSessionService()
        let controller = try await openedController(service: service)

        enqueueReconnectResume(
            service, pendingApproval: Fixtures.approvalPayload(command: "make install"))
        service.enqueueBatch(
            Fixtures.replayBatch([
                Fixtures.messageComplete(sessionID: Self.runtimeID, seq: 11, text: "batched")
            ]))
        // Envelope field the builder always writes is missing: this is an
        // unvalidated shape, which is a different thing from a valid payload
        // with no pending prompts.
        service.enqueueActivation(
            .object([
                "session_id": .string(Self.runtimeID),
                "started_at": .number(1_700_000_000),
                "status": .string("idle"),
                "running": .bool(false),
            ]))

        await controller.connectionBecameReady(isReconnect: true)

        #expect(controller.approval?.command == "make install")
        #expect(!controller.devMessages.contains { $0.text == "batched" })
    }

    /// The envelope can be perfect and the prompt field still unusable. A
    /// *present* pending key is the backend asserting something is pending,
    /// so a value the sheet decoders cannot read is an unvalidated shape —
    /// and the two failure modes are the exact damage R23 is about: a
    /// clarify with no `request_id` decodes to nil and clears the live
    /// sheet, and a non-object approval presents a sheet with nothing in it.
    @Test("a clarify with no request id is refused, not read as answered")
    func presentButUnusableClarifyRoutesToTheFallback() async throws {
        let service = ScriptedSessionService()
        let controller = try await openedController(
            service: service,
            pendingClarify: Fixtures.clarifyPayload(requestID: "q0", question: "Old?"))
        #expect(controller.clarify?.requestID == "q0")

        enqueueReconnectResume(
            service,
            pendingClarify: Fixtures.clarifyPayload(requestID: "q0", question: "Old?"))
        service.enqueueBatch(
            Fixtures.replayBatch([
                Fixtures.messageComplete(sessionID: Self.runtimeID, seq: 11, text: "batched")
            ]))
        enqueuePromptRead(
            service, status: "waiting",
            pendingClarify: .object(["question": .string("Which branch?")]))

        await controller.connectionBecameReady(isReconnect: true)

        // The still-pending question survives, on the resume snapshot's
        // authority, and the batch is discarded with the read.
        #expect(controller.clarify?.requestID == "q0")
        #expect(!controller.devMessages.contains { $0.text == "batched" })
    }

    @Test("a non-object approval is refused, not presented as an empty sheet")
    func presentButUnusableApprovalRoutesToTheFallback() async throws {
        let service = ScriptedSessionService()
        let controller = try await openedController(service: service)

        enqueueReconnectResume(
            service, pendingApproval: Fixtures.approvalPayload(command: "make install"))
        service.enqueueBatch(
            Fixtures.replayBatch([
                Fixtures.messageComplete(sessionID: Self.runtimeID, seq: 11, text: "batched")
            ]))
        enqueuePromptRead(service, pendingApproval: .string("make install"))

        await controller.connectionBecameReady(isReconnect: true)

        #expect(controller.approval?.command == "make install")
        #expect(!controller.devMessages.contains { $0.text == "batched" })
    }

    // MARK: Absent pending keys are a valid answer, not a missing one

    @Test("a waiting snapshot with no pending keys clears the sheets")
    func absentPendingKeysAreTreatedAsNothingPending() async throws {
        let service = ScriptedSessionService()
        let controller = try await openedController(
            service: service,
            pendingClarify: Fixtures.clarifyPayload(requestID: "q0", question: "Old?"))
        #expect(controller.clarify?.requestID == "q0")

        enqueueReconnectResume(
            service,
            pendingClarify: Fixtures.clarifyPayload(requestID: "q0", question: "Old?"))
        service.enqueueBatch(
            Fixtures.replayBatch([
                Fixtures.messageComplete(sessionID: Self.runtimeID, seq: 11, text: "batched")
            ]))
        // `status: waiting` with neither pending key is a legitimate state —
        // another blocking prompt family (secret/sudo/terminal.read/tour)
        // sets the status, and only `clarify.request` populates
        // `pending_clarify`. It must not be read as a malformed response.
        enqueuePromptRead(service, status: "waiting")

        await controller.connectionBecameReady(isReconnect: true)

        #expect(controller.clarify == nil)
        #expect(controller.approval == nil)
        // The batch was applied, so this took the replay path rather than
        // failing the read.
        #expect(controller.devMessages.contains { $0.text == "batched" })
    }

    // MARK: Paths with no usable replay

    @Test("a truncated batch skips the prompt read entirely")
    func truncatedBatchSkipsThePromptRead() async throws {
        let service = ScriptedSessionService()
        let controller = try await openedController(service: service)

        enqueueReconnectResume(
            service, pendingApproval: Fixtures.approvalPayload(command: "make install"))
        service.enqueueBatch(
            Fixtures.replayBatch(
                [Fixtures.messageComplete(sessionID: Self.runtimeID, seq: 11, text: "batched")],
                truncated: true))

        await controller.connectionBecameReady(isReconnect: true)

        #expect(service.activatedIDs.isEmpty)
        #expect(controller.approval?.command == "make install")
        #expect(!controller.devMessages.contains { $0.text == "batched" })
    }

    @Test("without a replay contract the resume snapshot stays authoritative")
    func snapshotIsAuthoritativeWhenReplayIsUnavailable() async throws {
        let service = ScriptedSessionService()
        let controller = try await openedController(service: service)

        enqueueReconnectResume(
            service, pendingApproval: Fixtures.approvalPayload(command: "make install"))
        service.enqueueBatchFailure()

        await controller.connectionBecameReady(isReconnect: true)

        #expect(service.activatedIDs.isEmpty)
        #expect(controller.approval?.command == "make install")
    }

    // MARK: Preservation

    @Test("a prompt only the registry knows about is still adopted")
    func registryOnlyApprovalIsStillAdopted() async throws {
        let service = ScriptedSessionService()
        let controller = try await openedController(service: service)

        enqueueReconnectResume(service)
        service.enqueueBatch(
            Fixtures.replayBatch([
                Fixtures.messageComplete(sessionID: Self.runtimeID, seq: 11)
            ]))
        enqueuePromptRead(
            service, pendingApproval: Fixtures.approvalPayload(command: "sudo reboot"))

        await controller.connectionBecameReady(isReconnect: true)

        #expect(controller.approval?.command == "sudo reboot")
    }

    @Test("a sheet the registry no longer lists is still cleared")
    func staleSheetIsStillCleared() async throws {
        let service = ScriptedSessionService()
        let controller = try await openedController(
            service: service,
            pendingClarify: Fixtures.clarifyPayload(requestID: "q0", question: "Old?"))
        #expect(controller.clarify?.requestID == "q0")

        enqueueReconnectResume(service)
        service.enqueueBatch(
            Fixtures.replayBatch([
                Fixtures.messageComplete(sessionID: Self.runtimeID, seq: 11)
            ]))
        enqueuePromptRead(service)

        await controller.connectionBecameReady(isReconnect: true)

        #expect(controller.clarify == nil)
    }

    @Test("a live event newer than the prompt read still wins after the drain")
    func newerLiveEventStillAppliesAfterTheDrain() async throws {
        let service = ScriptedSessionService()
        let controller = try await openedController(service: service)

        enqueueReconnectResume(service)
        service.enqueueBatch(
            Fixtures.replayBatch([
                Fixtures.clarifyRequest(
                    sessionID: Self.runtimeID, seq: 11, requestID: "q1", question: "Old?")
            ]))
        enqueuePromptRead(
            service, pendingClarify: Fixtures.clarifyPayload(requestID: "q1", question: "Old?"))

        let gate = CallGate()
        service.resumeGate = gate
        let ready = Task { await controller.connectionBecameReady(isReconnect: true) }
        await gate.waitUntilEntered()
        controller.handle(
            event: Fixtures.event(
                Fixtures.clarifyRequest(
                    sessionID: Self.runtimeID, seq: 12, requestID: "q2", question: "New?")))
        await gate.release()
        await ready.value

        #expect(controller.clarify?.requestID == "q2")
    }

    // MARK: Known failure — the silent-resolution defect, tracked separately

    /// A prompt whose frame is emitted after the batch was fetched and
    /// resolved by another client before the prompt read: the read correctly
    /// omits it, and the held frame then resurrects it on the drain.
    ///
    /// No read order fixes this. The request frame is the only carrier and it
    /// only ever says "asked" — resolving an approval or answering a clarify
    /// emits nothing at all — so the client has no fact that can retire the
    /// frame. It is also **not reconnect-specific**: a continuously connected
    /// client fed the same server history receives the same request frame,
    /// never receives a resolution, and shows the same dead sheet. The fix is
    /// `approval.resolved` / `clarify.resolved` on the gateway plus a
    /// tombstone here, which is a protocol change tracked on its own issue.
    ///
    /// Recorded as a known issue rather than asserted, so that it fails
    /// loudly on the day the resolution frames land.
    @Test("a prompt resolved between the batch and the read is resurrected (known)")
    func promptResolvedInsideTheReadWindowIsResurrected() async throws {
        let service = ScriptedSessionService()
        let controller = try await openedController(service: service)

        enqueueReconnectResume(service)
        service.enqueueBatch(
            Fixtures.replayBatch([
                Fixtures.messageComplete(sessionID: Self.runtimeID, seq: 11)
            ]))
        // Read taken after the answer: the registry is empty and correct.
        enqueuePromptRead(service)

        let gate = CallGate()
        service.activateReturnGate = gate
        let ready = Task { await controller.connectionBecameReady(isReconnect: true) }
        await gate.waitUntilEntered()
        // The frame for a question that has already been answered elsewhere.
        controller.handle(
            event: Fixtures.event(
                Fixtures.clarifyRequest(
                    sessionID: Self.runtimeID, seq: 12, requestID: "q-dead",
                    question: "Already answered?")))
        await gate.release()
        await ready.value

        withKnownIssue("silent-resolution defect: no frame retires an answered prompt") {
            #expect(controller.clarify == nil)
        }
    }
}
