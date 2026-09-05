import Foundation

/// Input state for the Connect screen's server and token fields.
///
/// A token lifted out of a pasted dashboard URL belongs to the endpoint that
/// printed it. Point the server field somewhere else and that token is
/// dropped rather than sent on to the new server: the token field is
/// secure-entry, so a credential carried across servers is invisible to
/// whoever presses Connect. A token the user typed is theirs, and is left
/// alone — including when they clear it.
public struct ConnectFormState: Sendable, Equatable {
    /// Where the token currently in the field came from.
    public enum TokenSource: Sendable, Equatable {
        case none
        /// Typed or edited in the token field.
        case user
        /// Lifted from a dashboard URL for this `ServerEndpoint.key`.
        case autoFilled(endpointKey: String)
    }

    /// The most recent auto-fill the user overrode. The server field still
    /// holds the `?token=` that produced it, so re-offering it on the next
    /// keystroke there would undo their edit.
    ///
    /// Only the latest override is remembered, not every one ever declined: a
    /// later override replaces this, which makes the earlier pair offerable
    /// again. That is deliberate — the suppression exists to stop the server
    /// field from undoing the edit the user just made, not to keep a permanent
    /// blocklist. Re-offering is always to the endpoint the token came from,
    /// so it cannot disclose a credential across servers.
    private struct AutoFill: Sendable, Equatable {
        var endpointKey: String
        var token: String
    }

    public private(set) var serverInput: String = ""
    public private(set) var token: String = ""
    public private(set) var tokenSource: TokenSource = .none
    private var declined: AutoFill?

    public init() {}

    public mutating func setServerInput(_ newValue: String) {
        guard newValue != serverInput else { return }
        serverInput = newValue
        let parsed = try? ServerEndpoint.parse(newValue)

        // An auto-filled token survives only while the field still names the
        // endpoint it came from. This runs before any adoption below, so no
        // later early return can leave one endpoint's token sitting in a form
        // naming another.
        //
        // Unparseable input counts as a different endpoint, so a half-typed
        // address drops the token. That is a deliberate change of behavior in
        // this fix, not a carry-over: the previous code retained the token
        // through every intermediate keystroke. Erring toward dropping costs a
        // re-paste; erring toward keeping is how R01 sent one server's
        // credential to another.
        if case .autoFilled(let owner) = tokenSource, parsed?.endpoint.key != owner {
            token = ""
            tokenSource = .none
        }

        // A dashboard URL carries its own token: adopt it, unless it is the
        // one the user just overrode for this same endpoint.
        guard let parsed, let embedded = parsed.embeddedToken else { return }
        let offered = AutoFill(endpointKey: parsed.endpoint.key, token: embedded)
        guard offered != declined else { return }
        token = embedded
        tokenSource = .autoFilled(endpointKey: offered.endpointKey)
    }

    public mutating func setToken(_ newValue: String) {
        guard newValue != token else { return }
        if case .autoFilled(let owner) = tokenSource {
            declined = AutoFill(endpointKey: owner, token: token)
        }
        token = newValue
        tokenSource = newValue.isEmpty ? .none : .user
    }
}
