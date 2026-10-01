import Foundation
import Testing

@testable import HermesKit

/// Issue #146 item 3: agent failures reach the user as plain copy that is
/// safe to speak — never raw server prose read aloud (it can carry paths and
/// ids). "No provider set up" is recognised by upstream's
/// `provider_not_configured` code (961c79220a) and, for older backends, by
/// the same message patterns the desktop falls back to
/// (`provider-setup-errors.ts`).
@Suite("Agent error copy")
struct AgentErrorCopyTests {
    @Test func theCodeIdentifiesAProviderSetupFailure() {
        #expect(AgentErrorCopy.isProviderSetup(code: "provider_not_configured", message: "anything"))
        #expect(!AgentErrorCopy.isProviderSetup(code: "something_else", message: "boom"))
    }

    @Test(arguments: [
        "Agent initialization failed: No LLM provider configured. Run `hermes model` to select a provider.",
        "No inference provider is configured",
        "Provider 'openai' is set in config.yaml but no API key was found",
        "no_provider_configured",
        "No API key configured for provider 'anthropic'. First message will fail.",
    ])
    func olderBackendsAreRecognisedByMessage(message: String) {
        #expect(AgentErrorCopy.isProviderSetup(code: nil, message: message))
    }

    /// The auxiliary-model warning is not a provider-setup failure; upstream
    /// deliberately never matches on "provider configured" alone.
    @Test func theAuxiliaryWarningIsNotProviderSetup() {
        #expect(
            !AgentErrorCopy.isProviderSetup(
                code: nil, message: "No auxiliary LLM provider configured for vision"))
        #expect(!AgentErrorCopy.isProviderSetup(code: nil, message: nil))
    }

    @Test func errorEventCopy() {
        let setup = AgentErrorCopy.errorEvent(message: "x", code: "provider_not_configured")
        #expect(setup.display == AgentErrorCopy.providerSetupHint)
        #expect(setup.spoken == AgentErrorCopy.providerSetupHint)

        // Anything else: the server's sentence on screen, generic copy aloud.
        let other = AgentErrorCopy.errorEvent(
            message: "Compression failed for /Users/me/.hermes/state.db", code: nil)
        #expect(other.display == "Compression failed for /Users/me/.hermes/state.db")
        #expect(other.spoken == AgentErrorCopy.genericSpoken)
        #expect(!other.spoken.contains("/Users"))
    }

    @Test func emptyErrorEventMessageStillSaysSomething() {
        let copy = AgentErrorCopy.errorEvent(message: "  ", code: nil)
        #expect(copy.display == AgentErrorCopy.genericSpoken)
    }

    // MARK: prompt.submit refused because the agent never built (5032)

    @Test func agentInitRefusalWithNoProviderReadsAsTheSetupHint() {
        let error = HermesError.rpcError(
            code: 5032, message: "No LLM provider configured. Run `hermes model`.", data: nil)
        #expect(error.errorDescription == AgentErrorCopy.providerSetupHint)
        #expect(AgentErrorCopy.spokenSubmitFailure(error) == AgentErrorCopy.providerSetupHint)
    }

    @Test func otherAgentInitRefusalsAreSpokenGenerically() {
        let error = HermesError.rpcError(
            code: 5032, message: "agent initialization failed before completing", data: nil)
        #expect(
            error.errorDescription
                == "Hermes couldn't start the agent for this session: agent initialization failed before completing"
        )
        #expect(AgentErrorCopy.spokenSubmitFailure(error) == AgentErrorCopy.agentStartSpoken)
    }

    /// Other submit failures keep their on-screen notice only; most are
    /// transient and their copy was never written to be spoken.
    @Test func otherSubmitFailuresAreNotSpoken() {
        #expect(AgentErrorCopy.spokenSubmitFailure(HermesError.notConnected) == nil)
        #expect(
            AgentErrorCopy.spokenSubmitFailure(
                HermesError.rpcError(code: 4009, message: "busy", data: nil)) == nil)
        #expect(AgentErrorCopy.spokenSubmitFailure(URLError(.timedOut)) == nil)
    }
}
