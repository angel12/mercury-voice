import Foundation

/// A server-push event from `/api/ws`: a JSON-RPC notification with
/// `method == "event"` whose real name is `params.type`.
public struct GatewayEvent: Sendable, Equatable {
    public var type: String
    public var sessionID: String?
    public var payload: JSONValue
    /// Per-session monotonic stamp (event_replay.py). Present on session
    /// events from current gateways; nil on global events and old backends.
    public var seq: Int?

    public init(type: String, sessionID: String?, payload: JSONValue, seq: Int? = nil) {
        self.type = type
        self.sessionID = sessionID
        self.payload = payload
        self.seq = seq
    }

    /// Decode one event-frame `params` object ({type, session_id, seq,
    /// payload}) — the shape both the live socket and the
    /// `session.events.since` replay batches carry.
    public init?(eventParams params: JSONValue) {
        guard let type = params["type"]?.stringValue else { return nil }
        self.init(
            type: type,
            sessionID: params["session_id"]?.stringValue,
            payload: params["payload"] ?? .null,
            seq: params["seq"]?.intValue)
    }

    /// Well-known event names (open set — unknown types must be tolerated).
    public enum Kind {
        public static let gatewayReady = "gateway.ready"
        public static let messageStart = "message.start"
        public static let messageDelta = "message.delta"
        public static let messageInterim = "message.interim"
        public static let messageComplete = "message.complete"
        public static let thinkingDelta = "thinking.delta"
        public static let toolStart = "tool.start"
        public static let toolComplete = "tool.complete"
        public static let statusUpdate = "status.update"
        public static let sessionUsage = "session.usage"
        public static let approvalRequest = "approval.request"
        public static let clarifyRequest = "clarify.request"
        public static let clarifyExpire = "clarify.expire"
        public static let sessionInfo = "session.info"
        public static let sessionResumeProgress = "session.resume_progress"
        public static let sessionTitle = "session.title"
        public static let notificationShow = "notification.show"
        public static let sessionReclaimed = "session.reclaimed"
        public static let error = "error"
    }
}

/// Result of `session.events.since` — the missed-event replay a reconnecting
/// client requests with its last observed seq.
///
/// A batch is applied *instead of* a full refresh, so everything it does not
/// carry is taken to have never happened. Decoding is therefore fail-closed:
/// the gateway answers every call with `events`, `latest_seq`, `truncated`,
/// `count` and `epoch` (`tui_gateway/methods_session.py`), and a response that
/// leaves any of the gap questions unanswered is reported as unusable rather
/// than read as a reassuring default. `isLossless(under:forSession:after:)` is
/// that verdict.
public struct EventReplayBatch: Sendable, Equatable {
    public var events: [GatewayEvent]
    public var latestSeq: Int?
    /// The requested watermark predates the ring buffer — a gap exists, so
    /// the caller must fall back to a full state refresh instead of replaying.
    /// Also true when the response never answered the question: an absent or
    /// unreadable field is not a "no gap".
    public var truncated: Bool
    /// Process identity of the seq numbering; compare against the
    /// `replay_epoch` learned at `gateway.ready` — a mismatch means the
    /// backend restarted and every watermark is stale.
    public var epoch: String?
    /// The response could not be read as a whole batch: `events` absent or
    /// not an array, an entry that is not a decodable event frame, an
    /// unreadable `truncated`, or a `count` disagreeing with the entries
    /// decoded. The frames in hand are then a subset of what was sent — a
    /// gap, not a replay.
    public var malformed: Bool

    public init(result: JSONValue) {
        let entries = result["events"]?.arrayValue
        let decoded = entries?.compactMap(GatewayEvent.init(eventParams:)) ?? []
        self.events = decoded
        self.latestSeq = result["latest_seq"]?.intValue
        let gap = Self.boolean(result["truncated"])
        self.truncated = gap ?? true
        self.epoch = result["epoch"]?.stringValue
        // `count` is the gateway's own tally of what it put in `events`
        // (`len(frames)`), so it is the one field that can contradict an
        // entry dropped on the way in. A backend that omits it says nothing,
        // and the per-entry check already covers the drop.
        let countField = result["count"]
        self.malformed =
            gap == nil
            || entries == nil
            || entries?.count != decoded.count
            || (countField != nil && countField?.intValue != decoded.count)
    }

