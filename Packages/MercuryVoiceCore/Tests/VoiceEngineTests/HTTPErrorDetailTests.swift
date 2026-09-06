import Foundation
import Testing

@testable import HermesKit
@testable import VoiceEngine

/// Issue #74: JSON error strings must not bypass the 300-byte plain-body cap,
/// and the bound has to hold on the real `synthesize` → `perform` path.
@Suite("Bounded provider error details")
struct HTTPErrorDetailTests {
    private static let displayLimit = HTTPErrorDetail.displayLimit

    private func ttsConfig(port: UInt16) throws -> DirectTTSConfig {
        let json = try JSONDecoder().decode(
            JSONValue.self,
            from: Data(
                """
                {"mode": "direct", "wire": "openai-speech", "provider": "openai",
                 "base_url": "http://127.0.0.1:\(port)/v1", "api_key": "sk-test"}
                """.utf8))
        return try #require(DirectTTSConfig(json: json))
    }

    @Test func oversizedJSONErrorMessageIsCappedLikePlainText() {
        let message = String(repeating: "A", count: 400)
        let detail = DirectVoiceClient.errorDetail(
            Data("{\"error\":{\"message\":\"\(message)\"}}".utf8))
        #expect(detail.utf8.count <= Self.displayLimit)
        #expect(detail.hasPrefix("AAA"))
        #expect(!detail.contains(String(repeating: "A", count: 400)))
    }

    @Test func oversizedPlainBodyStaysCappedAt300() {
        let body = String(repeating: "P", count: 400)
        let detail = DirectVoiceClient.errorDetail(Data(body.utf8))
        #expect(detail.utf8.count == Self.displayLimit)
    }

    @Test func synthesizeThrowsCappedJSONErrorThroughPerform() async throws {
        let message = String(repeating: "A", count: 400) + "TAIL-MARKER"
        let body = Data("{\"error\":{\"message\":\"\(message)\"}}".utf8)
        let server = try await ScriptedHTTPServer.start(status: 500, body: body)
        defer { server.stop() }

        let client = DirectVoiceClient()
        let config = try ttsConfig(port: server.port)
        do {
            _ = try await client.synthesize(config: config, text: "Hello there, this is spoken.")
            Issue.record("expected provider error")
        } catch let DirectVoiceError.provider(_, status, detail) {
            #expect(status == 500)
            #expect(detail.utf8.count <= Self.displayLimit)
            #expect(detail.hasPrefix("AAA"))
            #expect(!detail.contains("TAIL-MARKER"))
            #expect((DirectVoiceError.provider(
                name: "openai TTS", status: status, detail: detail
            ).errorDescription ?? "").utf8.count < 400)
        } catch {
            Issue.record("unexpected error \(error)")
        }
    }

    @Test func jsonErrorRedactsBearerAndProviderKeys() {
        let detail = DirectVoiceClient.errorDetail(
            Data(
                #"{"error":{"message":"invalid Bearer sk-live-SUPERSECRETVALUE123 and xai-ALSOSECRET999"}}"#
                    .utf8))
        #expect(!detail.contains("SUPERSECRETVALUE123"))
        #expect(!detail.contains("ALSOSECRET999"))
        #expect(detail.contains("«redacted»"))
    }

    @Test func synthesizeKeepsSuccessAudioLargerThanErrorReadLimit() async throws {
        let audio = Data(repeating: 0x7F, count: HTTPErrorDetail.errorReadLimit + 16_384)
        let server = try await ScriptedHTTPServer.start(
            status: 200, body: audio, contentType: "audio/mpeg")
        defer { server.stop() }

        let data = try await DirectVoiceClient().synthesize(
            config: try ttsConfig(port: server.port),
            text: "Hello there, this is spoken.")
        #expect(data.count == audio.count)
        #expect(data == audio)
    }

    @Test func errorReadStopsBeforeDeclaredLength() async throws {
        let message = String(repeating: "A", count: HTTPErrorDetail.errorReadLimit + 2048)
        let body = Data("{\"error\":{\"message\":\"\(message)\"}}".utf8)
        let server = try await ScriptedHTTPServer.start(
            status: 500,
            body: body,
            declaredLength: 10_000_000,
            stallSeconds: 15)
        defer { server.stop() }

        let started = ContinuousClock.now
        do {
            _ = try await DirectVoiceClient().synthesize(
                config: try ttsConfig(port: server.port),
                text: "Hello there, this is spoken.")
            Issue.record("expected provider error")
        } catch let DirectVoiceError.provider(_, status, detail) {
            #expect(status == 500)
            #expect(detail.utf8.count <= Self.displayLimit)
        } catch {
            Issue.record("unexpected error \(error)")
        }
        #expect(ContinuousClock.now - started < .seconds(3))
    }
}
