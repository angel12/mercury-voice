import Foundation
import Network
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

    /// Percent-encode every byte outside RFC 3986 unreserved so the value
    /// reaches the listener exactly as written. `URLComponents.queryItems`
    /// is no good here: it leaves `&` raw in values, which would split the
    /// query and silently defang the payload under test.
    private func queryEncoded(_ value: String) -> String {
        let unreserved = Set(
            "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~".utf8)
        var encoded = ""
        for byte in Array(value.utf8) {
            if unreserved.contains(byte) {
                encoded.unicodeScalars.append(Unicode.Scalar(byte))
            } else {
                encoded += String(format: "%%%02X", byte)
            }
        }
        return encoded
    }

    /// The response bytes between `<p>` and `</p>` — the only span of the
    /// page carrying server-controlled text.
    ///
    /// Assertions on this span are byte-level on purpose: `String.contains`
    /// compares extended grapheme clusters, so a raw `<` fused into a
    /// cluster by a preceding Unicode Prepend code point (U+0600 and
    /// friends, UAX #29 GB9b) would slip past `!page.contains("<img")`
    /// while an HTML tokenizer — which works on code points — still opens a
    /// tag. Only the wire bytes can prove the text is inert.
    private func paragraphBytes(of body: Data) throws -> Data {
        let open = try #require(body.range(of: Data("<p>".utf8)))
        let close = try #require(body.range(of: Data("</p>".utf8)))
        return body[open.upperBound..<close.lowerBound]
    }

    /// No byte that an HTML tokenizer reads as a tag or attribute delimiter
    /// may appear raw in the server-controlled span. `&` is excluded: it is
    /// the first byte of every entity the escaper emits.
    private func expectNoRawDelimiters(in paragraph: Data) {
        for delimiter in "<>\"'".unicodeScalars {
            #expect(!paragraph.contains(UInt8(ascii: delimiter)))
        }
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

    /// The original vulnerability verbatim: a bare `?error=access_denied`
    /// with no `state` parameter at all ended the wait with `.denied`, so
    /// anything that could reach the port could fail the sign-in. It must
    /// now be rejected without consuming the flow, and the genuine callback
    /// must still win afterwards.
    @Test func denialWithoutAnyStateIsRejectedWithoutConsumingTheFlow() async throws {
        let listener = LoopbackRedirectListener(expectedState: "expected")
        let port = try await listener.start()
        let session = boundedSession()
        defer { session.finishTasksAndInvalidate() }

        let waiter = Task { try await listener.waitForCode() }
        let statelessDenial = URL(
            string: "http://127.0.0.1:\(port)/oauth/callback?error=access_denied")!
        let (_, denialResponse) = try await session.data(from: statelessDenial)
        #expect((denialResponse as? HTTPURLResponse)?.statusCode == 400)

        let real = URL(
            string: "http://127.0.0.1:\(port)/oauth/callback?code=real&state=expected")!
        let (_, realResponse) = try await session.data(from: real)
        #expect((realResponse as? HTTPURLResponse)?.statusCode == 200)
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
        expectNoRawDelimiters(in: try paragraphBytes(of: body))
        // The error value itself is unchanged for the app-side enum.
        await #expect(throws: LoopbackRedirectListener.RedirectError.denied(hostile)) {
            try await waiter.value
        }
    }

    /// Escaping has to work on Unicode scalars, not `Character`: a Prepend
    /// code point (U+0600 ARABIC NUMBER SIGN, UAX #29 GB9b) does not break
    /// before the next code point, so `U+0600 <` is a single grapheme
    /// cluster that matches none of the escaper's cases. A `Character`-based
    /// escaper therefore emits the `<` verbatim, and the browser's
    /// tokenizer — which reads code points — opens the injected tag, closed
    /// by the `>` of the `</p>` that follows. No raw `>` needed in the
    /// payload at all.
    @Test func prependCodePointCannotSmuggleRawMarkupBytes() async throws {
        let listener = LoopbackRedirectListener(expectedState: "s")
        let port = try await listener.start()
        let session = boundedSession()
        defer { session.finishTasksAndInvalidate() }

        let waiter = Task { try await listener.waitForCode() }
        let hostile = "\u{0600}<img src=x onerror=alert(document.location) "
        let url = URL(
            string: "http://127.0.0.1:\(port)/oauth/callback?error=access_denied"
                + "&error_description=\(queryEncoded(hostile))&state=s")!
        let (body, response) = try await session.data(from: url)
        #expect((response as? HTTPURLResponse)?.statusCode == 200)

        let paragraph = try paragraphBytes(of: body)
        expectNoRawDelimiters(in: paragraph)
        #expect(paragraph.range(of: Data("<img".utf8)) == nil)
        // The Prepend code point itself is inert text and survives (D8 80).
        #expect(
            paragraph
                == Data(
                    """
                    Sign-in failed: \u{0600}&lt;img src=x \
                    onerror=alert(document.location) . You can close this tab.
                    """.utf8))
        await #expect(throws: LoopbackRedirectListener.RedirectError.denied(hostile)) {
            try await waiter.value
        }
    }

    /// Wire-level check of the whole escape set, bare and behind a Prepend
    /// code point, in one round trip.
    @Test func everySpecialCharacterIsEscapedOnTheWire() async throws {
        let listener = LoopbackRedirectListener(expectedState: "s")
        let port = try await listener.start()
        let session = boundedSession()
        defer { session.finishTasksAndInvalidate() }

        let waiter = Task { try await listener.waitForCode() }
        let hostile = "&<>\"'\u{0600}&\u{0600}<\u{0600}>\u{0600}\"\u{0600}'"
        let url = URL(
            string: "http://127.0.0.1:\(port)/oauth/callback?error=access_denied"
                + "&error_description=\(queryEncoded(hostile))&state=s")!
        let (body, response) = try await session.data(from: url)
        #expect((response as? HTTPURLResponse)?.statusCode == 200)

        let paragraph = try paragraphBytes(of: body)
        expectNoRawDelimiters(in: paragraph)
        #expect(
            paragraph
                == Data(
                    """
                    Sign-in failed: &amp;&lt;&gt;&quot;&#39;\
                    \u{0600}&amp;\u{0600}&lt;\u{0600}&gt;\u{0600}&quot;\u{0600}&#39;\
                    . You can close this tab.
                    """.utf8))
        await #expect(throws: LoopbackRedirectListener.RedirectError.denied(hostile)) {
            try await waiter.value
        }
    }

    /// `.stateMismatch` is now reachable only when the state *matched* but
    /// the callback carried no usable code and no error, so its user-facing
    /// text must not claim a mismatched state. The case itself stays: the
    /// public error enum is part of the frozen API.
    @Test func validationFailureWordingDoesNotClaimAStateMismatch() {
        let message = LoopbackRedirectListener.RedirectError.stateMismatch.errorDescription
        #expect(message == "Sign-in response failed validation. Try again.")
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

    // MARK: Fragmented requests, EOF and stalled connections

    /// A raw TCP client. `URLSession` always writes a request in one shot, so
    /// nothing driven through it can produce the shapes below: a request line
    /// split across segments, a client that stalls mid-line, or one that
    /// half-closes without a CRLF.
    private actor RawHTTPClient {
        struct Response {
            let bytes: Data
            /// True when the listener closed the connection, false when this
            /// client gave up first because the listener left it open.
            let closedByListener: Bool
        }

        private let connection: NWConnection
        private var readyWaiter: CheckedContinuation<Void, Error>?
        private var gaveUp = false

        init(port: UInt16) {
            connection = NWConnection(
                host: .ipv4(.loopback),
                port: NWEndpoint.Port(rawValue: port)!,
                using: .tcp)
        }

        func connect() async throws {
            connection.stateUpdateHandler = { [weak self] state in
                Task { await self?.stateChanged(state) }
            }
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<Void, Error>) in
                readyWaiter = continuation
                connection.start(queue: .global(qos: .userInitiated))
            }
        }

        /// `finishing: true` appends a TCP FIN, so the listener sees EOF while
        /// this side can still read the response.
        func write(_ text: String, finishing: Bool = false) async throws {
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<Void, Error>) in
                connection.send(
                    content: Data(text.utf8),
                    contentContext: finishing ? .finalMessage : .defaultMessage,
                    isComplete: finishing,
                    completion: .contentProcessed { error in
                        if let error {
                            continuation.resume(throwing: error)
                        } else {
                            continuation.resume()
                        }
                    })
            }
        }

        /// Read until the listener closes — it always answers `Connection:
        /// close` — giving up after `limit` so a connection the listener never
        /// reclaims fails the test instead of hanging the run.
        func readToEnd(within limit: Duration) async -> Response {
            let watchdog = Task { [weak self] in
                try await Task.sleep(for: limit)
                await self?.giveUp()
            }
            defer { watchdog.cancel() }
            var bytes = Data()
            while true {
                let (chunk, ended) = await receiveOnce()
                if let chunk { bytes += chunk }
                if ended { break }
            }
            return Response(bytes: bytes, closedByListener: !gaveUp)
        }

        func close() {
            connection.cancel()
        }

        private func giveUp() {
            gaveUp = true
            connection.cancel()
        }

        private func stateChanged(_ state: NWConnection.State) {
            switch state {
            case .ready: resumeReady(with: .success(()))
            case .failed(let error), .waiting(let error): resumeReady(with: .failure(error))
            case .cancelled: resumeReady(with: .failure(CancellationError()))
            default: break
            }
        }

        private func resumeReady(with result: Result<Void, Error>) {
            guard let waiter = readyWaiter else { return }
            readyWaiter = nil
            waiter.resume(with: result)
        }

        /// End of stream covers a clean close and a reset alike: either way
        /// nothing more will arrive.
        private func receiveOnce() async -> (Data?, Bool) {
            await withCheckedContinuation {
                (continuation: CheckedContinuation<(Data?, Bool), Never>) in
                connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) {
                    data, _, isComplete, error in
                    continuation.resume(returning: (data, isComplete || error != nil))
                }
            }
        }
    }

    /// TCP is a byte stream: the callback's request line is free to arrive in
    /// several segments, and the listener used to treat whatever the first
    /// receive returned as the whole request line — answering 404 to a
    /// truncated path and leaving the genuine sign-in unfinished.
    @Test func fragmentedRequestLineStillDeliversTheCode() async throws {
        let listener = LoopbackRedirectListener(expectedState: "s-1")
        let port = try await listener.start()
        let waiter = Task { try await listener.waitForCode(timeout: .seconds(5)) }

        let client = RawHTTPClient(port: port)
        try await client.connect()
        // Split mid-path and mid-query, with gaps long enough that each piece
        // is a receive of its own.
        try await client.write("GET /oauth/call")
        try await Task.sleep(for: .milliseconds(30))
        try await client.write("back?code=frag-42&sta")
        try await Task.sleep(for: .milliseconds(30))
        try await client.write("te=s-1 HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n")

        let response = await client.readToEnd(within: .seconds(2))
        let page = try #require(String(data: response.bytes, encoding: .utf8))
        #expect(page.hasPrefix("HTTP/1.1 200 OK"))
        #expect(page.contains("Signed in"))
        #expect(try await waiter.value == "frag-42")
        await client.close()
    }

    /// A request line that never ends must be dropped at a bound instead of
    /// buffered without limit — and never acted on: a truncated line still
    /// parses, so the listener used to hand the flow a truncated `code` and
    /// consume the one-shot sign-in with it.
    @Test func oversizedRequestLineIsDroppedWithoutConsumingTheFlow() async throws {
        let listener = LoopbackRedirectListener(expectedState: "s-1")
        let port = try await listener.start()
        let waiter = Task { try await listener.waitForCode(timeout: .seconds(5)) }

        let client = RawHTTPClient(port: port)
        try await client.connect()
        try await client.write("GET /oauth/callback?state=s-1&code=")
        // No CRLF, ever. The listener drops the connection once the bound is
        // passed, so the tail of this write may fail — that is the point.
        try? await client.write(String(repeating: "a", count: 32768))

        let response = await client.readToEnd(within: .seconds(2))
        #expect(response.closedByListener)
        #expect(response.bytes.isEmpty)  // nothing was answered
        await client.close()

        // The flow survived, so the real callback still wins.
        let session = boundedSession()
        defer { session.finishTasksAndInvalidate() }
        let real = URL(string: "http://127.0.0.1:\(port)/oauth/callback?code=real&state=s-1")!
        let (_, realResponse) = try await session.data(from: real)
        #expect((realResponse as? HTTPURLResponse)?.statusCode == 200)
        #expect(try await waiter.value == "real")
    }

    /// A connection that opens and never writes must be reclaimed on its own
    /// deadline instead of holding an idle receive for the whole sign-in.
    @Test func silentConnectionIsReclaimedAtItsDeadline() async throws {
        let listener = LoopbackRedirectListener(
            expectedState: "s-1", requestDeadline: .milliseconds(150))
        let port = try await listener.start()
        let waiter = Task { try await listener.waitForCode(timeout: .seconds(5)) }

        let client = RawHTTPClient(port: port)
        try await client.connect()  // …and not a byte after it

        let response = await client.readToEnd(within: .seconds(2))
        #expect(response.closedByListener)
        #expect(response.bytes.isEmpty)
        await client.close()

        // Reclaiming the dead connection left the flow itself untouched.
        let session = boundedSession()
        defer { session.finishTasksAndInvalidate() }
        let real = URL(string: "http://127.0.0.1:\(port)/oauth/callback?code=real&state=s-1")!
        _ = try await session.data(from: real)
        #expect(try await waiter.value == "real")
    }

    /// Same for a client that stalls part-way through the request line: the
    /// listener has nothing it can answer, so it must wait for the rest until
    /// the deadline and then drop the connection — not reply to the fragment.
    @Test func stalledPartialRequestLineIsDroppedUnanswered() async throws {
        let listener = LoopbackRedirectListener(
            expectedState: "s-1", requestDeadline: .milliseconds(150))
        let port = try await listener.start()
        let waiter = Task { try await listener.waitForCode(timeout: .seconds(5)) }

        let client = RawHTTPClient(port: port)
        try await client.connect()
        try await client.write("GET /oauth/callback?code=stall")  // then silence

        let response = await client.readToEnd(within: .seconds(2))
        #expect(response.closedByListener)
        #expect(response.bytes.isEmpty)
        await client.close()

        let session = boundedSession()
        defer { session.finishTasksAndInvalidate() }
        let real = URL(string: "http://127.0.0.1:\(port)/oauth/callback?code=real&state=s-1")!
        _ = try await session.data(from: real)
        #expect(try await waiter.value == "real")
    }

    /// EOF ends the request line too: a client that half-closes after writing
    /// it, without a CRLF, is answered from what it did send — the leniency
    /// the single-receive parser had, kept now that reads are accumulated.
    @Test func requestLineEndedByEOFIsStillHonoured() async throws {
        let listener = LoopbackRedirectListener(expectedState: "s-1")
        let port = try await listener.start()
        let waiter = Task { try await listener.waitForCode(timeout: .seconds(5)) }

        let client = RawHTTPClient(port: port)
        try await client.connect()
        try await client.write(
            "GET /oauth/callback?code=eof-7&state=s-1 HTTP/1.1", finishing: true)

        let response = await client.readToEnd(within: .seconds(2))
        let page = try #require(String(data: response.bytes, encoding: .utf8))
        #expect(page.hasPrefix("HTTP/1.1 200 OK"))
        #expect(try await waiter.value == "eof-7")
        await client.close()
    }
}
