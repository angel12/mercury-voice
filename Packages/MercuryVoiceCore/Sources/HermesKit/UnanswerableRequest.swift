import Foundation

/// A server→client request (contract ≥ 7) that waits on the *user* for
/// something this app does not collect: a sudo password, a secret, a vault
/// prompt, or an approval/clarify whose params it cannot decode (#130).
///
/// The app never answers these on its own: the first response settles a
/// request for every attached client, and a client cannot tell whether a
/// desktop that could answer it is attached (upstream keeps
/// `_answering_clients` server-side). So it shows the user what was asked,
/// and the user either declines — `declineResult`, the backend's own
/// "skipped" answer — or leaves it for another client or the deadline.
///
/// Desktop GUI bridges (`terminal.read`, `preview.*`, `window.read`, `tour`)
/// are not user questions and never decode here. Declining one would also
/// do harm: an empty `tour` answer marks the tour bridge unavailable for the
/// rest of the session (upstream `_tour_request`).
public struct UnanswerableRequest: Sendable, Equatable, Identifiable {
    /// One labelled line of what was asked.
    public struct Detail: Sendable, Equatable, Hashable {
        public var label: String
        public var value: String
        /// Commands, env vars, origins: shown in a code font.
        public var monospaced: Bool

        public init(label: String, value: String, monospaced: Bool = false) {
            self.label = label
            self.value = value
            self.monospaced = monospaced
        }
    }

    /// The `srq-<hex>` id, answered through `request.answer`.
    public var id: String
    public var method: String
    public var sessionID: String?
    public var title: String
    public var details: [Detail]
    /// What Decline sends as `request.answer`'s `result`.
    public var declineResult: JSONValue
    /// The line spoken when the sheet comes up.
    public var spokenNotice: String

    /// The one-string prompts (`ValueResult`, `''` = skipped) this type
    /// renders. Everything else except an undecodable approval/clarify is
    /// not shown.
    public static let promptMethods: Set<String> = [
        "sudo", "secret", "vault.unlock_prompt", "vault.save_login", "vault.code",
    ]

    public init?(serverRequest request: ServerRequest) {
        let params = request.params
        let text = { (key: String) -> String? in
            guard let value = params[key]?.stringValue, !value.isEmpty else { return nil }
            return value
        }
        let skipped: JSONValue = .object(["value": .string("")])
        var details: [Detail] = []
        func add(_ label: String, _ value: String?, monospaced: Bool = false) {
            if let value { details.append(Detail(label: label, value: value, monospaced: monospaced)) }
        }

        switch request.method {
        case "sudo":
            title = "Hermes needs your sudo password"
            spokenNotice = "Hermes needs a sudo password."
            add("Command", text("command"), monospaced: true)
            declineResult = skipped
        case "secret":
            title = "Hermes needs a secret value"
            spokenNotice = "Hermes needs a secret value."
            add("Variable", text("env_var"), monospaced: true)
            add("Prompt", text("prompt"))
            // Only one-line metadata values; nested structures are left out.
            for (key, value) in (params["metadata"]?.objectValue ?? [:]).sorted(by: { $0.key < $1.key }) {
                add(key, Self.scalarText(value))
            }
            declineResult = skipped
        case "vault.unlock_prompt":
            let name = text("display_name")
            title = "Hermes wants to unlock \(name ?? "a password manager")"
            spokenNotice = "Hermes wants to unlock a password manager."
            add("Backend", text("backend"), monospaced: true)
            declineResult = skipped
        case "vault.save_login":
            title = "Hermes wants to save a login"
            spokenNotice = "Hermes wants to save a login."
            add("Site", text("site"))
            add("Origin", text("origin"), monospaced: true)
            declineResult = skipped
        case "vault.code":
            title = "Hermes needs a one-time code"
            spokenNotice = "Hermes needs a one-time code."
            add("Site", text("site"))
            add("Hint", text("hint"))
            declineResult = skipped
        case "approval":
            guard ApprovalRequest(serverRequest: request) == nil else { return nil }
            title = "Hermes is asking for approval"
            spokenNotice = "Hermes is asking for approval to run a command."
            add("Command", text("command"), monospaced: true)
            add("Description", text("description"))
            declineResult = .object(["choice": .string("deny")])
        case "clarify":
            guard ClarifyRequest(serverRequest: request) == nil else { return nil }
            if let questions = params["questions"]?.arrayValue {
                title = "Hermes has questions for you"
                spokenNotice = "Hermes has questions for you."
                for (index, entry) in questions.enumerated() {
                    add("Question \(index + 1)", entry["question"]?.stringValue)
                }
                // `ClarifyResult` with neither `answer` nor `answers` is
                // cancel-all for a batch.
                declineResult = .object([:])
            } else {
                title = "Hermes has a question for you"
                spokenNotice = "Hermes has a question for you."
                add("Question", text("question"))
                declineResult = .object(["answer": .string("")])
            }
        default:
            return nil
        }

        self.id = request.id
        self.method = request.method
        self.sessionID = request.sessionID
        self.details = details
        self.spokenNotice += " Answer it on another device, or decline."
    }

    private static func scalarText(_ value: JSONValue) -> String? {
        switch value {
        case .string(let string): return string.isEmpty ? nil : string
        case .bool(let bool): return bool ? "true" : "false"
        case .number(let number):
            return number.rounded() == number && abs(number) < 1e15
                ? String(Int(number)) : String(number)
        default: return nil
        }
    }
}
