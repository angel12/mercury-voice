import Foundation
import Testing

@testable import HermesKit

/// Regression coverage for issue #54 (audit finding R01): a token lifted out
/// of one server's dashboard URL must not be carried to a different server.
/// The token field is secure-entry, so a stale token is invisible to whoever
/// presses Connect.
@Suite("ConnectFormState token ownership")
struct ConnectFormStateTests {
    private static let serverA = "http://127.0.0.1:8080/?token=TOKEN-A"
    private static let serverB = "http://192.168.1.50:8080"

    @Test func liftsEmbeddedTokenFromPastedDashboardURL() {
        var form = ConnectFormState()
        form.setServerInput(Self.serverA)
        #expect(form.token == "TOKEN-A")
        #expect(form.tokenSource == .autoFilled(endpointKey: "http://127.0.0.1:8080"))
    }

    /// The R01 leak itself.
    @Test func dropsAutoFilledTokenWhenEndpointChanges() {
        var form = ConnectFormState()
        form.setServerInput(Self.serverA)
        form.setServerInput(Self.serverB)
        #expect(form.token == "")
        #expect(form.tokenSource == .none)
    }

    @Test func dropsAutoFilledTokenWhenOnlyThePortChanges() {
        var form = ConnectFormState()
        form.setServerInput(Self.serverA)
        form.setServerInput("http://127.0.0.1:9090")
        #expect(form.token == "")
    }

    @Test func dropsAutoFilledTokenWhenServerFieldIsCleared() {
        var form = ConnectFormState()
        form.setServerInput(Self.serverA)
        form.setServerInput("")
        #expect(form.token == "")
        #expect(form.tokenSource == .none)
    }

    /// Editing the same endpoint - here, deleting the query string - must not
    /// cost the user the token they just pasted.
    @Test func keepsAutoFilledTokenWhenSameEndpointIsEdited() {
        var form = ConnectFormState()
        form.setServerInput(Self.serverA)
        form.setServerInput("http://127.0.0.1:8080")
        #expect(form.token == "TOKEN-A")
        #expect(form.tokenSource == .autoFilled(endpointKey: "http://127.0.0.1:8080"))
    }

    /// `ServerEndpoint.key` lowercases the host, so a case-only edit is the
    /// same endpoint.
    @Test func keepsAutoFilledTokenAcrossHostCaseOnlyEdit() {
        var form = ConnectFormState()
        form.setServerInput("http://Example.Local:8080/?token=TOKEN-A")
        form.setServerInput("http://example.local:8080")
        #expect(form.token == "TOKEN-A")
    }

    @Test func newEmbeddedTokenReplacesPreviousAutoFill() {
        var form = ConnectFormState()
        form.setServerInput(Self.serverA)
        form.setServerInput("http://192.168.1.50:8080/?token=TOKEN-B")
        #expect(form.token == "TOKEN-B")
        #expect(form.tokenSource == .autoFilled(endpointKey: "http://192.168.1.50:8080"))
    }

    @Test func keepsExplicitlyTypedTokenAcrossEndpointChange() {
        var form = ConnectFormState()
        form.setServerInput("http://127.0.0.1:8080")
        form.setToken("TYPED-BY-HAND")
        form.setServerInput(Self.serverB)
        #expect(form.token == "TYPED-BY-HAND")
        #expect(form.tokenSource == .user)
    }

    /// Editing an auto-filled token transfers ownership to the user, so the
    /// endpoint-change rule no longer applies to it.
    @Test func editingAutoFilledTokenTransfersOwnershipToUser() {
        var form = ConnectFormState()
        form.setServerInput(Self.serverA)
        form.setToken("TOKEN-A-EDITED")
        #expect(form.tokenSource == .user)
        form.setServerInput(Self.serverB)
        #expect(form.token == "TOKEN-A-EDITED")
    }

    /// The server field still contains `?token=`, so any later keystroke there
    /// would re-offer the token the user deliberately cleared.
    @Test func manuallyClearedTokenIsNotRestoredByLaterServerEdits() {
        var form = ConnectFormState()
        form.setServerInput(Self.serverA)
        form.setToken("")
        #expect(form.token == "")
        form.setServerInput(Self.serverA + "&project=demo")
        #expect(form.token == "")
        #expect(form.tokenSource == .none)
    }

    /// SwiftUI bindings can write the current value back on re-render; that
    /// must not silently reclassify an auto-filled token as user-owned.
    @Test func rewritingIdenticalValuesDoesNotChangeOwnership() {
        var form = ConnectFormState()
        form.setServerInput(Self.serverA)
        form.setToken("TOKEN-A")
        form.setServerInput(Self.serverA)
        #expect(form.tokenSource == .autoFilled(endpointKey: "http://127.0.0.1:8080"))
        form.setServerInput(Self.serverB)
        #expect(form.token == "")
    }

    /// A token typed before the server address is user-owned and survives the
    /// keystroke-by-keystroke endpoint churn of typing the address.
    @Test func tokenTypedBeforeServerAddressSurvivesTyping() {
        var form = ConnectFormState()
        form.setToken("TYPED-FIRST")
        for prefix in ["1", "12", "127.0.0.1", "127.0.0.1:8080"] {
            form.setServerInput(prefix)
        }
        #expect(form.token == "TYPED-FIRST")
        #expect(form.tokenSource == .user)
    }

    /// Review find (#54): a declined auto-fill must not shield a token that
    /// belongs to a *different* endpoint. Returning early on the declined
    /// offer left endpoint B's token sitting in a form naming endpoint A,
    /// which is the same cross-server disclosure R01 is about.
    @Test func decliningAnAutoFillDoesNotStrandAnotherEndpointsToken() {
        var form = ConnectFormState()
        form.setServerInput(Self.serverA)
        form.setToken("")
        form.setServerInput("http://192.168.1.50:8080/?token=TOKEN-B")
        #expect(form.token == "TOKEN-B")

        form.setServerInput(Self.serverA)
        #expect(form.token == "")
        #expect(form.tokenSource == .none)
    }

    /// Characterizes the "most recent override only" rule Raoden called out:
    /// declining B's auto-fill replaces the memory of declining A's, so A's
    /// token is offered again on return. Safe by construction — A's token is
    /// only ever re-offered while the field names A.
    @Test func onlyTheMostRecentDeclinedAutoFillIsRemembered() {
        var form = ConnectFormState()
        form.setServerInput(Self.serverA)
        form.setToken("")

        form.setServerInput("http://192.168.1.50:8080/?token=TOKEN-B")
        form.setToken("")

        form.setServerInput(Self.serverA)
        #expect(form.token == "TOKEN-A")
        #expect(form.tokenSource == .autoFilled(endpointKey: "http://127.0.0.1:8080"))
    }

    /// Intentional new behavior in this fix, not a carry-over: the previous
    /// `onChange` kept the token through unparseable intermediate input.
    @Test func dropsAutoFilledTokenWhenInputBecomesUnparseable() {
        var form = ConnectFormState()
        form.setServerInput(Self.serverA)
        form.setServerInput("ftp://example.com")
        #expect(form.token == "")
        #expect(form.tokenSource == .none)
    }
}
