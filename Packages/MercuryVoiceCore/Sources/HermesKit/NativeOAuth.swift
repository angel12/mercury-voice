import CryptoKit
import Foundation
import Network

// RFC 8252 native-app OAuth against the Hermes gateway (issue #51).
//
// The gateway brokers the upstream IDP round trip itself; the app only does
// the native-client half: open `/auth/native/authorize` in the system
// browser with a PKCE S256 challenge and a loopback `redirect_uri`, catch
// the `?code=` redirect on a one-shot 127.0.0.1 listener (the server
// accepts ONLY loopback IP literals — custom schemes and `localhost` are
// rejected as an open-redirect defense), then redeem the code at
// `/auth/native/token` for the same bearer/refresh pair a password login
// mints. Everything after that — keychain storage, Bearer headers,
// `/auth/native/refresh` rotation, WS tickets — is shared with password
// mode via `PasswordSession`.

/// RFC 7636 S256 code challenge. The verifier is 32 random bytes
/// base64url-encoded (43 chars, within the 43–128 spec range).
public struct PKCEChallenge: Sendable, Equatable {
    public let verifier: String
    public let challenge: String

    public init() {
        var bytes = [UInt8](repeating: 0, count: 32)
        for i in bytes.indices { bytes[i] = UInt8.random(in: .min ... .max) }
        self.init(verifier: Data(bytes).base64URLEncodedString())
    }

    /// Split out so tests can drive the RFC 7636 appendix B vector.
    public init(verifier: String) {
        self.verifier = verifier
        self.challenge = Data(SHA256.hash(data: Data(verifier.utf8)))
            .base64URLEncodedString()
    }

    /// CSRF state nonce for the authorize round trip.
    public static func randomState() -> String {
        var bytes = [UInt8](repeating: 0, count: 16)
        for i in bytes.indices { bytes[i] = UInt8.random(in: .min ... .max) }
        return Data(bytes).base64URLEncodedString()
    }
}

