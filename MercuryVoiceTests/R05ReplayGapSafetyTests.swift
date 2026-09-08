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
/// The frames themselves carry the rest of the proof, and it used to go
/// unread: `latest_seq` says whether the session is still numbering where the
/// watermark left off (an evicted ring answers 0 while renumbering from 1),
/// and each frame's `seq`/`session_id` say whether the frames in hand really
/// are this session's contiguous run from `watermark + 1`. A batch that fails
/// any of it is refused whole — not frame by frame — so nothing in it is
/// applied and the watermark never advances past what it failed to account
/// for.
///
/// Every gateway that has served this method answers with
/// `events`/`latest_seq`/`truncated`/`count`/`epoch`
/// (`tui_gateway/methods_session.py`), stamps every replayed frame with an
/// ascending per-session `seq` (`event_replay.py`), and `epoch` has been
/// echoed since the same commit that first advertised `replay_epoch` at
/// `gateway.ready` — so requiring them costs no backend that ever worked.
/// Anything short of that takes the fallback the contract already has: drop
/// the watermark, reset the tracker, and let the resume snapshot be the
/// authority.
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

    @Test(arguments: [
        JSONValue.number(0), .number(1), .string("false"), .string("0"), .string("true"),
        .string("1"),
    ])
    func nonBooleanGapRefusesPrefixAndAllowsRedelivery(flag: JSONValue) async throws {
        let service = ScriptedSessionService()
        let controller = try await openedController(service: service)
        await reconnect(
            controller, service: service,
            with: Fixtures.replayBatch(Self.batchedFrames(), replacing: "truncated", with: flag))
        expectFallback(controller, service: service)
        controller.handle(
            event: Fixtures.event(
                Fixtures.messageComplete(sessionID: Self.runtimeID, seq: 11, text: "redelivered")))
        #expect(controller.devMessages.contains { $0.text == "redelivered" })
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

    @Test(arguments: [
        JSONValue?.none, .null, .array([]), .bool(false), .number(7), .string("text"),
    ])
    func malformedPayloadRefusesPrefixAndAllowsRedelivery(payload: JSONValue?) async throws {
        let service = ScriptedSessionService()
        let controller = try await openedController(service: service)
        var frame =
            Fixtures.messageComplete(
                sessionID: Self.runtimeID, seq: 12, text: "invalid"
            ).objectValue ?? [:]
        frame["payload"] = payload
        await reconnect(
            controller, service: service,
            with: Fixtures.replayBatch(Self.batchedFrames() + [.object(frame)]))
        expectFallback(controller, service: service)
        for (seq, text) in [(11, "batched"), (12, "corrected")] {
            controller.handle(
                event: Fixtures.event(
                    Fixtures.messageComplete(sessionID: Self.runtimeID, seq: seq, text: text)))
            #expect(controller.devMessages.contains { $0.text == text })
        }
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

    // MARK: A response that cannot be shown to span the whole gap

    /// The gateway's 64-session FIFO eviction drops a session's ring *and*
    /// its counter (`event_replay.py:57–59`), so `is_truncated` reads False
    /// (`bool(buf)` on a missing ring) and the session renumbers from 1. The
    /// answer is then a perfectly conforming empty batch whose `latest_seq`
    /// is *below* the watermark — the one thing in it that says the numbering
    /// is no longer the one the watermark was taken under. Accepting it keeps
    /// the watermark and the seq gate then swallows the whole renumbered
    /// stream.
    @Test("an evicted ring's empty answer is not replayed, and the renumbered stream survives")
    func evictedRingAnswerFallsBack() async throws {
        let service = ScriptedSessionService()
        let controller = try await openedController(service: service)

        await reconnect(
            controller, service: service, with: Fixtures.replayBatch([], latestSeq: 0))

        expectFallback(controller, service: service)
        controller.handle(
            event: Fixtures.event(
                Fixtures.messageComplete(sessionID: Self.runtimeID, seq: 1, text: "renumbered")))
        #expect(controller.devMessages.contains { $0.text == "renumbered" })
    }

    /// A batch is applied instead of a refresh, so a hole inside it is a
    /// permanent loss: the seq gate would advance past the missing frame as
    /// if it had never been sent. The whole batch is refused — including the
    /// frames on either side of the hole, which is why nothing is applied and
    /// the watermark still lets the socket redeliver frame 11.
    @Test("a batch with a hole in its numbering is refused whole, applying none of it")
    func holedBatchIsRefusedWhole() async throws {
        let service = ScriptedSessionService()
        let controller = try await openedController(service: service)

        await reconnect(
            controller, service: service,
            with: Fixtures.replayBatch([
                Fixtures.messageComplete(sessionID: Self.runtimeID, seq: 11, text: "batched"),
                Fixtures.messageComplete(
                    sessionID: Self.runtimeID, seq: 13, text: "after-the-hole"),
            ]))

        expectFallback(controller, service: service)
        #expect(!controller.devMessages.contains { $0.text == "after-the-hole" })
        // Nothing advanced: the socket can still deliver frame 11 itself.
        controller.handle(
            event: Fixtures.event(
                Fixtures.messageComplete(sessionID: Self.runtimeID, seq: 11, text: "batched")))
        #expect(controller.devMessages.contains { $0.text == "batched" })
    }

    /// Out of order, the earlier frame would be dropped by the seq gate the
    /// later one just advanced — silent loss inside an "accepted" batch.
    @Test("a batch whose frames are out of order is not replayed")
    func outOfOrderBatchFallsBack() async throws {
        let service = ScriptedSessionService()
        let controller = try await openedController(service: service)

        await reconnect(
            controller, service: service,
            with: Fixtures.replayBatch([
                Fixtures.messageComplete(sessionID: Self.runtimeID, seq: 12, text: "second"),
                Fixtures.messageComplete(sessionID: Self.runtimeID, seq: 11, text: "batched"),
            ]))

        expectFallback(controller, service: service)
        #expect(!controller.devMessages.contains { $0.text == "second" })
    }

    /// The replay path calls `apply` directly, bypassing the `ours` filter
    /// that guards live frames — so a frame belonging to another session
    /// would be applied to this conversation, and (having a different session
    /// id) would not even pass the seq gate on its way in.
    @Test("a batch carrying another session's frame is not replayed")
    func foreignSessionFrameFallsBack() async throws {
        let service = ScriptedSessionService()
        let controller = try await openedController(service: service)

        await reconnect(
            controller, service: service,
            with: Fixtures.replayBatch([
                Fixtures.messageComplete(sessionID: Self.runtimeID, seq: 11, text: "batched"),
                Fixtures.messageComplete(sessionID: "rt-other", seq: 12, text: "foreign"),
            ]))

        expectFallback(controller, service: service)
        #expect(!controller.devMessages.contains { $0.text == "foreign" })
    }

    /// A frame with no readable integer `seq` (absent, a string, fractional)
    /// slips through the seq gate without advancing the watermark, and one
    /// numbered backwards is not the next frame either — so neither can be
    /// placed in the run or de-duplicated against the live stream. Every
    /// frame this gateway replays is stamped
    /// (`event_replay.py:50–60`), so one that is not is not its answer.
    @Test(arguments: [JSONValue?.none, .string("12"), .number(12.5), .number(-12)])
    func aFrameWithoutAReadableSeqFallsBack(seq: JSONValue?) async throws {
        let service = ScriptedSessionService()
        let controller = try await openedController(service: service)

        var frame: [String: JSONValue] = [
            "type": .string(GatewayEvent.Kind.messageComplete),
            "session_id": .string(Self.runtimeID),
            "payload": .object(["text": .string("unstamped")]),
        ]
        frame["seq"] = seq
        await reconnect(
            controller, service: service,
            with: Fixtures.replayBatch(
                Self.batchedFrames() + [.object(frame)], latestSeq: 12))

        expectFallback(controller, service: service)
        #expect(!controller.devMessages.contains { $0.text == "unstamped" })
    }

    @Test(arguments: [false, true])
    func incompleteTailRefusesPrefixAndAllowsRedelivery(empty: Bool) async throws {
        let service = ScriptedSessionService()
        let controller = try await openedController(service: service)
        await reconnect(
            controller, service: service,
            with: Fixtures.replayBatch(empty ? [] : Self.batchedFrames(), latestSeq: 12))
        expectFallback(controller, service: service)
        controller.handle(
            event: Fixtures.event(
                Fixtures.messageComplete(sessionID: Self.runtimeID, seq: 11, text: "redelivered")))
        #expect(controller.devMessages.contains { $0.text == "redelivered" })
    }

    @Test func emptyCompleteBatchStillUsesReplay() async throws {
        let service = ScriptedSessionService()
        let controller = try await openedController(service: service)
        await reconnect(
            controller, service: service,
            with: Fixtures.replayBatch([], latestSeq: Self.watermark))
        #expect(service.activatedIDs == [Self.runtimeID])
        #expect(controller.approval == nil)
        controller.handle(
            event: Fixtures.event(
                Fixtures.messageComplete(
                    sessionID: Self.runtimeID, seq: Self.watermark, text: "duplicate")))
        #expect(!controller.devMessages.contains { $0.text == "duplicate" })
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
