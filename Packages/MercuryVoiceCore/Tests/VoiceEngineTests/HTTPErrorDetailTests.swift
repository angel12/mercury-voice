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

    @Test func jsonErrorDropsSplitScalarAtDisplayLimit() {
        let message = String(repeating: "A", count: 299) + "😀"
        #expect(message.utf8.count == 303)
        let detail = DirectVoiceClient.errorDetail(
            Data("{\"error\":{\"message\":\"\(message)\"}}".utf8))
        #expect(detail.utf8.count <= Self.displayLimit)
        #expect(detail == String(repeating: "A", count: 299))
        #expect(!detail.contains("\u{FFFD}"))
        #expect(!detail.contains("😀"))
    }

    @Test func jsonErrorPreservesExactByteBoundary() {
        let message = String(repeating: "C", count: 296) + "😀"
        #expect(message.utf8.count == Self.displayLimit)
        let detail = DirectVoiceClient.errorDetail(
            Data("{\"error\":{\"message\":\"\(message)\"}}".utf8))
        #expect(detail == message)
        #expect(detail.contains("😀"))
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
        // Application accumulation stopped at 64 KiB and this request's TCP
        // connection closed. That is not a bound on URLSession buffering.
        #expect(await eventually { server.peerClosed })
    }

    @Test func errorReadRedactsSecretCutAtReadBoundary() async throws {
        let secret = "sk-" + String(repeating: "K", count: HTTPErrorDetail.errorReadLimit)
        let body = Data("invalid Bearer \(secret) leftover".utf8)
        let server = try await ScriptedHTTPServer.start(status: 500, body: body)
        defer { server.stop() }

        do {
            _ = try await DirectVoiceClient().synthesize(
                config: try ttsConfig(port: server.port),
                text: "Hello there, this is spoken.")
            Issue.record("expected provider error")
        } catch let DirectVoiceError.provider(_, _, detail) {
            #expect(!detail.contains(String(repeating: "K", count: 16)))
            #expect(detail.contains("«redacted»"))
            #expect(detail.utf8.count <= Self.displayLimit)
        } catch {
            Issue.record("unexpected error \(error)")
        }
    }

    @Test func cancellingSynthesizeClosesTheRequest() async throws {
        // Headers + a tiny prefix with a huge Content-Length parks production
        // `bytes(for:)` inside `collect` so Task.cancel can hit it.
        let server = try await ScriptedHTTPServer.start(
            status: 200,
            body: Data(repeating: 0x7F, count: 16),
            contentType: "audio/mpeg",
            declaredLength: 10_000_000,
            stallSeconds: 15)
        defer { server.stop() }

        let task = Task {
            try await DirectVoiceClient().synthesize(
                config: try ttsConfig(port: server.port),
                text: "Hello there, this is spoken.")
        }
        #expect(await eventually { server.responseSent })
        task.cancel()

        do {
            _ = try await task.value
            Issue.record("expected cancellation")
        } catch is CancellationError {
            // Task cancellation through production `bytes(for:)`.
        } catch let error as URLError where error.code == .cancelled {
            // Foundation may surface the same cancel as URLError.cancelled.
        } catch {
            Issue.record("unexpected error \(error)")
        }
        #expect(await eventually { server.peerClosed })
    }
}
