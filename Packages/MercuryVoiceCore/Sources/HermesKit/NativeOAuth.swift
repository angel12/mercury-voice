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
/// on IDP denial, state mismatch, or `cancel()`.
public actor LoopbackRedirectListener {
    public enum RedirectError: Error, LocalizedError, Equatable {
        case cancelled
        case denied(String)
        case stateMismatch
        case listenerFailed(String)

        public var errorDescription: String? {
            switch self {
            case .cancelled: return "Sign-in was cancelled."
            case .denied(let detail): return "Sign-in was denied: \(detail)"
            case .stateMismatch: return "Sign-in response failed validation (state mismatch)."
            case .listenerFailed(let detail): return "Couldn't listen for the sign-in redirect: \(detail)"
            }
        }
    }

    public let path: String
    private let expectedState: String
    private var listener: NWListener?
    private var startWaiter: CheckedContinuation<UInt16, Error>?
    private var codeWaiter: CheckedContinuation<String, Error>?
    /// Buffered outcome for a redirect that lands before waitForCode().
    private var outcome: Result<String, Error>?
    private var finished = false

    public init(expectedState: String, path: String = "/oauth/callback") {
        self.expectedState = expectedState
        self.path = path
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
    public func waitForCode() async throws -> String {
        if let outcome {
            return try outcome.get()
        }
        return try await withCheckedThrowingContinuation { codeWaiter = $0 }
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
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16384) {
            [weak self] data, _, _, _ in
            guard let self else { return connection.cancel() }
            Task { await self.handle(request: data, on: connection) }
        }
    }

    private func handle(request data: Data?, on connection: NWConnection) {
        guard let data, let text = String(data: data, encoding: .utf8),
            let requestLine = text.split(separator: "\r\n").first
        else {
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
        let query = { (name: String) -> String? in
            components.queryItems?.first(where: { $0.name == name })?.value
        }

        if let error = query("error") {
            let detail = query("error_description") ?? error
            respond(
                on: connection, status: "200 OK",
                body: "Sign-in failed: \(detail). You can close this tab.")
            finish(.failure(RedirectError.denied(detail)))
            return
        }
        guard query("state") == expectedState, let code = query("code"), !code.isEmpty
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

    private func respond(on connection: NWConnection, status: String, body: String) {
        let html =
            "<!doctype html><meta charset=\"utf-8\"><title>Mercury Voice</title>"
            + "<body style=\"font-family:-apple-system,sans-serif;padding:2em\">"
            + "<p>\(body)</p></body>"
        let payload = Data(html.utf8)
        let head =
            "HTTP/1.1 \(status)\r\nContent-Type: text/html; charset=utf-8\r\n"
            + "Content-Length: \(payload.count)\r\nConnection: close\r\n\r\n"
        connection.send(
            content: Data(head.utf8) + payload,
            completion: .contentProcessed { _ in connection.cancel() })
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
