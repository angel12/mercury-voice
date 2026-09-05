import Foundation
import Testing

@testable import HermesKit

/// The `pending_approval` / `pending_clarify` replay fields of
/// `session.resume` carry the same payloads as the `approval.request` /
/// `clarify.request` events (tui_gateway/server.py `_pending_*_payload`),
/// so the payload initializers must decode exactly like the event path.
@Suite("Pending prompt replay decoding")
struct PendingPromptDecodingTests {
    private func json(_ string: String) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: Data(string.utf8))
    }

    // MARK: pending_approval

    @Test func approvalWithExplicitChoices() throws {
        let payload = try json(
            """
            {"command": "rm -rf build", "description": "Delete the build dir",
             "choices": ["once", "deny"]}
            """)
        let request = ApprovalRequest(payload: payload, sessionID: "sid-1")

        #expect(request?.sessionID == "sid-1")
        #expect(request?.command == "rm -rf build")
        #expect(request?.description == "Delete the build dir")
        #expect(request?.choices == ["once", "deny"])
    }

    /// The gateway stamps `request_id` on every approval entry
    /// (`_ApprovalEntry.__init__`) and `_approval_request_payload` copies the
    /// entry's dict through, so both the event and the `pending_approval`
    /// snapshot field carry it. It is decoded to recognise the same approval
    /// arriving twice; `id` stays the session id because `approval.respond`
    /// is answered session-keyed.
    @Test func approvalCarriesTheRequestIDWhenTheBackendStampsOne() throws {
        let stamped = ApprovalRequest(
            payload: try json(#"{"command": "ls", "request_id": "a1"}"#), sessionID: "sid-1")
        #expect(stamped?.requestID == "a1")
        #expect(stamped?.id == "sid-1")

        // A backend that does not stamp one leaves it nil, and two such
        // approvals must not be assumed to be the same approval.
        let unstamped = ApprovalRequest(payload: try json(#"{"command": "ls"}"#), sessionID: "s")
        #expect(unstamped?.requestID == nil)
    }

    @Test func approvalDerivesChoicesLikeTheServer() throws {
        // allow_* absent means allowed; the full ladder is offered.
        let full = ApprovalRequest(payload: try json(#"{"command": "ls"}"#), sessionID: "s")
        #expect(full?.choices == ["once", "session", "always", "deny"])

        // Explicit denials trim the ladder.
        let trimmed = ApprovalRequest(
            payload: try json(#"{"command": "ls", "allow_permanent": false}"#),
            sessionID: "s")
        #expect(trimmed?.choices == ["once", "session", "deny"])

        // smart_denied collapses to once/deny.
        let denied = ApprovalRequest(
            payload: try json(#"{"command": "curl evil", "smart_denied": true}"#),
            sessionID: "s")
        #expect(denied?.choices == ["once", "deny"])
    }

    @Test func approvalRequiresASessionID() throws {
        #expect(ApprovalRequest(payload: try json(#"{"command": "ls"}"#), sessionID: nil) == nil)
    }

    @Test func approvalEventPathStillDecodes() throws {
        let event = GatewayEvent(
            type: GatewayEvent.Kind.approvalRequest,
            sessionID: "sid-9",
            payload: try json(#"{"command": "make", "choices": ["once", "deny"]}"#))
        let request = ApprovalRequest(event: event)
        #expect(request?.sessionID == "sid-9")
        #expect(request?.choices == ["once", "deny"])
        // Wrong event type still refuses.
        #expect(
            ApprovalRequest(
                event: GatewayEvent(
                    type: GatewayEvent.Kind.clarifyRequest, sessionID: "sid-9",
                    payload: .object([:]))) == nil)
    }

    // MARK: pending_clarify

    @Test func clarifyDecodesFromReplayPayload() throws {
        let payload = try json(
            """
            {"request_id": "req-42", "question": "Which env?",
             "choices": ["dev", "prod"], "multi_select": false}
            """)
        let request = ClarifyRequest(payload: payload, sessionID: "sid-1")

        #expect(request?.requestID == "req-42")
        #expect(request?.sessionID == "sid-1")
        #expect(request?.question == "Which env?")
        #expect(request?.choices == ["dev", "prod"])
        #expect(request?.multiSelect == false)
    }

    @Test func clarifyRequiresARequestID() throws {
        #expect(ClarifyRequest(payload: try json(#"{"question": "?"}"#), sessionID: "s") == nil)
    }

    @Test func clarifyFiltersUnspeakableChoices() throws {
        let payload = try json(
            """
            {"request_id": "req-1", "question": "Pick",
             "choices": ["ok", "", "has\\nnewline"], "multi_select": true}
            """)
        let request = ClarifyRequest(payload: payload, sessionID: nil)
        #expect(request?.choices == ["ok"])
        #expect(request?.multiSelect == true)
        #expect(request?.sessionID == nil)
    }
}
