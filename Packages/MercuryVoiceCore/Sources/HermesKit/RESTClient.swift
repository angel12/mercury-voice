import Foundation

/// HTTP client for the Hermes REST surface (`/api/*`).
///
/// Auth comes from the shared `HermesAuthenticator`: `X-Hermes-Session-Token`
/// in loopback token mode, `Authorization: Bearer` in gated password mode
/// (where a 401 triggers one token refresh + retry). The public `/api/health`
/// + `/api/status` skip auth. Endpoints that resolve provider config take
/// `?profile=<name>` — the audio endpoints must always get the conversation's
/// profile.
public struct HermesRESTClient: Sendable {
    public var endpoint: ServerEndpoint
    public let authenticator: HermesAuthenticator
    private let urlSession: URLSession

    /// `GET /api/profiles` walks skill trees and can take tens of seconds.
    public static let profilesTimeout: TimeInterval = 60

    public init(endpoint: ServerEndpoint, authenticator: HermesAuthenticator) {
        self.endpoint = endpoint
        self.authenticator = authenticator
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 30
        // Auth is headers/tickets only; never let a login Set-Cookie sneak
        // into cookie storage and shadow the Bearer header.
        config.httpShouldSetCookies = false
        config.httpCookieAcceptPolicy = .never
        self.urlSession = URLSession(configuration: config)
    }

    public init(endpoint: ServerEndpoint, token: String?) {
        self.init(
            endpoint: endpoint,
            authenticator: HermesAuthenticator(
                endpoint: endpoint,
                credentials: token.map { .sessionToken($0) }))
    }

    // MARK: Public probes (no token)

    public func health() async throws {
        _ = try await get("/api/health", authenticated: false)
    }

    public func status() async throws -> ServerStatus {
        ServerStatus(raw: try await get("/api/status", authenticated: false))
    }

    /// Cheap authed GET used to validate a token before opening the socket.
    public func validateToken() async throws {
        _ = try await get("/api/profiles/active")
    }

    // MARK: Profiles

    public func profiles() async throws -> [ProfileInfo] {
        let json = try await get("/api/profiles", timeout: Self.profilesTimeout)
        return json["profiles"]?.arrayValue?.compactMap(ProfileInfo.init(json:)) ?? []
    }

    public func activeProfile() async throws -> String? {
        let json = try await get("/api/profiles/active")
        return json["active"]?.stringValue ?? json["current"]?.stringValue
    }

    // MARK: Sessions

    /// Cross-profile session list; rows are tagged with their owning profile.
    /// Pass `profile: "all"` for every profile.
    public func profileSessions(
        profile: String, limit: Int = 50, offset: Int = 0, minMessages: Int? = nil
    ) async throws -> [SessionSummary] {
        var query = [
            URLQueryItem(name: "profile", value: profile),
            URLQueryItem(name: "limit", value: String(limit)),
            URLQueryItem(name: "offset", value: String(offset)),
        ]
        if let minMessages {
            query.append(URLQueryItem(name: "min_messages", value: String(minMessages)))
        }
        let json = try await get("/api/profiles/sessions", query: query)
        return json["sessions"]?.arrayValue?.compactMap(SessionSummary.init(json:)) ?? []
    }

    public func sessions(limit: Int = 50, offset: Int = 0) async throws -> [SessionSummary] {
        let json = try await get(
            "/api/sessions",
            query: [
                URLQueryItem(name: "limit", value: String(limit)),
                URLQueryItem(name: "offset", value: String(offset)),
            ])
        return json["sessions"]?.arrayValue?.compactMap(SessionSummary.init(json:)) ?? []
    }

    // MARK: Audio

