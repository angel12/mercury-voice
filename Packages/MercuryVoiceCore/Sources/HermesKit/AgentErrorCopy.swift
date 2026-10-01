import Foundation

/// User-facing copy for agent failures (issue #146 item 3). Server prose is
/// shown on screen but never read aloud — it can carry paths and ids — so
/// each failure gets a spoken line written for speech, the same rule
/// `HermesError.errorDescription` follows for refusals.
public enum AgentErrorCopy {
    /// `error.code` upstream sets when agent init found no usable inference
    /// provider (961c79220a): the remedy is setup, not a retry.
    public static let providerSetupCode = "provider_not_configured"

    public static let providerSetupHint =
        "No AI model provider is set up for this profile. Set one up on the Hermes server with hermes model, then try again."
    public static let genericSpoken = "Hermes ran into a problem. The details are on screen."
    public static let agentStartSpoken =
        "Hermes couldn't start the agent for this session. The details are on screen."

    /// Fallback for backends that send no `code`: the sentences the backend
    /// actually produces, matched by noun phrase exactly as the desktop's
    /// `provider-setup-errors.ts` does — and deliberately not "provider
    /// configured" alone, which the auxiliary-model warning also says.
    private static let providerSetupMessage = try! NSRegularExpression(
        pattern:
            #"No (?:inference|Hermes|LLM) provider(?: is)? configured|no_provider_configured|set an API key|is set in config\.yaml but no (?:API key|credentials)"#,
        options: [.caseInsensitive])
    private static let credentialWarning = try! NSRegularExpression(
        pattern: #"^No API key configured for provider '[^']*'\. First message will fail\.$"#)

    public static func isProviderSetup(code: String?, message: String?) -> Bool {
        if code == providerSetupCode { return true }
        guard let text = message?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty
        else { return false }
        let range = NSRange(text.startIndex..., in: text)
        return providerSetupMessage.firstMatch(in: text, range: range) != nil
            || credentialWarning.firstMatch(in: text, range: range) != nil
    }

    /// Copy for an `error` event: what the notice shows, and what is spoken
    /// when it ended a turn the user is waiting on.
    public static func errorEvent(message: String?, code: String?) -> (display: String, spoken: String) {
        if isProviderSetup(code: code, message: message) {
            return (providerSetupHint, providerSetupHint)
        }
        let text = message?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return (text.isEmpty ? genericSpoken : text, genericSpoken)
    }

    /// The spoken line for a refused `prompt.submit`, or nil to keep it on
    /// screen only. Only an agent that never built (5032) is spoken: the
    /// user cannot fix it by repeating themselves, and without this a
    /// voice-only user hears nothing at all.
    public static func spokenSubmitFailure(_ error: any Error) -> String? {
        guard case HermesError.rpcError(HermesError.RPCCode.agentUnavailable, let message, _) = error
        else { return nil }
        return isProviderSetup(code: nil, message: message) ? providerSetupHint : agentStartSpoken
    }
}
