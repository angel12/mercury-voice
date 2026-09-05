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
public struct EventReplayBatch: Sendable, Equatable {
    public var events: [GatewayEvent]
    public var latestSeq: Int?
    /// The requested watermark predates the ring buffer — a gap exists, so
    /// the caller must fall back to a full state refresh instead of replaying.
    public var truncated: Bool
    /// Process identity of the seq numbering; compare against the
    /// `replay_epoch` learned at `gateway.ready` — a mismatch means the
    /// backend restarted and every watermark is stale.
    public var epoch: String?

    public init(result: JSONValue) {
        self.events =
            result["events"]?.arrayValue?.compactMap(GatewayEvent.init(eventParams:)) ?? []
        self.latestSeq = result["latest_seq"]?.intValue
        self.truncated = result["truncated"]?.truthy ?? false
        self.epoch = result["epoch"]?.stringValue
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
