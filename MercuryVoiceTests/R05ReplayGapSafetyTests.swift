import Foundation
import HermesKit
import Testing

@testable import MercuryVoice

/// Issue #58 (audit finding R05) — a `session.events.since` answer is only a
/// lossless replay if it says so readably.
///
/// The reconnect path applies a replay batch *in place of* the tracker reset:
/// the watermark is kept, the batch's frames are applied on top of it, and
/// everything the batch did not carry is assumed never to have happened. That
/// is sound only when the response proves it is the complete set of frames
/// after the watermark. The decoder used to concede every one of those proofs
/// on a bad response — a missing or unreadable `truncated` read as "no gap",
/// an absent `epoch` read as "same numbering", and an entry it could not
/// decode dropped from the batch without a trace — so a reply that answered
/// none of the questions was replayed as if it had answered all of them, and
/// the frames it lost were silently skipped forever (the watermark advanced
/// past them, so the live socket could never redeliver them either).
///
/// Every gateway that has served this method answers with
/// `events`/`latest_seq`/`truncated`/`count`/`epoch`
/// (`tui_gateway/methods_session.py`), and `epoch` has been echoed since the
/// same commit that first advertised `replay_epoch` at `gateway.ready` — so
/// requiring them costs no backend that ever worked. Anything short of that
/// takes the fallback the contract already has: drop the watermark, reset the
/// tracker, and let the resume snapshot be the authority.
@MainActor
@Suite("R05 replay batches must prove they are lossless")
struct R05ReplayGapSafetyTests {

    static let runtimeID = "rt1"
    static let storedID = "st1"
    static let watermark = 10

    /// A controller with a live session open at `watermark`, exactly as it
    /// would be just before the socket dropped.
    private func openedController(service: ScriptedSessionService) async throws
        -> ConversationController
    {
        service.enqueueResume(
            Fixtures.resumeResult(runtimeID: Self.runtimeID, storedID: Self.storedID))
        let controller = makeController(service: service)
        try await controller.openSession(mode: .resume(storedID: Self.storedID))
        controller.handle(
            event: Fixtures.event(
                Fixtures.messageComplete(sessionID: Self.runtimeID, seq: Self.watermark)))
        return controller
    }

    /// The reconnect's `session.resume` answer, listing the approval that is
    /// the fallback path's evidence: it can only reach the sheet from the
    /// snapshot, because the post-batch prompt read is never taken there.
    private func enqueueReconnectResume(_ service: ScriptedSessionService) {
        service.enqueueResume(
            Fixtures.resumeResult(
                runtimeID: Self.runtimeID, storedID: Self.storedID,
                pendingApproval: Fixtures.approvalPayload(command: "make install")))
    }

    /// Reconnect with `batch` as the `session.events.since` answer, and a
    /// conforming post-batch prompt read behind it (nothing pending) so that
    /// only the batch decides which path is taken.
    private func reconnect(
        _ controller: ConversationController, service: ScriptedSessionService,
        with batch: EventReplayBatch
    ) async {
        enqueueReconnectResume(service)
        service.enqueueBatch(batch)
        service.enqueueActivation(
            Fixtures.activateResult(runtimeID: Self.runtimeID, sessionKey: Self.storedID))
        await controller.connectionBecameReady(isReconnect: true)
    }

