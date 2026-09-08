import Foundation
import Testing

@testable import HermesKit

/// Characterize both consumers before sharing their low-level HTTP policy.
/// Wrong status precedence, JSON fallback, cookie replay, or moving recovery
/// into the transport must fail these tests, not silently change login/auth.
@Suite("HTTP policy characterization")
struct HTTPPolicyTests {
    private func endpoint(_ server: RoutedHTTPServer) -> ServerEndpoint {
        ServerEndpoint(baseURL: URL(string: "http://127.0.0.1:\(server.port)")!)
    }

    private func perform(_ endpoint: ServerEndpoint, authenticator: Bool) async throws {
        if authenticator {
            let session = URLSession(configuration: HermesAuthenticator.cookieFreeConfig())
            defer { session.invalidateAndCancel() }
            _ = try await HermesAuthenticator.perform(
                URLRequest(url: endpoint.restURL("/test")), on: session)
        } else {
            try await HermesRESTClient(endpoint: endpoint, token: nil).health()
        }
    }

    @Test(arguments: [false, true], [200, 201, 299])
    func successAcceptsJSONValues(authenticator: Bool, status: Int) async throws {
        let server = try await RoutedHTTPServer.start { _ in .init(status, "[1,null,true]") }
        defer { server.stop() }
        try await perform(endpoint(server), authenticator: authenticator)
    }

    @Test(arguments: [false, true], ["", "not JSON"])
    func successRequiresJSON(authenticator: Bool, body: String) async throws {
        let server = try await RoutedHTTPServer.start { _ in .init(200, body) }
        defer { server.stop() }
        do {
            try await perform(endpoint(server), authenticator: authenticator)
            Issue.record("expected malformed response")
        } catch HermesError.malformedResponse(let detail) {
            #expect(detail == "invalid JSON body")
        }
    }

    @Test(arguments: [false, true], [401, 403, 429, 500])
    func errorStatusPrecedesJSONDecoding(authenticator: Bool, status: Int) async throws {
        let server = try await RoutedHTTPServer.start { _ in
            .init(status, "refused Bearer fake-token")
        }
        defer { server.stop() }
        do {
            try await perform(endpoint(server), authenticator: authenticator)
            Issue.record("expected status error")
        } catch HermesError.unauthorized {
            #expect(status == 401)
        } catch HermesError.httpError(let actual, let detail) {
            #expect(status != 401)
            #expect(actual == status)
            #expect(detail == "refused Bearer «redacted»")
        }
    }

    @Test(arguments: [false, true])
    func errorPrefersJSONDetail(authenticator: Bool) async throws {
        let server = try await RoutedHTTPServer.start { _ in
            .init(500, #"{"detail":"specific","ignored":"other"}"#)
        }
        defer { server.stop() }
        do {
            try await perform(endpoint(server), authenticator: authenticator)
            Issue.record("expected HTTP error")
        } catch HermesError.httpError(let status, let detail) {
            #expect(status == 500)
            #expect(detail == "specific")
        }
    }

    @Test(arguments: [401, 403, 429, 500])
    func loginKeepsItsOwnStatusPolicy(status: Int) async throws {
        let server = try await RoutedHTTPServer.start { _ in .init(status, "not JSON") }
        defer { server.stop() }
        do {
            _ = try await HermesAuthenticator.logIn(
                endpoint: endpoint(server), provider: "basic", username: "alice", password: "fake")
            Issue.record("expected login failure")
        } catch HermesError.invalidCredentials {
            #expect(status == 401 || status == 403)
        } catch HermesError.httpError(let actual, let detail) {
            #expect(actual == status)
            #expect(status == 429 || status == 500)
            #expect(
                detail == (status == 429 ? "Too many login attempts — try again shortly." : nil))
        }
        #expect(server.paths == ["/auth/password-login"])
        #expect(server.requests.first?.headers["authorization"] == nil)
    }

    @Test func loginAcceptsCookiesWithoutJSON() async throws {
        let server = try await RoutedHTTPServer.start { _ in
            .init(
                200, "not JSON", headers: ["Set-Cookie": "hermes_session_at=login-access; Path=/"])
        }
        defer { server.stop() }
        let session = try await HermesAuthenticator.logIn(
            endpoint: endpoint(server), provider: "basic", username: "alice", password: "fake")
        #expect(session.accessToken == "login-access")
        #expect(session.refreshToken == "")
    }

    @Test func sessionsNeverReplayResponseCookies() async throws {
        let server = try await RoutedHTTPServer.start { _ in
            .init(
                200, #"{"ticket":"fresh","active":"voice"}"#,
                headers: ["Set-Cookie": "hermes_session_at=stale; Path=/"])
        }
        defer { server.stop() }
        let auth = HermesAuthenticator(
            endpoint: endpoint(server),
            credentials: .password(
                PasswordSession(
                    provider: "basic", username: "alice", accessToken: "current",
                    refreshToken: "refresh")))
        let rest = HermesRESTClient(endpoint: endpoint(server), authenticator: auth)
        for _ in 0..<2 {
            #expect(try await rest.activeProfile() == "voice")
            #expect(try await auth.webSocketAuthQuery().first?.value == "fresh")
        }
        #expect(server.requests.count == 4)
        for request in server.requests {
            #expect(request.headers["cookie"] == nil)
            #expect(request.headers["authorization"] == "Bearer current")
        }
    }

    @Test func publicProbesDoNotAttachCredentialsOrRefresh() async throws {
        let server = try await RoutedHTTPServer.start { _ in .init(401) }
        defer { server.stop() }
        let auth = HermesAuthenticator(
            endpoint: endpoint(server),
            credentials: .password(
                PasswordSession(
                    provider: "basic", username: "alice", accessToken: "current",
                    refreshToken: "refresh")))
        let rest = HermesRESTClient(endpoint: endpoint(server), authenticator: auth)
        await #expect(throws: HermesError.self) { try await rest.health() }
        await #expect(throws: HermesError.self) { _ = try await rest.status() }
        await #expect(throws: HermesError.self) {
            _ = try await HermesAuthenticator.authProviders(endpoint: endpoint(server))
        }
        #expect(server.paths == ["/api/health", "/api/status", "/api/auth/providers"])
        for request in server.requests {
            #expect(request.headers["authorization"] == nil)
            #expect(request.headers["x-hermes-session-token"] == nil)
        }
    }

    @Test func cookieFreeConfigurationKeepsNativeSessionDefaults() {
        let config = HermesAuthenticator.cookieFreeConfig()
        #expect(config.timeoutIntervalForRequest == 30)
        #expect(!config.httpShouldSetCookies)
        #expect(config.httpCookieAcceptPolicy == .never)
        #expect(config.urlCache?.diskCapacity == 0)
    }
}
