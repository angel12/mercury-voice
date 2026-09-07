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

    /// Every listener request goes through a short-timeout session: a
    /// regression that consumes the one-shot flow (and so cancels the
    /// listener) must fail these tests fast instead of parking on a dead
    /// port until the default 60s URLSession timeout.
    private func boundedSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 5
        config.timeoutIntervalForResource = 5
        return URLSession(configuration: config)
    }

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

    /// A callback carrying the wrong state is not ours: reject it over HTTP
    /// and keep listening, because consuming the one-shot flow would let any
    /// process that can reach the loopback port kill an in-flight sign-in.
    /// (Superseding contract: this used to terminate the wait with
    /// `.stateMismatch`.)
    @Test func forgedStateIsRejectedWithoutConsumingTheFlow() async throws {
        let listener = LoopbackRedirectListener(expectedState: "expected")
        let port = try await listener.start()
        let session = boundedSession()
        defer { session.finishTasksAndInvalidate() }

        let waiter = Task { try await listener.waitForCode() }
        let forged = URL(
            string: "http://127.0.0.1:\(port)/oauth/callback?code=x&state=forged")!
        let (_, forgedResponse) = try await session.data(from: forged)
        #expect((forgedResponse as? HTTPURLResponse)?.statusCode == 400)

        let real = URL(
            string: "http://127.0.0.1:\(port)/oauth/callback?code=real&state=expected")!
        let (_, realResponse) = try await session.data(from: real)
        #expect((realResponse as? HTTPURLResponse)?.statusCode == 200)
        #expect(try await waiter.value == "real")
    }

    /// Same for a callback with no state at all — previously accepted as a
    /// match whenever it also carried no code, and terminating either way.
    @Test func missingStateIsRejectedWithoutConsumingTheFlow() async throws {
        let listener = LoopbackRedirectListener(expectedState: "expected")
        let port = try await listener.start()
        let session = boundedSession()
        defer { session.finishTasksAndInvalidate() }

        let waiter = Task { try await listener.waitForCode() }
        let stateless = URL(string: "http://127.0.0.1:\(port)/oauth/callback?code=x")!
        let (_, statelessResponse) = try await session.data(from: stateless)
        #expect((statelessResponse as? HTTPURLResponse)?.statusCode == 400)

        let real = URL(
            string: "http://127.0.0.1:\(port)/oauth/callback?code=real&state=expected")!
        _ = try await session.data(from: real)
        #expect(try await waiter.value == "real")
    }

    /// A denial is a flow outcome, so it needs the same state proof as a
    /// success — otherwise `?error=access_denied` from anywhere on the host
    /// forces the sign-in to fail.
    @Test func denialWithForgedStateIsRejectedWithoutConsumingTheFlow() async throws {
        let listener = LoopbackRedirectListener(expectedState: "expected")
        let port = try await listener.start()
        let session = boundedSession()
        defer { session.finishTasksAndInvalidate() }

        let waiter = Task { try await listener.waitForCode() }
        let forgedDenial = URL(
            string: "http://127.0.0.1:\(port)/oauth/callback"
                + "?error=access_denied&error_description=nope&state=forged")!
        let (_, denialResponse) = try await session.data(from: forgedDenial)
        #expect((denialResponse as? HTTPURLResponse)?.statusCode == 400)

        let real = URL(
            string: "http://127.0.0.1:\(port)/oauth/callback?code=real&state=expected")!
        _ = try await session.data(from: real)
        #expect(try await waiter.value == "real")
    }

    /// A genuine denial (state proves it is our flow) still surfaces as
    /// `.denied` with the server's detail.
    @Test func listenerSurfacesIDPDenialWithValidState() async throws {
        let listener = LoopbackRedirectListener(expectedState: "s")
        let port = try await listener.start()
        let session = boundedSession()
        defer { session.finishTasksAndInvalidate() }

        let waiter = Task { try await listener.waitForCode() }
        let url = URL(
            string: "http://127.0.0.1:\(port)/oauth/callback"
                + "?error=access_denied&error_description=nope&state=s")!
        let (body, response) = try await session.data(from: url)
        #expect((response as? HTTPURLResponse)?.statusCode == 200)
        #expect(String(data: body, encoding: .utf8)?.contains("nope") == true)
        await #expect(throws: LoopbackRedirectListener.RedirectError.denied("nope")) {
            try await waiter.value
        }
    }

    /// The error description is attacker/server-controlled text rendered by a
    /// real browser: it must land in the page inert, never as markup.
    @Test func hostileErrorDescriptionIsNotExecutable() async throws {
        let listener = LoopbackRedirectListener(expectedState: "s")
        let port = try await listener.start()
        let session = boundedSession()
        defer { session.finishTasksAndInvalidate() }

        let waiter = Task { try await listener.waitForCode() }
        let hostile = "<script>alert('xss')</script><img src=x onerror=alert(1)>"
        var components = URLComponents(string: "http://127.0.0.1:\(port)/oauth/callback")!
        components.queryItems = [
            URLQueryItem(name: "error", value: "access_denied"),
            URLQueryItem(name: "error_description", value: hostile),
            URLQueryItem(name: "state", value: "s"),
        ]
        let (body, response) = try await session.data(from: components.url!)
        #expect((response as? HTTPURLResponse)?.statusCode == 200)
        let page = try #require(String(data: body, encoding: .utf8))
        #expect(!page.contains("<script"))
        #expect(!page.contains("<img"))
        // No tag or attribute delimiter from the description survives raw, so
        // the text stays inside the <p> instead of becoming markup.
        #expect(!page.contains(hostile))
        #expect(page.contains("&lt;script&gt;alert(&#39;xss&#39;)&lt;/script&gt;"))
        #expect(page.contains("&lt;img src=x onerror=alert(1)&gt;"))
        // The error value itself is unchanged for the app-side enum.
        await #expect(throws: LoopbackRedirectListener.RedirectError.denied(hostile)) {
            try await waiter.value
        }
    }

    /// Duplicate `state` is ambiguous — a smuggled second copy must not be
    /// resolved in the sender's favour, and must not consume the flow.
    @Test func duplicateStateIsRejectedWithoutConsumingTheFlow() async throws {
        let listener = LoopbackRedirectListener(expectedState: "expected")
        let port = try await listener.start()
        let session = boundedSession()
        defer { session.finishTasksAndInvalidate() }

        let waiter = Task { try await listener.waitForCode() }
        let doubled = URL(
            string: "http://127.0.0.1:\(port)/oauth/callback"
                + "?code=x&state=expected&state=forged")!
        let (_, doubledResponse) = try await session.data(from: doubled)
        #expect((doubledResponse as? HTTPURLResponse)?.statusCode == 400)

        let real = URL(
            string: "http://127.0.0.1:\(port)/oauth/callback?code=real&state=expected")!
        _ = try await session.data(from: real)
        #expect(try await waiter.value == "real")
    }

    /// Valid state but an unusable payload (duplicate/absent code, no error)
    /// is our own flow answering incoherently: reject the request and fail
    /// the wait rather than hanging on to a flow nothing can complete.
    @Test func ambiguousCodeWithValidStateFailsValidation() async throws {
        let listener = LoopbackRedirectListener(expectedState: "expected")
        let port = try await listener.start()
        let session = boundedSession()
        defer { session.finishTasksAndInvalidate() }

        let waiter = Task { try await listener.waitForCode() }
        let doubled = URL(
            string: "http://127.0.0.1:\(port)/oauth/callback"
                + "?state=expected&code=a&code=b")!
        let (_, response) = try await session.data(from: doubled)
        #expect((response as? HTTPURLResponse)?.statusCode == 400)
        await #expect(throws: LoopbackRedirectListener.RedirectError.stateMismatch) {
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

    /// A browser sheet that never presents means no redirect can ever land;
    /// the wait must end on its own rather than parking forever.
    @Test func listenerWaitTimesOut() async throws {
        let listener = LoopbackRedirectListener(expectedState: "s")
        _ = try await listener.start()

        await #expect(throws: LoopbackRedirectListener.RedirectError.timedOut) {
            try await listener.waitForCode(timeout: .milliseconds(50))
        }
    }

    @Test func cancellingTheWaitingTaskUnblocksIt() async throws {
        let listener = LoopbackRedirectListener(expectedState: "s")
        _ = try await listener.start()

        let waiter = Task { try await listener.waitForCode() }
        try await Task.sleep(for: .milliseconds(20))
        waiter.cancel()
        await #expect(throws: LoopbackRedirectListener.RedirectError.cancelled) {
            try await waiter.value
        }
    }

    /// The timeout must not fire after a real code already arrived.
    @Test func timeoutDoesNotClobberADeliveredCode() async throws {
        let listener = LoopbackRedirectListener(expectedState: "s-1")
        let port = try await listener.start()

        let waiter = Task { try await listener.waitForCode(timeout: .milliseconds(200)) }
        let url = URL(string: "http://127.0.0.1:\(port)/oauth/callback?code=in-time&state=s-1")!
        _ = try await URLSession.shared.data(from: url)
        #expect(try await waiter.value == "in-time")
        // Outlive the timeout to prove the late fire is harmless.
        try await Task.sleep(for: .milliseconds(250))
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
