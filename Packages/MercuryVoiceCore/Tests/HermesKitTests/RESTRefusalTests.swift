import Foundation
import Testing

@testable import HermesKit

/// Issue #60, REST half: 401 and 403 are not the same answer.
///
/// A 401 means "this access token lapsed" — the one case a refresh can fix.
/// A 403 means "this request is refused" (Host/Origin guard, peer check,
/// permission gate); no rotation makes it succeed, so burning the refresh
/// token on it both wastes a round trip and, when the refresh itself is
/// rejected, ends in a bogus "your session has expired, sign in again".
///
/// Every case here runs the production `HermesRESTClient` / `HermesAuthenticator`
/// paths against a loopback server that records which routes were hit, so
/// "no refresh happened" is an observation rather than a mock expectation.
@Suite("REST refusal handling")
struct RESTRefusalTests {
    private static let refreshPath = "/auth/native/refresh"

    private static func passwordClient(
        port: UInt16, onChange: (@Sendable (ServerCredentials) -> Void)? = nil
    ) -> (client: HermesRESTClient, authenticator: HermesAuthenticator) {
        let endpoint = ServerEndpoint(baseURL: URL(string: "http://127.0.0.1:\(port)")!)
        let authenticator = HermesAuthenticator(
            endpoint: endpoint,
            credentials: .password(
                PasswordSession(
                    provider: "basic", username: "alice",
                    accessToken: "access-1", refreshToken: "refresh-1")),
            onCredentialsChanged: onChange)
        return (HermesRESTClient(endpoint: endpoint, authenticator: authenticator), authenticator)
    }

    /// A refresh answer with rotated tokens — served so that a spurious
    /// refresh *succeeds*, which is exactly what makes the current behavior
    /// silent: the token rotates for nothing.
    private static let rotatedTokens =
        #"{"access_token":"access-2","refresh_token":"refresh-2","expires_at":0}"#

    // MARK: 403 must not touch credentials

