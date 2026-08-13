import Foundation

/// Owns the credential state for one server and answers the three questions
/// every transport asks:
///
/// 1. What headers authenticate a REST request right now?
/// 2. What query items authenticate a WebSocket upgrade right now?
///    (Gated mode needs a fresh single-use 30s `?ticket=` per dial, minted
///    via `POST /api/auth/ws-ticket` — never reuse one across dials.)
/// 3. A request came back 401 — can we recover?
///    (Password mode rotates tokens via `POST /auth/native/refresh`;
///    session-token mode cannot recover.)
///
/// Shared by the REST client and the gateway so a token rotation done for
/// one is immediately visible to the other. Rotations are pushed to
/// `onCredentialsChanged` for keychain persistence.
public actor HermesAuthenticator {
    public let endpoint: ServerEndpoint
    public private(set) var credentials: ServerCredentials?
    private let onCredentialsChanged: (@Sendable (ServerCredentials) -> Void)?
    private let urlSession: URLSession

    /// In-flight refresh, so concurrent 401s coalesce into one round trip.
    private var refreshTask: Task<Void, Error>?

    public init(
        endpoint: ServerEndpoint,
        credentials: ServerCredentials?,
        onCredentialsChanged: (@Sendable (ServerCredentials) -> Void)? = nil
    ) {
        self.endpoint = endpoint
        self.credentials = credentials
        self.onCredentialsChanged = onCredentialsChanged
        self.urlSession = URLSession(configuration: Self.cookieFreeConfig())
    }

    /// Auth endpoints set session cookies for the SPA; we are a native
    /// client holding tokens in the keychain instead. Never store or replay
    /// cookies — a stale cookie silently overriding the Bearer header would
    /// be undebuggable.
    static func cookieFreeConfig() -> URLSessionConfiguration {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 30
        config.httpShouldSetCookies = false
        config.httpCookieAcceptPolicy = .never
        return config
    }

    // MARK: REST auth

    public func authHeaders() -> [String: String] {
        switch credentials {
        case .sessionToken(let token) where !token.isEmpty:
            return ["X-Hermes-Session-Token": token]
        case .password(let session):
            return ["Authorization": "Bearer \(session.accessToken)"]
        default:
            return [:]
        }
    }

    // MARK: WebSocket auth

    /// Query items for a WS upgrade. Call once per dial: gated-mode tickets
    /// are single-use with a 30s TTL.
    public func webSocketAuthQuery() async throws -> [URLQueryItem] {
        switch credentials {
        case .sessionToken(let token) where !token.isEmpty:
            return [URLQueryItem(name: "token", value: token)]
        case .password:
            return [URLQueryItem(name: "ticket", value: try await mintWSTicket())]
        default:
            return []
        }
    }

    private func mintWSTicket() async throws -> String {
        do {
            return try await requestWSTicket()
        } catch HermesError.unauthorized {
            // Access token lapsed — rotate once and retry.
            guard try await recoverFromUnauthorized(sentAccessToken: nil) else {
                throw HermesError.unauthorized
            }
            return try await requestWSTicket()
        }
    }

    private func requestWSTicket() async throws -> String {
        var request = URLRequest(url: endpoint.restURL("/api/auth/ws-ticket"))
        request.httpMethod = "POST"
        for (key, value) in authHeaders() {
            request.setValue(value, forHTTPHeaderField: key)
        }
        let json = try await Self.perform(request, on: urlSession)
        guard let ticket = json["ticket"]?.stringValue, !ticket.isEmpty else {
            throw HermesError.malformedResponse("ws-ticket returned no ticket")
        }
        return ticket
    }

    // MARK: 401 recovery

    /// Try to make a retry worthwhile after a 401. Returns false when this
    /// auth mode has no recovery (session-token mode). Throws
    /// `HermesError.sessionExpired` when the refresh token itself is dead —
    /// the user must sign in again.
    ///
    /// `sentAccessToken` is the token the failed request carried, when the
    /// caller knows it; a 401 for an already-rotated token skips the extra
    /// refresh and just signals "retry with current credentials".
    public func recoverFromUnauthorized(sentAccessToken: String?) async throws -> Bool {
        guard case .password(let session) = credentials else { return false }
        if let sentAccessToken, sentAccessToken != session.accessToken {
            return true  // Someone already rotated past the failed token.
        }
        if let refreshTask {
            try await refreshTask.value
            return true
        }
        let task = Task { try await self.refresh(session: session) }
        refreshTask = task
        defer { refreshTask = nil }
        try await task.value
        return true
    }

    private func refresh(session: PasswordSession) async throws {
        var request = URLRequest(url: endpoint.restURL("/auth/native/refresh"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(
            JSONValue.object([
                "refresh_token": .string(session.refreshToken),
                "provider": .string(session.provider),
            ]))

        let json: JSONValue
        do {
            json = try await Self.perform(request, on: urlSession)
        } catch HermesError.unauthorized {
            // Every provider rejected the refresh token: expired or revoked.
            throw HermesError.sessionExpired
        }

        guard let accessToken = json["access_token"]?.stringValue,
            let refreshToken = json["refresh_token"]?.stringValue
        else {
            throw HermesError.malformedResponse("refresh returned no tokens")
        }
        var rotated = session
        rotated.accessToken = accessToken
        rotated.refreshToken = refreshToken
        rotated.expiresAt = json["expires_at"]?.intValue ?? 0
        setCredentials(.password(rotated))
    }

    private func setCredentials(_ new: ServerCredentials) {
        credentials = new
        onCredentialsChanged?(new)
    }

    // MARK: Login (static — no credentials exist yet)

    /// Sign-in options a gated server advertises (public route).
    public static func authProviders(endpoint: ServerEndpoint) async throws
        -> [AuthProviderInfo]
    {
        let request = URLRequest(url: endpoint.restURL("/api/auth/providers"))
        let json = try await perform(request, on: URLSession(configuration: cookieFreeConfig()))
        return json["providers"]?.arrayValue?.compactMap(AuthProviderInfo.init(json:)) ?? []
    }

    /// `POST /auth/password-login` against a password provider ("basic").
    ///
    /// The endpoint is built for the SPA, so the minted tokens arrive as
    /// `Set-Cookie: hermes_session_at/_rt` (optionally `__Secure-`/`__Host-`
    /// prefixed on HTTPS) rather than in the body — lift them out of the
    /// response headers into a keychain-storable `PasswordSession`.
    public static func logIn(
        endpoint: ServerEndpoint,
        provider: String,
        username: String,
        password: String
    ) async throws -> PasswordSession {
        var request = URLRequest(url: endpoint.restURL("/auth/password-login"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(
            JSONValue.object([
                "provider": .string(provider),
                "username": .string(username),
                "password": .string(password),
            ]))

        let session = URLSession(configuration: cookieFreeConfig())
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw HermesError.malformedResponse("not an HTTP response")
        }
        switch http.statusCode {
        case 200..<300:
            break
        case 401, 403:
            throw HermesError.invalidCredentials
        case 429:
            throw HermesError.httpError(
                status: 429, detail: "Too many login attempts — try again shortly.")
        default:
            let detail = (try? JSONDecoder().decode(JSONValue.self, from: data))?["detail"]?
                .stringValue
            throw HermesError.httpError(status: http.statusCode, detail: detail)
        }

        guard
            let tokens = sessionTokens(
                fromResponseHeaders: http.allHeaderFields, url: request.url!)
        else {
            throw HermesError.malformedResponse("login response carried no session cookies")
        }
        return PasswordSession(
            provider: provider,
            username: username,
            accessToken: tokens.accessToken,
            refreshToken: tokens.refreshToken,
            expiresAt: tokens.expiresAt)
    }

    /// Extract the session tokens from a login response's Set-Cookie
    /// headers. Split out (and non-private) for unit testing.
    public static func sessionTokens(
        fromResponseHeaders headers: [AnyHashable: Any], url: URL
    ) -> (accessToken: String, refreshToken: String, expiresAt: Int)? {
        let fields = headers.reduce(into: [String: String]()) { out, pair in
            if let key = pair.key as? String, let value = pair.value as? String {
                out[key] = value
            }
        }
        let cookies = HTTPCookie.cookies(withResponseHeaderFields: fields, for: url)

        func find(_ bare: String) -> HTTPCookie? {
            // The server picks the name variant by deploy shape:
            // bare on HTTP, __Host-/__Secure- prefixed on HTTPS.
            for name in ["__Host-\(bare)", "__Secure-\(bare)", bare] {
                if let cookie = cookies.first(where: { $0.name == name }),
                    !cookie.value.isEmpty
                {
                    return cookie
                }
            }
            return nil
        }

        guard let at = find("hermes_session_at") else { return nil }
        // A provider may omit the refresh token (access-token-only session).
        let rt = find("hermes_session_rt")?.value ?? ""
        let expiresAt = at.expiresDate.map { Int($0.timeIntervalSince1970) } ?? 0
        return (at.value, rt, expiresAt)
    }

    // MARK: Shared HTTP plumbing

    static func perform(
        _ request: URLRequest, on session: URLSession
    ) async throws -> JSONValue {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw HermesError.malformedResponse("not an HTTP response")
        }
        switch http.statusCode {
        case 200..<300:
            break
        case 401, 403:
            throw HermesError.unauthorized
        default:
            let detail = (try? JSONDecoder().decode(JSONValue.self, from: data))?["detail"]?
                .stringValue ?? String(data: data.prefix(300), encoding: .utf8)
            throw HermesError.httpError(status: http.statusCode, detail: detail)
        }
        guard let json = try? JSONDecoder().decode(JSONValue.self, from: data) else {
            throw HermesError.malformedResponse("invalid JSON body")
        }
        return json
    }
}