    /// `POST /api/audio/transcribe` — an empty transcript is success
    /// (silence), not an error; callers must quietly re-listen.
    public func transcribe(
        audio: Data, mimeType: String, profile: String?
    ) async throws -> TranscriptionResult {
        let dataURL = "data:\(mimeType);base64,\(audio.base64EncodedString())"
        let body: JSONValue = [
            "data_url": .string(dataURL),
            "mime_type": .string(mimeType),
        ]
        let json = try await post(
            "/api/audio/transcribe",
            query: profileQuery(profile),
            body: body,
            timeout: 120)
        return TranscriptionResult(
            transcript: json["transcript"]?.stringValue ?? "",
            provider: json["provider"]?.stringValue)
    }

    /// `POST /api/audio/speak` — whole-clip TTS fallback for providers with
    /// no chunked API.
    public func speak(text: String, profile: String?) async throws -> SpokenClip {
        let json = try await post(
            "/api/audio/speak",
            query: profileQuery(profile),
            body: ["text": .string(text)],
            timeout: 120)
        guard let dataURL = json["data_url"]?.stringValue else {
            throw HermesError.malformedResponse("speak returned no data_url")
        }
        return SpokenClip(dataURL: dataURL, mimeType: json["mime_type"]?.stringValue)
    }

    /// `GET /api/audio/voice-config` — the profile's STT/TTS resolution for
    /// client-direct voice. Throws on older backends (404) and transport
    /// failures; callers treat any throw as "relay everything".
    public func voiceConfig(profile: String?) async throws -> VoiceClientConfig {
        let json = try await get("/api/audio/voice-config", query: profileQuery(profile))
        return VoiceClientConfig(json: json)
    }

    /// ws(s) URL for the streaming TTS socket (`/api/audio/speak-stream`).
    /// Build one per dial — gated mode embeds a fresh single-use ticket.
    public func speakStreamURL(profile: String?) async throws -> URL {
        var query = try await authenticator.webSocketAuthQuery()
        if let profile, !profile.isEmpty {
            query.append(URLQueryItem(name: "profile", value: profile))
        }
        return endpoint.webSocketURL("/api/audio/speak-stream", query: query)
    }

    // MARK: Plumbing

    private func profileQuery(_ profile: String?) -> [URLQueryItem] {
        guard let profile, !profile.isEmpty else { return [] }
        return [URLQueryItem(name: "profile", value: profile)]
    }

    private func get(
        _ path: String,
        query: [URLQueryItem] = [],
        authenticated: Bool = true,
        timeout: TimeInterval = 30
    ) async throws -> JSONValue {
        var request = URLRequest(url: endpoint.restURL(path, query: query))
        request.timeoutInterval = timeout
        if authenticated {
            return try await performAuthenticated(request)
        }
        return try await perform(request)
    }

    private func post(
        _ path: String,
        query: [URLQueryItem] = [],
        body: JSONValue,
        timeout: TimeInterval = 30
    ) async throws -> JSONValue {
        var request = URLRequest(url: endpoint.restURL(path, query: query))
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(body)
        return try await performAuthenticated(request)
    }

    /// Attach the current auth headers and perform. In password mode a 401
    /// means the access token lapsed — refresh once and retry with the
    /// rotated token; a second 401 (or a dead refresh token) surfaces.
    private func performAuthenticated(_ request: URLRequest) async throws -> JSONValue {
        var attempt = request
        var headers = await authenticator.authHeaders()
        for (key, value) in headers {
            attempt.setValue(value, forHTTPHeaderField: key)
        }
        do {
            return try await perform(attempt)
        } catch HermesError.unauthorized {
            let sentToken = headers["Authorization"].map {
                String($0.dropFirst("Bearer ".count))
            }
            guard try await authenticator.recoverFromUnauthorized(sentAccessToken: sentToken)
            else { throw HermesError.unauthorized }

            var retry = request
            headers = await authenticator.authHeaders()
            for (key, value) in headers {
                retry.setValue(value, forHTTPHeaderField: key)
            }
            return try await perform(retry)
        }
    }

    private func perform(_ request: URLRequest) async throws -> JSONValue {
        let (data, response) = try await urlSession.data(for: request)
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