extension Data {
    /// Base64url without padding (RFC 4648 §5) — the encoding both PKCE
    /// fields use on the wire.
    func base64URLEncodedString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

/// One-shot HTTP listener on 127.0.0.1 that catches the authorize redirect.
/// Start it, put `http://127.0.0.1:<port><path>` in the authorize URL, and
/// await `waitForCode()`; it resolves with the authorization code, or throws
/// on IDP denial, an incoherent callback for this flow, or `cancel()`.
/// Requests that don't carry the expected `state` — including denials — are
/// answered with an HTTP rejection and leave the wait running: only the flow
/// that knows the state can end it.
public actor LoopbackRedirectListener {
    public enum RedirectError: Error, LocalizedError, Equatable {
        case cancelled
        case denied(String)
        /// A callback that proved the expected `state` but carried nothing
        /// this flow can act on — no usable `code` and no `error`. Callbacks
        /// that fail the state check never reach here: they are rejected
        /// over HTTP and the wait keeps running. (Case name kept for API
        /// compatibility; it no longer implies a mismatched state.)
        case stateMismatch
        case listenerFailed(String)
        case timedOut
        /// The system browser sheet refused to present, so no redirect can
        /// ever arrive.
        case presentationFailed

        public var errorDescription: String? {
            switch self {
            case .cancelled: return "Sign-in was cancelled."
            case .denied(let detail): return "Sign-in was denied: \(detail)"
            case .stateMismatch: return "Sign-in response failed validation. Try again."
            case .timedOut: return "Sign-in timed out. Try again."
            case .presentationFailed: return "Couldn't open the sign-in browser. Try again."
            case .listenerFailed(let detail): return "Couldn't listen for the sign-in redirect: \(detail)"
            }
        }
    }

    public let path: String
    private let expectedState: String
    /// How long an accepted connection has to deliver a complete request line
    /// before it is dropped. A loopback redirect arrives in milliseconds; the
    /// bound exists so a connection that opens and then stalls cannot hold a
    /// receive (and its buffer) for the whole sign-in.
    private let requestDeadline: Duration
    /// Cap on what one connection may accumulate while its request line is
    /// still unterminated. A callback request line is a few hundred bytes.
    private static let maxRequestLineBytes = 16384
    /// Connections whose request line is still being read. Membership is what
    /// says a completed receive may be parsed: cancelling a connection
    /// completes its pending receive with `isComplete == true, error == nil`,
    /// which is exactly what a peer's half-close looks like, so the receive
    /// alone cannot tell "the browser finished writing" from "the deadline
    /// gave up". `expire` drops the connection from this set before
    /// cancelling it, and every terminal read path drops it too — so an
    /// expiry that lands after the request line was handled is a no-op and
    /// the set cannot grow.
    private var readingConnections: Set<ObjectIdentifier> = []
    private var listener: NWListener?
    private var startWaiter: CheckedContinuation<UInt16, Error>?
    private var codeWaiter: CheckedContinuation<String, Error>?
    /// Buffered outcome for a redirect that lands before waitForCode().
    private var outcome: Result<String, Error>?
    private var finished = false

    public init(expectedState: String, path: String = "/oauth/callback") {
        self.expectedState = expectedState
        self.path = path
        self.requestDeadline = .seconds(10)
    }

    /// Test seam for the accept deadline; the public initializer keeps the
    /// production value.
    init(expectedState: String, path: String = "/oauth/callback", requestDeadline: Duration) {
        self.expectedState = expectedState
        self.path = path
        self.requestDeadline = requestDeadline
    }

    /// Bind to an ephemeral 127.0.0.1 port and return it.
    public func start() async throws -> UInt16 {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        let listener: NWListener
        do {
            listener = try NWListener(using: parameters)
        } catch {
            throw RedirectError.listenerFailed("\(error)")
        }
        self.listener = listener
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { return connection.cancel() }
            Task { await self.accept(connection) }
        }
        return try await withCheckedThrowingContinuation { continuation in
            startWaiter = continuation
            listener.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                Task { await self.listenerStateChanged(state) }
            }
            listener.start(queue: .global(qos: .userInitiated))
        }
    }

    /// Await the redirect. Single-shot: resolves with the code or throws.
    ///
    /// Bounded and cancellation-aware on purpose: the only thing that resumes
    /// this is a redirect landing on the listener, so a browser sheet that
    /// never presents (no anchor, another sheet already up) would otherwise
    /// park the continuation forever and leak the sign-in task with the UI
    /// stuck on the sheet.
    public func waitForCode(timeout: Duration = .seconds(180)) async throws -> String {
        if let outcome {
            return try outcome.get()
        }
        let timeoutTask = Task { [weak self] in
            try? await Task.sleep(for: timeout)
            guard !Task.isCancelled else { return }
            await self?.timeOut()
        }
        defer { timeoutTask.cancel() }

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<String, Error>) in
                // The cancellation handler and the timeout both hop onto the
                // actor to finish(), so either can land before the
                // continuation is installed — resume from the buffered
                // outcome instead of waiting for a resume that already fired.
                if let outcome {
                    continuation.resume(with: outcome)
                } else {
                    codeWaiter = continuation
                }
            }
        } onCancel: {
            Task { await self.cancel() }
        }
    }

    private func timeOut() {
        finish(.failure(RedirectError.timedOut))
    }

    /// Abort (user closed the browser sheet, or the flow owner is bailing).
    public func cancel() {
        finish(.failure(RedirectError.cancelled))
    }

    // MARK: Internals

    private func listenerStateChanged(_ state: NWListener.State) {
        switch state {
        case .ready:
            if let port = listener?.port?.rawValue, let waiter = startWaiter {
                startWaiter = nil
                waiter.resume(returning: port)
            }
        case .failed(let error):
            if let waiter = startWaiter {
                startWaiter = nil
                waiter.resume(throwing: RedirectError.listenerFailed("\(error)"))
            }
            finish(.failure(RedirectError.listenerFailed("\(error)")))
        default:
            break
        }
    }

    private func accept(_ connection: NWConnection) {
        connection.start(queue: .global(qos: .userInitiated))
        readingConnections.insert(ObjectIdentifier(connection))
        // A peer that opens the connection and then stalls — mid-request-line
        // or before writing a byte — would otherwise hold an idle receive for
        // as long as the flow lives, so give it a deadline of its own. Expiry
        // goes through the actor so it is ordered against `received`, and the
        // task holds only the connection and the duration: no reference to
        // the listener, and nothing to cancel once it has run.
        let deadline = Task { [weak self, requestDeadline] in
            try? await Task.sleep(for: requestDeadline)
            guard !Task.isCancelled else { return }
            guard let self else { return connection.cancel() }
            await self.expire(connection)
        }
        receiveRequestLine(on: connection, accumulated: Data(), deadline: deadline)
    }

    /// The deadline fired: drop the connection with its half-written request
    /// line unread. Never resolves the flow — the fragment is not ours to act
    /// on, so the wait stays open for the callback that completes.
    private func expire(_ connection: NWConnection) {
        // Absent means the read already ended on its own; the cancel below
        // would then be racing a response that is already on its way out.
        guard readingConnections.remove(ObjectIdentifier(connection)) != nil else { return }
        connection.cancel()
    }

    /// Terminal for the read side: stop the deadline and forget the
    /// connection, so a deadline that fires afterwards finds nothing to expire.
    private func endReading(_ connection: NWConnection, deadline: Task<Void, Never>) {
        deadline.cancel()
        readingConnections.remove(ObjectIdentifier(connection))
    }

    /// One TCP receive is not one HTTP request: the redirect's request line
    /// may arrive split across segments, so accumulate until it is terminated,
    /// the peer stops writing, or the byte bound is reached.
    private func receiveRequestLine(
        on connection: NWConnection, accumulated: Data, deadline: Task<Void, Never>
    ) {
        connection.receive(
            minimumIncompleteLength: 1,
            maximumLength: Self.maxRequestLineBytes - accumulated.count
        ) { [weak self] data, _, isComplete, error in
            guard let self else {
                deadline.cancel()
                return connection.cancel()
            }
            Task {
                await self.received(
                    data, endOfStream: isComplete || error != nil,
                    on: connection, accumulated: accumulated, deadline: deadline)
            }
        }
    }

    private func received(
        _ data: Data?, endOfStream: Bool, on connection: NWConnection,
        accumulated: Data, deadline: Task<Void, Never>
    ) {
        guard readingConnections.contains(ObjectIdentifier(connection)) else {
            // `expire` already gave up on this connection, and its cancel is
            // what completed this receive. Whatever is buffered is a fragment,
            // not an EOF-terminated request line.
            deadline.cancel()
            connection.cancel()
            return
        }
        var buffer = accumulated
        if let data { buffer += data }

        if let terminator = buffer.range(of: Data("\r\n".utf8)) {
            endReading(connection, deadline: deadline)
            handle(requestLine: buffer[..<terminator.lowerBound], on: connection)
        } else if endOfStream {
            endReading(connection, deadline: deadline)
            // No CRLF, but the peer is done writing: what it sent is all the
            // request line there will ever be.
            if buffer.isEmpty {
                connection.cancel()
            } else {
                handle(requestLine: buffer, on: connection)
            }
        } else if buffer.count >= Self.maxRequestLineBytes {
            // Past the bound with no end in sight. Drop it unanswered rather
            // than act on a truncated line: a truncation splits cleanly enough
            // to parse, which is how a half-delivered callback could hand the
            // flow a truncated `code` and consume the one-shot sign-in.
            endReading(connection, deadline: deadline)
            connection.cancel()
        } else {
            receiveRequestLine(on: connection, accumulated: buffer, deadline: deadline)
        }
    }

    private func handle(requestLine bytes: Data, on connection: NWConnection) {
        guard let requestLine = String(data: bytes, encoding: .utf8) else {
            connection.cancel()
            return
        }
        // "GET /oauth/callback?code=…&state=… HTTP/1.1"
        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2, parts[0] == "GET",
            let components = URLComponents(string: "http://127.0.0.1\(parts[1])"),
            components.path == path
        else {
            respond(on: connection, status: "404 Not Found", body: "Not found.")
            return
        }
        // Exactly-one lookup: a repeated parameter is ambiguous input, and
        // resolving it in the sender's favour (first match wins) is how a
        // smuggled second `state=` slips past validation.
        let query = { (name: String) -> String? in
            let values = (components.queryItems ?? []).filter { $0.name == name }
            guard values.count == 1 else { return nil }
            return values[0].value
        }

        // State first, for denials as much as for successes: a callback that
        // can't prove it belongs to this flow gets an HTTP rejection and the
        // listener keeps waiting, so a stray browser request or a hostile
        // local process can neither hijack the sign-in nor kill it (an
        // unauthenticated `?error=access_denied` used to be enough).
        guard let state = query("state"), state == expectedState else {
            respond(
                on: connection, status: "400 Bad Request",
                body: "Sign-in response failed validation. Restart sign-in from the app.")
            return
        }

        if let error = query("error") {
            let detail = query("error_description") ?? error
            respond(
                on: connection, status: "200 OK",
                body: "Sign-in failed: \(detail). You can close this tab.")
            finish(.failure(RedirectError.denied(detail)))
            return
        }
        // Right state, no usable code and no error: our own flow answering
        // incoherently, so fail the wait instead of holding a flow that
        // nothing can complete.
        guard let code = query("code"), !code.isEmpty
        else {
            respond(
                on: connection, status: "400 Bad Request",
                body: "Sign-in response failed validation. Restart sign-in from the app.")
            finish(.failure(RedirectError.stateMismatch))
            return
        }
        respond(
            on: connection, status: "200 OK",
            body: "Signed in — return to Mercury Voice. You can close this tab.")
        finish(.success(code))
    }

    /// `body` is plain text — it can carry the server's `error_description`,
    /// which a real browser would otherwise render as markup — so it is
    /// escaped into the page rather than interpolated.
    private func respond(on connection: NWConnection, status: String, body: String) {
        let html =
            "<!doctype html><meta charset=\"utf-8\"><title>Mercury Voice</title>"
            + "<body style=\"font-family:-apple-system,sans-serif;padding:2em\">"
            + "<p>\(Self.htmlEscaped(body))</p></body>"
        let payload = Data(html.utf8)
        let head =
            "HTTP/1.1 \(status)\r\nContent-Type: text/html; charset=utf-8\r\n"
            + "Content-Length: \(payload.count)\r\nConnection: close\r\n\r\n"
        connection.send(
            content: Data(head.utf8) + payload,
            completion: .contentProcessed { _ in connection.cancel() })
    }

    /// Escapes per Unicode scalar, which is what an HTML tokenizer reads.
    /// Iterating `Character` would leave a bypass: a grapheme cluster can
    /// swallow a delimiter, because a Prepend code point (U+0600, U+0D4E,
    /// U+110BD…) does not break before the next code point (UAX #29 GB9b),
    /// so `U+0600 <` is one Character that matches none of these cases and
    /// used to be appended verbatim — enough to open a tag, with the `>` of
    /// the surrounding `</p>` closing it.
    private static func htmlEscaped(_ text: String) -> String {
        var escaped = ""
        escaped.unicodeScalars.reserveCapacity(text.unicodeScalars.count)
        for scalar in text.unicodeScalars {
            switch scalar {
            case "&": escaped += "&amp;"
            case "<": escaped += "&lt;"
            case ">": escaped += "&gt;"
            case "\"": escaped += "&quot;"
            case "'": escaped += "&#39;"
            default: escaped.unicodeScalars.append(scalar)
            }
        }
        return escaped
    }

    private func finish(_ result: Result<String, Error>) {
        guard !finished else { return }
        finished = true
        listener?.cancel()
        listener = nil
        if let waiter = codeWaiter {
            codeWaiter = nil
            waiter.resume(with: result)
        } else {
            outcome = result
        }
    }
}

