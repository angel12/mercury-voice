import Foundation
import Testing

@testable import HermesKit

/// `LiveSessionSnapshot` decodes the payload `_live_session_payload` builds
/// (tui_gateway/server.py) for `session.resume` and returns verbatim from
/// `session.activate`. It is the prompt authority for a reconnect that
/// replayed events (issue #75), so what it refuses matters as much as what it
/// accepts: a shape it cannot validate must not read as "nothing pending".
@Suite("Live session snapshot decoding")
struct LiveSessionSnapshotTests {
    private func json(_ string: String) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: Data(string.utf8))
    }

    private let envelope = """
        "session_id": "rt1", "session_key": "st1", "started_at": 1700000000,
        "status": "idle", "running": false
        """

    @Test func decodesPendingPrompts() throws {
        let snapshot = LiveSessionSnapshot(
            result: try json(
                """
                {\(envelope),
                 "pending_approval": {"command": "rm -rf build", "request_id": "a1"},
                 "pending_clarify": {"request_id": "q1", "question": "Which branch?"}}
                """))

        #expect(snapshot?.runtimeID == "rt1")
        #expect(snapshot?.sessionKey == "st1")
        #expect(snapshot?.pendingApproval?["request_id"]?.stringValue == "a1")
        #expect(snapshot?.pendingClarify?["request_id"]?.stringValue == "q1")
    }

    /// The builder writes the pending keys only when there is something
    /// pending (`if value: payload[key] = value`), so an absent key is the
    /// backend's encoding of "no prompt" — there is no null form to decode.
    @Test func absentPendingKeysMeanNothingPending() throws {
        let snapshot = LiveSessionSnapshot(result: try json("{\(envelope)}"))

        #expect(snapshot != nil)
        #expect(snapshot?.pendingApproval == nil)
        #expect(snapshot?.pendingClarify == nil)
    }

    /// `status` is `"waiting"` for *any* blocking prompt family — secrets,
    /// sudo, terminal reads, the tour — while `pending_clarify` is filtered
    /// to `clarify.request` alone. So waiting with no clarify field is a
    /// legitimate state and must decode as one.
    @Test func waitingWithoutAClarifyFieldIsValid() throws {
        let snapshot = LiveSessionSnapshot(
            result: try json(
                """
                {"session_id": "rt1", "session_key": "st1", "started_at": 1700000000,
                 "status": "waiting", "running": true}
                """))

        #expect(snapshot != nil)
        #expect(snapshot?.pendingClarify == nil)
    }

    @Test func refusesPayloadsMissingAnEnvelopeField() throws {
        // Each of these is written unconditionally by the builder, so its
        // absence means the response is not a live-session payload.
        let bodies = [
            #"{"session_key": "st1", "started_at": 1, "status": "idle", "running": false}"#,
            #"{"session_id": "rt1", "started_at": 1, "status": "idle", "running": false}"#,
            #"{"session_id": "rt1", "session_key": "st1", "status": "idle", "running": false}"#,
            #"{"session_id": "rt1", "session_key": "st1", "started_at": 1, "running": false}"#,
            #"{"session_id": "rt1", "session_key": "st1", "started_at": 1, "status": "idle"}"#,
            #"{"session_id": "", "session_key": "st1", "started_at": 1, "status": "idle", "running": false}"#,
        ]
        for body in bodies {
            #expect(LiveSessionSnapshot(result: try json(body)) == nil, "accepted \(body)")
        }
    }

    /// Presence is the backend saying something *is* pending, so a value the
    /// sheet decoders cannot use is an unvalidated shape and must be refused.
    /// Accepting one would clear a live clarify sheet (`ClarifyRequest` is nil
    /// without a string `request_id`, which the caller reads as "answered
    /// elsewhere") or present an approval sheet with nothing in it
    /// (`ApprovalRequest` never fails on content).
    @Test func refusesAPresentButUnusablePromptPayload() throws {
        let bodies = [
            // pending_approval present, not an object.
            #"{"pending_approval": "rm -rf build"}"#,
            #"{"pending_approval": ["rm -rf build"]}"#,
            #"{"pending_approval": 1}"#,
            #"{"pending_approval": true}"#,
            // `if value:` in the builder emits neither of these, so both are
            // shapes it did not produce rather than "nothing pending".
            #"{"pending_approval": null}"#,
            #"{"pending_approval": {}}"#,
            // pending_clarify present, not an object.
            #"{"pending_clarify": "Which branch?"}"#,
            #"{"pending_clarify": ["Which branch?"]}"#,
            #"{"pending_clarify": null}"#,
            #"{"pending_clarify": {}}"#,
            // An object, but with no id to correlate the answer by.
            #"{"pending_clarify": {"question": "Which branch?"}}"#,
            #"{"pending_clarify": {"request_id": "", "question": "Which branch?"}}"#,
            #"{"pending_clarify": {"request_id": 7, "question": "Which branch?"}}"#,
            // A usable prompt does not excuse an unusable one beside it.
            """
            {"pending_approval": {"command": "make install"},
             "pending_clarify": {"question": "Which branch?"}}
            """,
        ]
        for body in bodies {
            let merged = "{\(envelope), \(body.dropFirst())"
            #expect(LiveSessionSnapshot(result: try json(merged)) == nil, "accepted \(body)")
        }
    }

    /// The compatibility half of the same check: the gateway stamps every
    /// approval with a `request_id`, but `ApprovalRequest` treats it as
    /// optional for backends that do not, so validation must not start
    /// requiring one.
    @Test func acceptsAnApprovalWithoutARequestID() throws {
        let snapshot = LiveSessionSnapshot(
            result: try json(
                """
                {\(envelope), "pending_approval": {"command": "make install"}}
                """))

        #expect(snapshot?.pendingApproval?["command"]?.stringValue == "make install")
        #expect(snapshot?.pendingApproval?["request_id"] == nil)
    }

    // MARK: Identity across two reads of the same session

    private func handle(
        runtimeID: String = "rt1", sessionKey: String = "st1", startedAt: Double = 1_700_000_000
    ) -> SessionHandle {
        SessionHandle(
            result: .object([
                "session_id": .string(runtimeID),
                "session_key": .string(sessionKey),
                "started_at": .number(startedAt),
                "status": .string("idle"),
                "running": .bool(false),
            ]))!
    }

    @Test func matchesTheResumeItFollows() throws {
        let snapshot = LiveSessionSnapshot(result: try json("{\(envelope)}"))
        #expect(snapshot?.describesSameSession(as: handle()) == true)
    }

    @Test func refusesARemintedRuntimeID() throws {
        let snapshot = LiveSessionSnapshot(result: try json("{\(envelope)}"))
        // Same short runtime id, different session: `uuid4().hex[:8]` can be
        // reissued after a reap inside one process.
        #expect(snapshot?.describesSameSession(as: handle(startedAt: 1_700_009_999)) == false)
        #expect(snapshot?.describesSameSession(as: handle(sessionKey: "other")) == false)
        #expect(snapshot?.describesSameSession(as: handle(runtimeID: "rt2")) == false)
    }

    /// A resume result from a backend that does not carry the identity fields
    /// cannot be matched, so the reconnect degrades to the un-replayed path
    /// rather than applying a batch it cannot vouch for.
    @Test func refusesAResumeWithoutIdentityFields() throws {
        let snapshot = LiveSessionSnapshot(result: try json("{\(envelope)}"))
        let bare = SessionHandle(result: .object(["session_id": .string("rt1")]))!
        #expect(snapshot?.describesSameSession(as: bare) == false)
    }
}
