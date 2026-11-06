import Foundation

/// Translation between the app's session calls and the `hermes-gateway-v1`
/// wire a v0.23+ **session authority** speaks.
///
/// A socket gets the authority when it lands on the gateway's own listener
/// (the gateway-hosted Webapp, `webapp.enabled`, or the gateway's private
/// loopback `api_origin`); its `gateway.ready` then says
/// `session_authority: true`. Standalone `hermes serve` never attaches one,
/// and everything here is used only on a socket that announced it — the
/// legacy wire is untouched.
///
/// Where the two wires differ (upstream `tui_gateway/contracts/
/// canonical_sessions.py` + `canonical.py`, `gateway/session_controls.py`,
/// live-checked against v0.23.0):
///
/// - `session.create` validates `source` against acp/cli/gui/oneshot/tool/tui
///   and has no `cols`; both refusals are 4001 on the authority.
/// - `prompt.submit` admits only with a client `submission_id`.
/// - `session.interrupt`, `approval.respond` and `clarify.respond` are fenced
///   by `execution_generation`; the two responds take exactly
///   `{session_id, execution_generation, prompt_id, choice|answer}`.
/// - `session.activate` and `session.close` are not served (-32601, no
///   legacy fallback). `session.resume` re-reads the same state and
///   `session.detach {session_id, subscription_id}` drops the attachment.
/// - Create/resume answer a canonical snapshot: pending prompts arrive as
///   `prompts: [{kind, prompt_id, execution_generation, …}]` rather than
///   `pending_approval` / `pending_clarify`, and there is no `session_key`,
///   `started_at` or `status`.
enum AuthorityWire {
    /// `source` the authority accepts for a GUI client.
    static let source = "gui"

    // MARK: Params

    /// Legacy `session.create` params → canonical: drop `cols`, replace the
    /// desktop `source`. cwd, cwd_explicit, profile and title carry over.
    static func createParams(_ legacy: [String: JSONValue]) -> [String: JSONValue] {
        var params = legacy
        params["cols"] = nil
        params["source"] = .string(source)
        return params
    }

    /// `prompt.submit` gains the admission key. `submissionID` is minted once
    /// per submit by the caller so a retry of the same submit dedups.
    static func submitParams(
        _ legacy: [String: JSONValue], submissionID: String
    ) -> [String: JSONValue] {
        var params = legacy
        params["submission_id"] = .string(submissionID)
        return params
    }

    static func interruptParams(sessionID: String, generation: Int) -> JSONValue {
        [
            "session_id": .string(sessionID),
            "execution_generation": .number(Double(generation)),
        ]
    }

    static func approvalParams(
        sessionID: String, generation: Int, promptID: String, choice: String
    ) -> JSONValue {
        [
            "session_id": .string(sessionID),
            "execution_generation": .number(Double(generation)),
            "prompt_id": .string(promptID),
            "choice": .string(choice),
        ]
    }

    static func clarifyParams(
        sessionID: String, generation: Int, promptID: String, answer: String
    ) -> JSONValue {
        [
            "session_id": .string(sessionID),
            "execution_generation": .number(Double(generation)),
            "prompt_id": .string(promptID),
            "answer": .string(answer),
        ]
    }

    /// `session.activate`'s stand-in. The app's resume flags are tolerated
    /// by the canonical resume; `omit_messages` keeps it a cheap re-read.
    static func activateParams(sessionID: String) -> JSONValue {
        ["session_id": .string(sessionID), "omit_messages": .bool(true)]
    }

    static func detachParams(sessionID: String, subscriptionID: String) -> JSONValue {
        ["session_id": .string(sessionID), "subscription_id": .string(subscriptionID)]
    }

    // MARK: Results

    /// A canonical create/resume snapshot, re-expressed in the legacy
    /// live-session payload shape the rest of the app decodes
    /// (`SessionHandle`, `LiveSessionSnapshot`, the pending-prompt adoption).
    /// Every canonical key stays; the legacy keys are added beside them:
    ///
    /// - `session_key` = `stored_session_id`. Authority ids are durable
    ///   (`local-…`), so the runtime and stored ids are the same id.
    /// - `started_at` = `authority_epoch`. It is only ever compared for
    ///   equality between two reads of one session
    ///   (`LiveSessionSnapshot.describesSameSession`); the authority epoch is
    ///   the stamp that changes when the owner restarts, which is the case
    ///   that comparison exists to catch.
    /// - `status` from `running`, which the canonical snapshot always carries.
    /// - `pending_approval` / `pending_clarify` from the first prompt of each
    ///   kind, with `request_id` = `prompt_id` (the id the authority's own
    ///   hosted API uses for it) and the prompt's `execution_generation`.
    ///   Absent when none is pending, matching the legacy encoding.
    static func legacySnapshot(_ result: JSONValue) -> JSONValue {
        guard var object = result.objectValue else { return result }
        if object["session_key"] == nil, let stored = object["stored_session_id"] {
            object["session_key"] = stored
        }
        if object["started_at"] == nil, let epoch = object["authority_epoch"] {
            object["started_at"] = epoch
        }
        if object["status"] == nil, let running = object["running"]?.boolValue {
            object["status"] = .string(running ? "running" : "idle")
        }
        let prompts = object["prompts"]?.arrayValue ?? []
        if object["pending_approval"] == nil,
            let approval = prompts.first(where: { $0["kind"]?.stringValue == "approval" }),
            let payload = legacyPrompt(approval)
        {
            object["pending_approval"] = payload
        }
        if object["pending_clarify"] == nil,
            let clarify = prompts.first(where: { $0["kind"]?.stringValue == "clarify" }),
            let payload = legacyPrompt(clarify)
        {
            object["pending_clarify"] = payload
        }
        return .object(object)
    }

    /// A canonical pending prompt with the legacy `request_id` beside its
    /// `prompt_id`; nil when it has no usable id.
    static func legacyPrompt(_ prompt: JSONValue) -> JSONValue? {
        guard var object = prompt.objectValue,
            let promptID = object["prompt_id"]?.stringValue, !promptID.isEmpty
        else { return nil }
        if object["request_id"] == nil { object["request_id"] = .string(promptID) }
        return .object(object)
    }
}