// MARK: - Gateway endpoints

extension HermesAuthenticator {
    /// The system-browser entry point for a native login.
    public static func nativeAuthorizeURL(
        endpoint: ServerEndpoint,
        provider: String,
        challenge: PKCEChallenge,
        redirectURI: String,
        state: String
    ) -> URL {
        endpoint.restURL(
            "/auth/native/authorize",
            query: [
                URLQueryItem(name: "provider", value: provider),
                URLQueryItem(name: "code_challenge", value: challenge.challenge),
                URLQueryItem(name: "code_challenge_method", value: "S256"),
                URLQueryItem(name: "redirect_uri", value: redirectURI),
                URLQueryItem(name: "state", value: state),
            ])
    }

    /// `POST /auth/native/token` — redeem the loopback code + PKCE verifier
    /// for bearer tokens (returned in the JSON body, no cookies).
    public static func redeemNativeCode(
        endpoint: ServerEndpoint,
        provider: String,
        code: String,
        verifier: String
    ) async throws -> PasswordSession {
        var request = URLRequest(url: endpoint.restURL("/auth/native/token"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(
            JSONValue.object([
                "code": .string(code),
                "code_verifier": .string(verifier),
            ]))
        let json = try await perform(
            request, on: URLSession(configuration: cookieFreeConfig()))
        return try passwordSession(fromNativeTokenResponse: json, provider: provider)
    }

    /// Parse the `/auth/native/token` body. Split out for unit testing.
    public static func passwordSession(
        fromNativeTokenResponse json: JSONValue, provider: String
    ) throws -> PasswordSession {
        guard let accessToken = json["access_token"]?.stringValue, !accessToken.isEmpty
        else {
            throw HermesError.malformedResponse("native token response carried no access_token")
        }
        return PasswordSession(
            provider: json["provider"]?.stringValue ?? provider,
            // OAuth identities have no local username; refresh keys off the
            // provider + refresh token, so empty is fine here.
            username: json["user_id"]?.stringValue ?? "",
            accessToken: accessToken,
            refreshToken: json["refresh_token"]?.stringValue ?? "",
            expiresAt: json["expires_at"]?.intValue ?? 0)
    }
}
