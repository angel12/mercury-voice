import Foundation
import Testing

@testable import HermesKit

/// Issue #146 (upstream 5f23cac568, e40f293796, 7ee2840c06):
/// `POST /api/audio/stt-lease` pre-loads the backend's local faster-whisper
/// model so a cold load doesn't eat the transcribe timeout. Same wire as the
/// TTS lease; best-effort, so every failure is swallowed — a 404/405 from an
/// older backend, a transport error, any non-2xx status.
@Suite("STT lease")
struct STTLeaseTests {
    private func client(port: UInt16) -> HermesRESTClient {
        HermesRESTClient(
            endpoint: ServerEndpoint(baseURL: URL(string: "http://127.0.0.1:\(port)")!),
            token: "session-token")
    }

    @Test func acquireSendsLeaseAndActiveWithProfileQuery() async throws {
        let server = try await RoutedHTTPServer.start { _ in
            .init(200, #"{"ok":true,"action":"loaded","warmed":true,"leases":1}"#)
        }
        defer { server.stop() }

        await client(port: server.port).sttLease(
            "mercury:voice-input:abc-123", active: true, profile: "voice")

        let request = try #require(server.requests.first)
        #expect(server.requests.count == 1)
        #expect(request.method == "POST")
        #expect(request.path == "/api/audio/stt-lease?profile=voice")
        let body = try #require(
            JSONSerialization.jsonObject(with: request.body) as? [String: Any])
        #expect(body["lease"] as? String == "mercury:voice-input:abc-123")
        #expect(body["active"] as? Bool == true)
    }

    @Test func releaseSendsActiveFalseWithNoProfileQueryWhenNil() async throws {
        let server = try await RoutedHTTPServer.start { _ in .init(200, #"{"leases":0}"#) }
        defer { server.stop() }

        await client(port: server.port).sttLease(
            "mercury:voice-input:abc-123", active: false, profile: nil)

        let request = try #require(server.requests.first)
        #expect(request.path == "/api/audio/stt-lease")
        let body = try #require(
            JSONSerialization.jsonObject(with: request.body) as? [String: Any])
        #expect(body["active"] as? Bool == false)
    }

    @Test(arguments: [404, 405, 500])
    func olderBackendOrServerErrorDoesNotThrow(status: Int) async throws {
        let server = try await RoutedHTTPServer.start { _ in .init(status, #"{"detail":"no"}"#) }
        defer { server.stop() }

        await client(port: server.port).sttLease("lease", active: true, profile: nil)
        #expect(server.requests.count == 1)
    }

    @Test func networkFailureDoesNotThrow() async {
        await client(port: 1).sttLease("lease", active: true, profile: nil)
    }

    /// A cold faster-whisper download + load can take minutes; the acquire
    /// blocks until warm, so it gets upstream's 180 s budget, not the 30 s
    /// default.
    @Test func acquireBudgetMatchesUpstream() {
        #expect(HermesRESTClient.sttLeaseTimeout == 180)
    }
}
