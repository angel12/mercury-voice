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

    // MARK: Server requests (contract ≥ 7)

    @Test func approvalDecodesFromAServerRequest() throws {
        let request = ServerRequest(
            id: "srq-0123456789ab", method: "approval",
            params: try json(
                #"{"session_id": "s1", "request_id": "a1", "command": "ls", "choices": ["once", "deny"]}"#
            ))
        let approval = try #require(ApprovalRequest(serverRequest: request))
        #expect(approval.serverRequestID == "srq-0123456789ab")
        #expect(approval.sessionID == "s1")
        #expect(approval.requestID == "a1")
        #expect(approval.command == "ls")
        #expect(approval.choices == ["once", "deny"])
    }

    @Test func approvalRefusesANonApprovalServerRequest() throws {
        let request = ServerRequest(
            id: "srq-0123456789ab", method: "clarify",
            params: try json(#"{"session_id": "s1"}"#))
        #expect(ApprovalRequest(serverRequest: request) == nil)
    }

    @Test func clarifyDecodesASingleQuestionServerRequest() throws {
        let request = ServerRequest(
            id: "srq-111111111111", method: "clarify",
            params: try json(
                """
                {"session_id": "s1", "question": "Which env?",
                 "choices": ["dev", "prod"], "multi_select": false}
                """))
        let clarify = try #require(ClarifyRequest(serverRequest: request))
        #expect(clarify.requestID == "srq-111111111111")
        #expect(clarify.serverRequestID == "srq-111111111111")
        #expect(clarify.sessionID == "s1")
        #expect(clarify.question == "Which env?")
        #expect(clarify.choices == ["dev", "prod"])
        #expect(clarify.multiSelect == false)
        #expect(clarify.questions.isEmpty)
        #expect(clarify.lockedAnswers.isEmpty)
    }

    @Test func clarifyDecodesABatchServerRequest() throws {
        let request = ServerRequest(
            id: "srq-222222222222", method: "clarify",
            params: try json(
                """
                {"session_id": "s1",
                 "questions": [
                   {"qid": "q1", "question": "Which env?", "choices": ["dev", "prod"]},
                   {"qid": "q2", "question": "Which branch?", "multi_select": true}
                 ],
                 "answers": {"q1": "dev"}}
                """))
        let clarify = try #require(ClarifyRequest(serverRequest: request))
        #expect(clarify.requestID == "srq-222222222222")
        #expect(clarify.serverRequestID == "srq-222222222222")
        // A batch's own question/choices are not "the first question" — the
        // per-question data lives in `questions` instead.
        #expect(clarify.question == "")
        #expect(clarify.choices == [])
        #expect(clarify.questions.count == 2)
        #expect(clarify.questions[0] == ClarifyQuestion(qid: "q1", question: "Which env?", choices: ["dev", "prod"], multiSelect: false))
        #expect(clarify.questions[1] == ClarifyQuestion(qid: "q2", question: "Which branch?", choices: [], multiSelect: true))
        #expect(clarify.lockedAnswers == ["q1": "dev"])
    }

    /// A dropped question would still let the caller submit `{answers}` for
    /// the ones it did see — a batch that looks complete to the backend
    /// while actually short one answer. So one undecodable entry (here,
    /// missing `qid`) must refuse the whole request, not just that entry.
    @Test func clarifyBatchFailsClosedOnAnUndecodableQuestion() throws {
        let request = ServerRequest(
            id: "srq-444444444444", method: "clarify",
            params: try json(
                """
                {"session_id": "s1",
                 "questions": [
                   {"qid": "q1", "question": "Which env?"},
                   {"question": "Which branch?"}
                 ]}
                """))
        #expect(ClarifyRequest(serverRequest: request) == nil)
    }

    @Test func clarifyBatchFailsClosedOnAnEmptyQuestionsArray() throws {
        let request = ServerRequest(
            id: "srq-555555555555", method: "clarify",
            params: try json(#"{"session_id": "s1", "questions": []}"#))
        #expect(ClarifyRequest(serverRequest: request) == nil)
    }

    @Test func clarifyRefusesANonClarifyServerRequest() throws {
        let request = ServerRequest(
            id: "srq-333333333333", method: "approval",
            params: try json(#"{"session_id": "s1"}"#))
        #expect(ClarifyRequest(serverRequest: request) == nil)
    }
}
