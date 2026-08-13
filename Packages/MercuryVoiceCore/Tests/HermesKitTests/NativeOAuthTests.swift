import Foundation
import Testing

@testable import HermesKit

@Suite("Native OAuth (RFC 8252)")
struct NativeOAuthTests {
    // MARK: PKCE

    /// RFC 7636 appendix B reference vector.
    @Test func pkceMatchesRFC7636Vector() {
        let challenge = PKCEChallenge(
            verifier: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk")
        #expect(challenge.challenge == "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
    }

    @Test func generatedVerifierIsSpecCompliant() {
        let challenge = PKCEChallenge()
        // 32 random bytes base64url → 43 chars, within RFC 7636's 43–128.
        #expect(challenge.verifier.count == 43)
        let allowed = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        #expect(challenge.verifier.allSatisfy(allowed.contains))
        #expect(PKCEChallenge().verifier != challenge.verifier)  // random
    }

    // MARK: Authorize URL

    @Test func authorizeURLCarriesTheContractQuery() throws {
        let endpoint = try ServerEndpoint.parse("http://10.0.0.5:9119").endpoint
        let challenge = PKCEChallenge(verifier: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk")
        let url = HermesAuthenticator.nativeAuthorizeURL(
            endpoint: endpoint,
            provider: "nous",
            challenge: challenge,
            redirectURI: "http://127.0.0.1:49152/oauth/callback",
            state: "state-123")

        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        #expect(components.path == "/auth/native/authorize")
        let query = { (name: String) in
            components.queryItems?.first(where: { $0.name == name })?.value
        }
        #expect(query("provider") == "nous")
        #expect(query("code_challenge") == challenge.challenge)
        #expect(query("code_challenge_method") == "S256")
        #expect(query("redirect_uri") == "http://127.0.0.1:49152/oauth/callback")
        #expect(query("state") == "state-123")
    }

    // MARK: Token response parsing

    private func json(_ string: String) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: Data(string.utf8))
    }

    @Test func tokenResponseParsesIntoPasswordSession() throws {
        let session = try HermesAuthenticator.passwordSession(
            fromNativeTokenResponse: json("""
                {"access_token": "at-1", "refresh_token": "rt-1",
                 "token_type": "Bearer", "expires_at": 1755200000,
                 "provider": "nous", "user_id": "spencer@example.com"}
                """),
            provider: "requested")
        #expect(session.accessToken == "at-1")
        #expect(session.refreshToken == "rt-1")
        #expect(session.expiresAt == 1_755_200_000)
        #expect(session.provider == "nous")  // response wins over requested
        #expect(session.username == "spencer@example.com")
    }

    @Test func tokenResponseWithoutAccessTokenThrows() throws {
        let body = try json(#"{"refresh_token": "rt-1"}"#)
        #expect(throws: HermesError.self) {
            try HermesAuthenticator.passwordSession(
                fromNativeTokenResponse: body, provider: "nous")
        }
    }

    // MARK: Status advertisement

    @Test func serverStatusParsesAuthFlows() throws {
        let status = ServerStatus(
            raw: try json(
                #"{"auth_required": true, "auth_flows": ["cookie", "native_pkce"]}"#))
        #expect(status.authFlows == ["cookie", "native_pkce"])

        let older = ServerStatus(raw: try json(#"{"auth_required": true}"#))
        #expect(older.authFlows.isEmpty)
    }

    // MARK: Loopback listener (real bind + HTTP round trip)

    @Test func listenerCatchesTheRedirect() async throws {
        let listener = LoopbackRedirectListener(expectedState: "s-1")
        let port = try await listener.start()
        #expect(port > 0)

        let waiter = Task { try await listener.waitForCode() }
        let url = URL(string: "http://127.0.0.1:\(port)/oauth/callback?code=gw-code-42&state=s-1")!
        let (body, response) = try await URLSession.shared.data(from: url)
        #expect((response as? HTTPURLResponse)?.statusCode == 200)
        #expect(String(data: body, encoding: .utf8)?.contains("Signed in") == true)
        #expect(try await waiter.value == "gw-code-42")
    }

    @Test func listenerRejectsStateMismatch() async throws {
        let listener = LoopbackRedirectListener(expectedState: "expected")
        let port = try await listener.start()

        let waiter = Task { try await listener.waitForCode() }
        let url = URL(string: "http://127.0.0.1:\(port)/oauth/callback?code=x&state=forged")!
        let (_, response) = try await URLSession.shared.data(from: url)
        #expect((response as? HTTPURLResponse)?.statusCode == 400)
        await #expect(throws: LoopbackRedirectListener.RedirectError.stateMismatch) {
            try await waiter.value
        }
    }

    @Test func listenerSurfacesIDPDenial() async throws {
        let listener = LoopbackRedirectListener(expectedState: "s")
        let port = try await listener.start()

        let waiter = Task { try await listener.waitForCode() }
        let url = URL(
            string:
                "http://127.0.0.1:\(port)/oauth/callback?error=access_denied&error_description=nope"
        )!
        _ = try await URLSession.shared.data(from: url)
        await #expect(throws: LoopbackRedirectListener.RedirectError.denied("nope")) {
            try await waiter.value
        }
    }

    @Test func listenerCancelUnblocksTheWait() async throws {
        let listener = LoopbackRedirectListener(expectedState: "s")
        _ = try await listener.start()

        let waiter = Task { try await listener.waitForCode() }
        try await Task.sleep(for: .milliseconds(20))
        await listener.cancel()
        await #expect(throws: LoopbackRedirectListener.RedirectError.cancelled) {
            try await waiter.value
        }
    }

    @Test func listenerIgnoresUnrelatedPaths() async throws {
        let listener = LoopbackRedirectListener(expectedState: "s-1")
        let port = try await listener.start()

        let waiter = Task { try await listener.waitForCode() }
        // A stray browser request (favicon) must not consume the flow.
        let stray = URL(string: "http://127.0.0.1:\(port)/favicon.ico")!
        let (_, strayResponse) = try await URLSession.shared.data(from: stray)
        #expect((strayResponse as? HTTPURLResponse)?.statusCode == 404)

        let callback = URL(
            string: "http://127.0.0.1:\(port)/oauth/callback?code=late&state=s-1")!
        _ = try await URLSession.shared.data(from: callback)
        #expect(try await waiter.value == "late")
    }
}