    @Test func forbiddenGetNeverRefreshesTheToken() async throws {
        let server = try await RoutedHTTPServer.start { request in
            request.path.hasPrefix(Self.refreshPath)
                ? .init(200, Self.rotatedTokens)
                : .init(403, #"{"detail":"origin not allowed"}"#)
        }
        defer { server.stop() }
        let (client, authenticator) = Self.passwordClient(port: server.port)

        do {
            try await client.validateToken()
            Issue.record("expected the request to fail")
        } catch let HermesError.httpError(status, detail) {
            #expect(status == 403)
            #expect(detail == "origin not allowed")
        } catch {
            Issue.record("expected httpError(403), got \(error)")
        }

        #expect(server.requestCount(forPath: Self.refreshPath) == 0)
        #expect(server.requestCount(forPath: "/api/profiles/active") == 1)
        // The credentials are untouched: a refused request is no evidence
        // that they lapsed.
        let unrotated = ServerCredentials.password(
            PasswordSession(
                provider: "basic", username: "alice",
                accessToken: "access-1", refreshToken: "refresh-1"))
        #expect(await authenticator.credentials == unrotated)
    }

    @Test func forbiddenAudioPostNeverRefreshesTheToken() async throws {
        // The audio endpoints are the busiest authenticated POSTs in the app
        // and go through the same `performAuthenticated`; a 403 there must
        // not rotate credentials either.
        let server = try await RoutedHTTPServer.start { request in
            request.path.hasPrefix(Self.refreshPath)
                ? .init(200, Self.rotatedTokens)
                : .init(403, #"{"detail":"transcription not permitted"}"#)
        }
        defer { server.stop() }
        let (client, _) = Self.passwordClient(port: server.port)

        do {
            _ = try await client.transcribe(
                audio: Data("pcm".utf8), mimeType: "audio/wav", profile: "voice")
            Issue.record("expected the request to fail")
        } catch let HermesError.httpError(status, detail) {
            #expect(status == 403)
            #expect(detail == "transcription not permitted")
        } catch {
            Issue.record("expected httpError(403), got \(error)")
        }

        #expect(server.requestCount(forPath: Self.refreshPath) == 0)
        #expect(server.requestCount(forPath: "/api/audio/transcribe") == 1)
    }

    @Test func forbiddenWSTicketNeverRefreshesTheToken() async throws {
        // The gateway dial mints a ticket first. A 403 there used to spend the
        // refresh token and, on a server that refuses that too, surface as
        // `sessionExpired` — a sign-in prompt for credentials that are fine.
        let server = try await RoutedHTTPServer.start { request in
            request.path.hasPrefix(Self.refreshPath)
                ? .init(401, #"{"detail":"no"}"#)
                : .init(403, #"{"detail":"peer refused"}"#)
        }
        defer { server.stop() }
        let (_, authenticator) = Self.passwordClient(port: server.port)

        do {
            _ = try await authenticator.webSocketAuthQuery()
            Issue.record("expected the ticket request to fail")
        } catch let HermesError.httpError(status, detail) {
            #expect(status == 403)
            #expect(detail == "peer refused")
        } catch {
            Issue.record("expected httpError(403), got \(error)")
        }

        #expect(server.requestCount(forPath: Self.refreshPath) == 0)
        #expect(server.requestCount(forPath: "/api/auth/ws-ticket") == 1)
    }

    @Test func forbiddenInTokenModeIsNotATokenRejection() async throws {
        // Loopback token mode has no refresh at all, so the only harm is the
        // story: `.unauthorized` tells the user to paste a fresh dashboard
        // URL, which cannot fix an access refusal.
        let server = try await RoutedHTTPServer.start { _ in
            .init(403, #"{"detail":"host header mismatch"}"#)
        }
        defer { server.stop() }
        let endpoint = ServerEndpoint(baseURL: URL(string: "http://127.0.0.1:\(server.port)")!)
        let client = HermesRESTClient(endpoint: endpoint, token: "session-token")

        do {
            _ = try await client.activeProfile()
            Issue.record("expected the request to fail")
        } catch let HermesError.httpError(status, detail) {
            #expect(status == 403)
            #expect(detail == "host header mismatch")
        } catch {
            Issue.record("expected httpError(403), got \(error)")
        }
    }

    // MARK: 401 keeps its one refresh + retry

    @Test func unauthorizedGetStillRefreshesOnceAndRetries() async throws {
        let attempts = CallCounter()
        let server = try await RoutedHTTPServer.start { request in
            if request.path.hasPrefix(Self.refreshPath) {
                return .init(200, Self.rotatedTokens)
            }
            // First call carries the lapsed token; the retry carries the
            // rotated one and succeeds.
            return attempts.next() == 1
                ? .init(401, #"{"detail":"token expired"}"#)
                : .init(200, #"{"active":"voice"}"#)
        }
        defer { server.stop() }
        let (client, authenticator) = Self.passwordClient(port: server.port)

        let active = try await client.activeProfile()
        #expect(active == "voice")
        #expect(server.requestCount(forPath: Self.refreshPath) == 1)
        #expect(server.requestCount(forPath: "/api/profiles/active") == 2)
        if case .password(let session)? = await authenticator.credentials {
            #expect(session.accessToken == "access-2")
        } else {
            Issue.record("expected rotated password credentials")
        }
    }

    @Test func deadRefreshTokenStillEndsAsSessionExpired() async throws {
        // The genuine expired-session path must survive the 403 split: a 401
        // on the request AND a 401 on the refresh is the one case that means
        // "sign in again".
        let server = try await RoutedHTTPServer.start { _ in .init(401, #"{"detail":"no"}"#) }
        defer { server.stop() }
        let (client, _) = Self.passwordClient(port: server.port)

        do {
            try await client.validateToken()
            Issue.record("expected the request to fail")
        } catch HermesError.sessionExpired {
            // The one honest "sign in again".
        } catch {
            Issue.record("expected sessionExpired, got \(error)")
        }
        #expect(server.requestCount(forPath: Self.refreshPath) == 1)
    }
}

/// Counts calls from the server's queue; `next()` returns the 1-based index.
final class CallCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    func next() -> Int {
        lock.withLock {
            count += 1
            return count
        }
    }

    var calls: Int { lock.withLock { count } }
}
