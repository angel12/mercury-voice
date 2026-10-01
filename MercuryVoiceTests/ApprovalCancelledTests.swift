import HermesKit
import Testing

@testable import MercuryVoice

/// Issue #146 item 4 (upstream 591e3a7ce1): `approval.cancelled` is a
/// broadcast saying an interrupt, reap or teardown deny-resolved pending
/// approvals. `request.cancel` usually takes the sheet down first; this
/// catches the rest (a legacy `approval.request` sheet has no srq id for
/// `request.cancel` to match), so the user is never left answering an
/// approval that no longer exists. `request_ids` are the approval queue's
/// own ids — `ApprovalRequest.requestID`, not the `srq-` id.
@MainActor
struct ApprovalCancelledTests {
    private func openController(_ service: ScriptedSessionService) async throws
        -> ConversationController
    {
        service.enqueueCreate(Fixtures.resumeResult(runtimeID: "rt", storedID: "stored"))
        let controller = makeController(service: service)
        try await controller.openSession(mode: .create(cwd: nil, title: nil))
        return controller
    }

    private func presentLegacyApproval(_ controller: ConversationController, requestID: String?) {
        controller.handle(
            event: Fixtures.event(
                Fixtures.approvalRequest(
                    sessionID: "rt", seq: 1, command: "rm -rf /tmp/x", requestID: requestID)))
    }

    /// Broadcast frame: no top-level session_id, the session is in the payload.
    private func cancelled(
        sessionID: String = "rt", storedID: String = "stored", requestIDs: [String]
    ) -> GatewayEvent {
        Fixtures.event([
            "type": .string("approval.cancelled"),
            "payload": .object([
                "session_id": .string(sessionID),
                "stored_session_id": .string(storedID),
                "reason": "interrupt",
                "cancelled_count": .number(Double(max(requestIDs.count, 1))),
                "request_ids": .array(requestIDs.map(JSONValue.string)),
            ]),
        ])
    }

    @Test func aCancelledApprovalTakesTheSheetDown() async throws {
        let controller = try await openController(ScriptedSessionService())
        presentLegacyApproval(controller, requestID: "a1")
        #expect(controller.approval != nil)

        controller.handle(event: cancelled(requestIDs: ["a1"]))
        #expect(controller.approval == nil)
        await controller.teardown()
    }

    /// A cancelled id never wipes a newer approval re-armed on the session.
    @Test func anotherApprovalsCancellationLeavesTheSheetUp() async throws {
        let controller = try await openController(ScriptedSessionService())
        presentLegacyApproval(controller, requestID: "a2")

        controller.handle(event: cancelled(requestIDs: ["a1"]))
        #expect(controller.approval?.requestID == "a2")
        await controller.teardown()
    }

    /// No correlation ids on the wire: drop the session's approval
    /// wholesale, as the desktop does.
    @Test func noRequestIDsClearsTheSessionsApproval() async throws {
        let controller = try await openController(ScriptedSessionService())
        presentLegacyApproval(controller, requestID: nil)

        controller.handle(event: cancelled(requestIDs: []))
        #expect(controller.approval == nil)
        await controller.teardown()
    }

    @Test func anotherSessionsCancellationIsIgnored() async throws {
        let controller = try await openController(ScriptedSessionService())
        presentLegacyApproval(controller, requestID: "a1")

        controller.handle(
            event: cancelled(sessionID: "other", storedID: "other-stored", requestIDs: ["a1"]))
        #expect(controller.approval != nil)
        await controller.teardown()
    }
}
