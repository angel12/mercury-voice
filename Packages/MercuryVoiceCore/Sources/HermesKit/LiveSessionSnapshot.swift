import Foundation

/// The prompt half of the gateway's live-session payload — the shape
/// `_live_session_payload` builds for `session.resume` and returns verbatim
/// from `session.activate`.
///
/// This exists so a *re-read* of the prompt registry can be taken after a
/// replay batch has been fetched, and used for the approval/clarify sheets
/// and nothing else (issue #75). Only the fields that decision needs are
/// surfaced: the transcript, hydration and `running` fields of the same
/// payload are deliberately absent, so a caller cannot accidentally let a
/// second read replace the session handle it resumed with.
///
/// ## Encoding this decodes against
///
/// The builder writes the pending fields as
/// `for key, value in (...): if value: payload[key] = value`, so **"nothing
/// pending" is the key being absent** — never `null`, and never an empty
/// object. `pendingApproval`/`pendingClarify` are therefore nil in exactly
/// that case, and a nil is a real "no prompt", not a missing answer.
///
/// The consequence is that a backend which builds the same envelope but does
/// not implement the prompt fields at all is **indistinguishable** from one
/// with nothing pending; a client cannot detect that difference without a
/// capability or version guarantee the contract does not offer. The envelope
/// check below establishes that *a* live-session payload came back, not that
/// its producer implements the same prompt semantics.
public struct LiveSessionSnapshot: Sendable, Equatable {
    /// `session_id` — the runtime id, not the stored one.
    public var runtimeID: String
    /// `session_key` — the durable id the runtime is bound to.
    public var sessionKey: String
    /// `started_at`, kept as raw JSON: it is only ever compared for equality
    /// with the value another read of the same payload reported, so nothing
    /// here depends on its numeric type.
    public var startedAt: JSONValue
    /// `pending_approval`, or nil when the key is absent (nothing pending).
    public var pendingApproval: JSONValue?
    /// `pending_clarify`, or nil when the key is absent (nothing pending).
    public var pendingClarify: JSONValue?

    /// Fails when the response is not a live-session payload: every field
    /// checked here is written unconditionally by the builder, so a missing
    /// one means an unvalidated shape rather than an empty registry. `status`
    /// and `running` are required for that reason and then discarded —
    /// `status == "waiting"` is *not* evidence about the clarify field, since
    /// it is set for any blocking prompt type (`secret.request`,
    /// `sudo.request`, `terminal.read.request`, …) while the clarify field is
    /// filtered to `clarify.request` alone.
    ///
    /// A *present* pending key is validated too, because presence is the
    /// backend asserting that something **is** pending: a value the sheet
    /// decoders cannot use is an unvalidated shape, not an empty registry.
    /// Passing one through would do the very damage this type exists to
    /// prevent — `ClarifyRequest` returns nil without a string `request_id`,
    /// which the caller reads as "answered elsewhere" and clears a live
    /// sheet, and `ApprovalRequest` never fails on content, so it would put
    /// an approval sheet on screen with nothing in it. Refusing instead makes
    /// `activateSession` throw, and the reconnect takes the un-replayed
    /// fallback, which is the conservative direction.
    public init?(result: JSONValue) {
        guard let runtimeID = result["session_id"]?.stringValue, !runtimeID.isEmpty,
            let sessionKey = result["session_key"]?.stringValue, !sessionKey.isEmpty,
            let startedAt = result["started_at"], startedAt != .null,
            result["status"]?.stringValue != nil,
            result["running"]?.boolValue != nil
        else { return nil }

        // No `request_id` is demanded of an approval: the gateway stamps one
        // (`approval_gateway_wait.py`), but `ApprovalRequest` carries it as
        // optional for backends that do not, and this must not become the
        // check that breaks them.
        let approvalField = result["pending_approval"]
        if let approvalField, !Self.carriesAPrompt(approvalField) { return nil }

        // Clarify is correlated *by* `request_id` — without one there is no
        // prompt to adopt, only a sheet to wrongly clear.
        let clarifyField = result["pending_clarify"]
        if let clarifyField {
            guard Self.carriesAPrompt(clarifyField),
                let requestID = clarifyField["request_id"]?.stringValue, !requestID.isEmpty
            else { return nil }
        }

        self.runtimeID = runtimeID
        self.sessionKey = sessionKey
        self.startedAt = startedAt
        self.pendingApproval = approvalField
        self.pendingClarify = clarifyField
    }

    /// A non-empty JSON object, which is the only thing the builder can write
    /// for a present pending key: it emits the key under `if value:`, so both
    /// `null` and `{}` are falsy and never produced. Both are refused here for
    /// that reason, leaving **absent** as the sole "nothing pending"
    /// encoding — a backend that sends `null` for it loses lossless replay,
    /// which is the same cost as any other unvalidated shape.
    private static func carriesAPrompt(_ value: JSONValue) -> Bool {
        value.objectValue?.isEmpty == false
    }

    /// True when this snapshot came from the same runtime session, in the
    /// same process, as the `session.resume` that produced `handle`.
    ///
    /// Runtime ids are `uuid4().hex[:8]` and a restart drops the socket, so
    /// an id match already implies the same process in practice; `started_at`
    /// and `session_key` close the reap-and-remint case, where the same short
    /// id could be reissued to a different session within one process.
    ///
    /// Every field compared here is written by the same builder from the same
    /// session dict, so two reads of one live session agree exactly. Anything
    /// that makes them disagree — including a backend whose resume result
    /// omits them — costs the caller its lossless replay and nothing more.
    public func describesSameSession(as handle: SessionHandle) -> Bool {
        runtimeID == handle.runtimeID
            && handle.raw["session_key"] == .string(sessionKey)
            && handle.raw["started_at"] == startedAt
    }
}
