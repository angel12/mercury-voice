import Foundation
import Testing

@testable import HermesKit

@Suite("ServerCredentials codec")
struct ServerCredentialsTests {
    @Test func passwordSessionRoundTrips() throws {
        let original = ServerCredentials.password(
            PasswordSession(
                provider: "basic",
                username: "spencer",
                accessToken: "at-123",
                refreshToken: "rt-456",
                expiresAt: 1_754_000_000))
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(ServerCredentials.self, from: data)
        #expect(decoded == original)
    }

    @Test func sessionTokenRoundTrips() throws {
        let original = ServerCredentials.sessionToken("tok-abc")
        let decoded = try JSONDecoder().decode(
            ServerCredentials.self, from: JSONEncoder().encode(original))
        #expect(decoded == original)
    }

    /// A pre-credentials keychain item is a raw token string, not JSON —
    /// decoding must fail so the store's legacy fallback kicks in.
    @Test func legacyRawTokenIsNotDecodable() {
        let legacy = Data("plain-legacy-token".utf8)
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(ServerCredentials.self, from: legacy)
        }
    }
}

@Suite("Password login cookie extraction")
struct SessionCookieParsingTests {
    private let httpURL = URL(string: "http://192.168.1.20:8080/auth/password-login")!
    private let httpsURL = URL(string: "https://hermes.example.com/auth/password-login")!

    @Test func extractsBareCookiesOnHTTP() throws {
        // Two Set-Cookie headers arrive comma-joined in allHeaderFields.
        let headers: [AnyHashable: Any] = [
            "Set-Cookie": "hermes_session_at=at-token; Max-Age=43200; Path=/; HttpOnly; SameSite=lax, hermes_session_rt=rt-token; Max-Age=2592000; Path=/; HttpOnly; SameSite=lax"
        ]
        let tokens = try #require(
            HermesAuthenticator.sessionTokens(
                fromResponseHeaders: headers, url: httpURL))
        #expect(tokens.accessToken == "at-token")
        #expect(tokens.refreshToken == "rt-token")
        #expect(tokens.expiresAt > Int(Date().timeIntervalSince1970))
    }

    @Test func extractsHostPrefixedCookiesOnHTTPS() throws {
        let headers: [AnyHashable: Any] = [
            "Set-Cookie": "__Host-hermes_session_at=at-2; Max-Age=43200; Path=/; Secure; HttpOnly; SameSite=lax, __Host-hermes_session_rt=rt-2; Max-Age=2592000; Path=/; Secure; HttpOnly; SameSite=lax"
        ]
        let tokens = try #require(
            HermesAuthenticator.sessionTokens(
                fromResponseHeaders: headers, url: httpsURL))
        #expect(tokens.accessToken == "at-2")
        #expect(tokens.refreshToken == "rt-2")
    }

    @Test func refreshTokenIsOptional() throws {
        let headers: [AnyHashable: Any] = [
            "Set-Cookie": "hermes_session_at=only-at; Max-Age=60; Path=/; HttpOnly"
        ]
        let tokens = try #require(
            HermesAuthenticator.sessionTokens(
                fromResponseHeaders: headers, url: httpURL))
        #expect(tokens.accessToken == "only-at")
        #expect(tokens.refreshToken.isEmpty)
    }

    @Test func missingAccessTokenIsNil() {
        let headers: [AnyHashable: Any] = [
            "Set-Cookie": "hermes_session_provider=basic; Max-Age=60; Path=/"
        ]
        #expect(
            HermesAuthenticator.sessionTokens(
                fromResponseHeaders: headers, url: httpURL) == nil)
    }
}
