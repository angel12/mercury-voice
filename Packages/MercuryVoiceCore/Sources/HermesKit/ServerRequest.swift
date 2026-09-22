import Foundation

/// A server→client JSON-RPC request (desktop contract ≥ 7): the backend asks
/// this client a question and waits for an answer keyed by `id`
/// (`srq-<12hex>`, tui_gateway/server_requests.py). Answered through
/// `request.answer` (see `SessionAPI.answerServerRequest`), withdrawn by a
/// `request.cancel {id, method, reason}` event.
public struct ServerRequest: Sendable, Equatable {
    public var id: String
    public var method: String
    public var sessionID: String?
    public var params: JSONValue

    /// Methods this app renders. Every other request (sudo, secret, vault.*,
    /// terminal.read, preview.*, tour, …) is dropped unanswered and left for
    /// another attached client: the first response settles a request for
    /// every client, so a refusal would take it from a desktop that can
    /// answer it. If the phone is the only client, the request waits out its
    /// server-side deadline (upstream `_ask`) — failing fast while another
    /// advertising client may be attached would need an upstream change.
    public static let answerableMethods: Set<String> = ["approval", "clarify"]

    /// A live frame: has `method`, and a *string* id (client ids are ints).
    public init?(frame: JSONValue) {
        guard let method = frame["method"]?.stringValue, method != "event",
            let id = frame["id"]?.stringValue
        else { return nil }
        self.init(id: id, method: method, params: frame["params"] ?? .object([:]))
    }

    /// An `open_requests` entry — `ServerRequest.snapshot()` — same shape.
    public init?(snapshot: JSONValue) {
        guard let id = snapshot["id"]?.stringValue,
            let method = snapshot["method"]?.stringValue
        else { return nil }
        self.init(id: id, method: method, params: snapshot["params"] ?? .object([:]))
    }

    public init?(event: GatewayEvent) {
        guard event.type == GatewayEvent.Kind.serverRequest else { return nil }
        self.init(snapshot: event.payload)
    }

    init(id: String, method: String, params: JSONValue) {
        self.id = id
        self.method = method
        self.params = params
        self.sessionID = params["session_id"]?.stringValue
    }
}

/// Outcome of `SessionAPI.answerServerRequest`: the server acknowledges every
/// `request.answer` with `status: ok|expired` rather than a bare reply, since
/// the answer can arrive from a reconnected socket that never saw the
/// request (`open_requests` replay) and the caller needs to know whether it
/// still landed.
public enum ServerRequestAnswer: Sendable, Equatable {
    case answered
    case expired

    /// The JSON-RPC method name — a shared constant so the wire method and
    /// the params shape below cannot drift apart from what
    /// `SessionAPI.answerServerRequest` actually sends.
    public static let method = "request.answer"

    /// `request.answer` params: exactly `id` and `result` — the server
    /// rejects undeclared keys with error 4000, so nothing else may be
    /// added here.
    public static func answerParams(id: String, result: JSONValue) -> JSONValue {
        .object(["id": .string(id), "result": result])
    }

    /// Maps a `request.answer` reply: `status == "expired"` → `.expired`,
    /// anything else (`"ok"`, an unknown value, or an absent/unreadable
    /// field) → `.answered` — the server's only documented failure mode for
    /// this call is expiry, so an unrecognised status is read as success
    /// rather than silently swallowed.
    public init(reply: JSONValue) {
        self = reply["status"]?.stringValue == "expired" ? .expired : .answered
    }
}

extension GatewayEvent {
    /// Carries a server request down the event pipeline so it inherits the
    /// controller's replay hold and prompt-family handling. Never seq-stamped.
    public init(serverRequest request: ServerRequest) {
        self.init(
            type: Kind.serverRequest,
            sessionID: request.sessionID,
            payload: .object([
                "id": .string(request.id),
                "method": .string(request.method),
                "params": request.params,
            ]))
    }
}