    /// Whether these frames are provably every event after `watermark`, for
    /// `sessionID`, under the epoch `expected` — the identity and numbering
    /// the watermark was taken with. False is not "an error occurred": it is
    /// "this answer is not evidence that nothing was missed", and the caller
    /// must refresh instead of replaying.
    ///
    /// What a conforming answer from the gateway always satisfies, and what
    /// is therefore required here (`tui_gateway/event_replay.py`,
    /// `methods_session.py`, `server.py:write_json`):
    ///
    /// - The epoch is present and equal. It has been echoed here since the
    ///   same gateway commit that first advertised `replay_epoch` at
    ///   `gateway.ready`, so a caller holding an epoch is by construction
    ///   talking to a gateway that returns one; an older backend leaves the
    ///   caller with no epoch at all and never reaches this check.
    /// - `latest_seq` is the session's current highest stamp, read straight
    ///   after the frames, so it is never below the watermark the client
    ///   reached — *unless* the ring was evicted, which drops the counter
    ///   with it (`_replay_next_seq.pop`) and restarts the session at 1 while
    ///   `truncated` reads False because the ring is simply gone. A
    ///   `latest_seq` below the watermark (0 for an evicted session), or one
    ///   that is absent or unreadable, is the only trace that renumbering
    ///   leaves, so it is refused.
    /// - Every replayed frame is stamped with an integer `seq` and carries
    ///   the session id it was requested for (`_stamp_event` only records
    ///   frames with a session id, and `events_since` reads that session's
    ///   ring), the ring ascends by exactly one, and `truncated == false`
    ///   means the first frame returned is `watermark + 1`. So the frames
    ///   must be the contiguous run `watermark + 1 … latest_seq`: a hole, a
    ///   repeat, a reordering, an unstamped or fractional seq, or a frame
    ///   from another session invalidates the batch as a whole rather than
    ///   the frame alone — the caller applies all of it or none of it.
    ///
    /// Residual, and a backend limitation rather than something a client can
    /// see: a session whose ring was evicted and has since emitted more than
    /// `watermark` new events answers exactly like a real continuation. Only
    /// a per-session epoch (or an `is_truncated` that reported a missing
    /// ring) could distinguish it.
    public func isLossless(
        under expected: String, forSession sessionID: String, after watermark: Int
    ) -> Bool {
        guard !truncated, !malformed, epoch == expected else { return false }
        // Seqs start at 1, so a watermark below 0 was never stamped by this
        // contract, and `latest` must still be at or past where we got to.
        guard watermark >= 0, let latest = latestSeq, latest >= watermark else { return false }
        var previous = watermark
        for event in events {
            guard event.sessionID == sessionID, let seq = event.seq else { return false }
            // `previous + 1` unchecked would trap on a watermark at Int.max.
            let (next, overflowed) = previous.addingReportingOverflow(1)
            guard !overflowed, seq == next else { return false }
            previous = next
        }
        return previous <= latest
    }

    /// A JSON boolean, or the loose spellings a Python backend may use for
    /// one; nil for anything that is not a boolean at all — including a
    /// missing field, which for `truncated` means the gap question went
    /// unanswered.
    private static func boolean(_ value: JSONValue?) -> Bool? {
        switch value {
        case .bool(let flag): return flag
        case .number(let number) where number == 0 || number == 1: return number == 1
        case .string(let text):
            switch text.lowercased() {
            case "true", "1": return true
            case "false", "0": return false
            default: return nil
            }
        default: return nil
        }
    }
}

// MARK: - Typed payloads

/// `approval.request` — answered session-keyed with
/// `approval.respond {session_id, choice}`, which resolves the *oldest*
/// queued approval for the session, so `id` stays the session id.
///
/// The payload does carry a gateway-assigned `request_id`
/// (`_ApprovalEntry.__init__` stamps one, and `_approval_request_payload`
/// copies the entry's dict through to both the event and the
/// `pending_approval` snapshot field). It is decoded only to recognise the
/// same approval arriving twice — once in a prompt snapshot and once as a
/// live frame — and is deliberately not used to address a response; that the
/// app answers oldest-first while showing the newest frame is a separate
/// defect, tracked on its own.
public struct ApprovalRequest: Sendable, Equatable, Identifiable {
    public var sessionID: String
    /// `request_id` when the backend stamps one; nil on a backend that does
    /// not, where two approvals cannot be told apart.
    public var requestID: String?
    public var command: String?
    public var description: String?
    /// Server-derived subset of once/session/always/deny.
    public var choices: [String]

    public var id: String { sessionID }

    public init?(event: GatewayEvent) {
        guard event.type == GatewayEvent.Kind.approvalRequest else { return nil }
        self.init(payload: event.payload, sessionID: event.sessionID)
    }

    /// Also decodes the `pending_approval` replay field of `session.resume`
    /// (same payload shape; the session id comes from the resume handle).
    public init?(payload: JSONValue, sessionID: String?) {
        guard let sessionID else { return nil }
        self.sessionID = sessionID
        self.requestID = payload["request_id"]?.stringValue
        self.command = payload["command"]?.stringValue
        self.description = payload["description"]?.stringValue

        if let listed = payload["choices"]?.arrayValue?.compactMap(\.stringValue),
            !listed.isEmpty
        {
            self.choices = listed
        } else {
            // Derive like the server does when choices is absent:
            // allow_permanent/allow_session absent mean *allowed* (!= false).
            var derived = ["once"]
            if payload["smart_denied"]?.truthy != true {
                if payload["allow_session"]?.boolValue != false { derived.append("session") }
                if payload["allow_permanent"]?.boolValue != false { derived.append("always") }
            }
            derived.append("deny")
            self.choices = derived
        }
    }
}

/// `clarify.request` — correlated by `request_id`; may be cleared by a
/// matching `clarify.expire`. Empty answer = skip.
public struct ClarifyRequest: Sendable, Equatable, Identifiable {
    public var requestID: String
    public var sessionID: String?
    public var question: String
    /// nil/empty = free-text question.
    public var choices: [String]
    public var multiSelect: Bool

    public var id: String { requestID }

    public init?(event: GatewayEvent) {
        guard event.type == GatewayEvent.Kind.clarifyRequest else { return nil }
        self.init(payload: event.payload, sessionID: event.sessionID)
    }

    /// Also decodes the `pending_clarify` replay field of `session.resume`
    /// (same payload shape, `request_id` included).
    public init?(payload: JSONValue, sessionID: String?) {
        guard let requestID = payload["request_id"]?.stringValue else { return nil }
        self.requestID = requestID
        self.sessionID = sessionID
        self.question = payload["question"]?.stringValue ?? ""
        self.choices =
            payload["choices"]?.arrayValue?
            .compactMap(\.stringValue)
            .filter { !$0.isEmpty && $0.count <= 200 && !$0.contains("\n") } ?? []
        self.multiSelect = payload["multi_select"]?.truthy ?? false
    }
}