    /// The fallback: the prompt read is never taken, the resume snapshot owns
    /// the sheets, and nothing the batch carried reached the UI.
    private func expectFallback(
        _ controller: ConversationController, service: ScriptedSessionService,
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        #expect(service.activatedIDs.isEmpty, sourceLocation: sourceLocation)
        #expect(controller.approval?.command == "make install", sourceLocation: sourceLocation)
        #expect(
            !controller.devMessages.contains { $0.text == "batched" },
            sourceLocation: sourceLocation)
    }

    private static func batchedFrames() -> [JSONValue] {
        [Fixtures.messageComplete(sessionID: runtimeID, seq: 11, text: "batched")]
    }

    // MARK: A response that never answered the gap question

    @Test("a batch with no truncated flag is not replayed")
    func missingTruncatedFlagFallsBack() async throws {
        let service = ScriptedSessionService()
        let controller = try await openedController(service: service)

        await reconnect(
            controller, service: service,
            with: Fixtures.replayBatch(Self.batchedFrames(), replacing: "truncated", with: nil))

        expectFallback(controller, service: service)
    }

    @Test("a batch whose truncated flag is not a boolean is not replayed")
    func unreadableTruncatedFlagFallsBack() async throws {
        let service = ScriptedSessionService()
        let controller = try await openedController(service: service)

        await reconnect(
            controller, service: service,
            with: Fixtures.replayBatch(
                Self.batchedFrames(), replacing: "truncated", with: .string("maybe")))

        expectFallback(controller, service: service)
    }

    // MARK: A response that cannot be shown to be about our numbering

    @Test("a batch with no epoch is not replayed against a known epoch")
    func missingEpochFallsBack() async throws {
        let service = ScriptedSessionService()
        let controller = try await openedController(service: service)

        await reconnect(
            controller, service: service,
            with: Fixtures.replayBatch(Self.batchedFrames(), replacing: "epoch", with: nil))

        expectFallback(controller, service: service)
    }

    // MARK: A response that lost frames on the way in

    @Test("a batch containing a frame that does not decode is not replayed")
    func undecodableFrameFallsBack() async throws {
        let service = ScriptedSessionService()
        let controller = try await openedController(service: service)

        // A frame with no `type` — the shape the decoder used to drop
        // silently, leaving the surrounding frames looking complete.
        let frames =
            Self.batchedFrames() + [
                .object([
                    "session_id": .string(Self.runtimeID), "seq": .number(12),
                    "payload": .object(["text": .string("lost")]),
                ])
            ]
        await reconnect(
            controller, service: service,
            with: Fixtures.replayBatch(frames, replacing: "count", with: .number(2)))

        expectFallback(controller, service: service)
    }

    @Test("a batch whose count disagrees with its frames is not replayed")
    func countMismatchFallsBack() async throws {
        let service = ScriptedSessionService()
        let controller = try await openedController(service: service)

        await reconnect(
            controller, service: service,
            with: Fixtures.replayBatch(
                Self.batchedFrames(), replacing: "count", with: .number(4)))

        expectFallback(controller, service: service)
    }

    // MARK: The fallback is a recovery, not just a refusal

    /// Refusing the batch is only safe because the un-replayed path drops the
    /// watermark: a gateway that renumbered from 1 (a restart, or a session
    /// whose ring was evicted) sends seqs far below the old watermark, and a
    /// retained watermark would make the seq gate swallow every one of them.
    @Test("after a refused batch the socket's renumbered frames still apply")
    func refusedBatchDropsTheWatermark() async throws {
        let service = ScriptedSessionService()
        let controller = try await openedController(service: service)

        await reconnect(
            controller, service: service,
            with: Fixtures.replayBatch(Self.batchedFrames(), replacing: "truncated", with: nil))

        controller.handle(
            event: Fixtures.event(
                Fixtures.messageComplete(sessionID: Self.runtimeID, seq: 1, text: "renumbered")))

        #expect(controller.devMessages.contains { $0.text == "renumbered" })
    }

    // MARK: Preservation — the contract's own answer still replays

    @Test("the answer the gateway actually sends is still replayed losslessly")
    func conformingBatchStillReplays() async throws {
        let service = ScriptedSessionService()
        let controller = try await openedController(service: service)

        await reconnect(
            controller, service: service, with: Fixtures.replayBatch(Self.batchedFrames()))

        // The batch was applied and the post-batch prompt read was taken —
        // and that read, not the older resume snapshot, owns the sheets.
        #expect(controller.devMessages.contains { $0.text == "batched" })
        #expect(service.activatedIDs == [Self.runtimeID])
        #expect(controller.approval == nil)
        #expect(service.eventsSinceCalls.map(\.lastSeen) == [Self.watermark])
    }
}
