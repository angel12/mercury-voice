import Foundation
import Testing

@testable import HermesKit

/// Issue #125, contract v7: `POST /api/audio/tts-lease` acquires/releases a
/// server-side TTS model warm-up for a named surface
/// (`hermes_cli/web_routers/audio.py:340`). `ttsLease` swallows every error
/// — a 404 from an older backend, a network failure, a non-2xx status — so
/// callers can fire it without a try.
@Suite("TTS lease")
struct TTSLeaseTests {
    @Test func acquireSendsLeaseAndActiveWithProfileQuery() async throws {
        let server = try await RoutedHTTPServer.start { _ in .init(200, #"{"ok":true}"#) }
        defer { server.stop() }
        let endpoint = ServerEndpoint(baseURL: URL(string: "http://127.0.0.1:\(server.port)")!)
        let client = HermesRESTClient(endpoint: endpoint, token: "session-token")

        await client.ttsLease("mercury:conversation:abc-123", active: true, profile: "voice")

        #expect(server.requests.count == 1)
        let request = try #require(server.requests.first)
        #expect(request.method == "POST")
        #expect(request.path == "/api/audio/tts-lease?profile=voice")
        let body = try #require(
            JSONSerialization.jsonObject(with: request.body) as? [String: Any])
        #expect(body["lease"] as? String == "mercury:conversation:abc-123")
        #expect(body["active"] as? Bool == true)
    }

    @Test func releaseSendsActiveFalseWithNoProfileQueryWhenNil() async throws {
        let server = try await RoutedHTTPServer.start { _ in .init(200, #"{"ok":true}"#) }
        defer { server.stop() }
        let endpoint = ServerEndpoint(baseURL: URL(string: "http://127.0.0.1:\(server.port)")!)
        let client = HermesRESTClient(endpoint: endpoint, token: "session-token")

        await client.ttsLease("mercury:conversation:abc-123", active: false, profile: nil)

        let request = try #require(server.requests.first)
        #expect(request.path == "/api/audio/tts-lease")
        let body = try #require(
            JSONSerialization.jsonObject(with: request.body) as? [String: Any])
        #expect(body["active"] as? Bool == false)
    }

    @Test func notFoundOnAnOlderBackendDoesNotThrow() async throws {
        // Older backends don't have the route at all; the call must swallow
        // the 404 rather than surfacing it, since acquiring the lease is
        // best-effort and never gates listening.
        let server = try await RoutedHTTPServer.start { _ in .init(404, #"{"detail":"not found"}"#)
        }
        defer { server.stop() }
        let endpoint = ServerEndpoint(baseURL: URL(string: "http://127.0.0.1:\(server.port)")!)
        let client = HermesRESTClient(endpoint: endpoint, token: "session-token")

        // Does not throw — there is nothing to catch.
        await client.ttsLease("mercury:conversation:abc-123", active: true, profile: nil)
        #expect(server.requests.count == 1)
    }

    @Test func networkFailureDoesNotThrow() async throws {
        // No server listening at all: the connection itself fails.
        let endpoint = ServerEndpoint(baseURL: URL(string: "http://127.0.0.1:1")!)
        let client = HermesRESTClient(endpoint: endpoint, token: "session-token")

        await client.ttsLease("mercury:conversation:abc-123", active: true, profile: nil)
    }
}
