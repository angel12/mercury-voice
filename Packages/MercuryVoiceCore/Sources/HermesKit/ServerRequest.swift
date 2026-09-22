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
    /// terminal.read, preview.*, tour, …) is refused on arrival.
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
