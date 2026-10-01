import Foundation
import Testing

@testable import HermesKit
@testable import VoiceEngine

/// Issue #146: the relay transcriber warms the backend's local STT model at
/// every listen start and holds the transcription back until that warm-up
/// settles, so a cold model load is paid while the user is still talking
/// instead of inside the transcribe timeout (desktop parity).
@Suite("STT warm-up")
struct STTWarmupTests {
    @Test func startAcquiresAndReadyWaitsForIt() async {
        let acquire = GatedAcquire()
        let warmup = STTWarmup(shouldWarm: { true }, acquire: { await acquire.run() })

        await warmup.start()
        #expect(await eventually { acquire.calls == 1 })

        let ready = Task { await warmup.ready(); return true }
        try? await Task.sleep(for: .milliseconds(50))
        #expect(acquire.calls == 1)
        acquire.open()
        #expect(await ready.value)
    }

    @Test func startWhileInFlightDoesNotAcquireTwice() async {
        let acquire = GatedAcquire()
        let warmup = STTWarmup(shouldWarm: { true }, acquire: { await acquire.run() })

        await warmup.start()
        await warmup.start()
        #expect(await eventually { acquire.calls == 1 })
        acquire.open()
        await warmup.ready()
        #expect(acquire.calls == 1)
    }

    /// Idle-unload can evict the model between turns, so each listen start
    /// after the previous warm-up settled acquires again.
    @Test func startAfterSettlingAcquiresAgain() async {
        let acquire = GatedAcquire()
        acquire.open()
        let warmup = STTWarmup(shouldWarm: { true }, acquire: { await acquire.run() })

        await warmup.start()
        await warmup.ready()
        await warmup.start()
        await warmup.ready()
        #expect(acquire.calls == 2)
    }

    @Test func noWarmUpWhenNotNeeded() async {
        let acquire = GatedAcquire()
        let warmup = STTWarmup(shouldWarm: { false }, acquire: { await acquire.run() })

        await warmup.start()
        await warmup.ready()
        #expect(acquire.calls == 0)
    }

    @Test func readyWithoutStartReturnsImmediately() async {
        let warmup = STTWarmup(shouldWarm: { true }, acquire: {})
        await warmup.ready()
    }

    // MARK: RestTranscriber wiring

    /// Client-direct STT goes to a remote provider: the backend's local model
    /// is never used, so there is nothing to warm.
    @Test func directSTTSkipsTheLease() async throws {
        let server = try await LeaseCountingServer.start()
        defer { server.stop() }
        let store = VoiceConfigStore(
            fetcher: FixedFetcher(config: Self.directConfig), profile: "p",
            now: { .zero })
        let transcriber = RestTranscriber(
            rest: server.rest, profile: "p", voiceConfig: store, sttLease: "mercury:voice-input:t")

        await transcriber.prepare()
        try? await Task.sleep(for: .milliseconds(150))
        #expect(!server.sawLeaseRequest)
    }

    @Test func relaySTTAcquiresTheLease() async throws {
        let server = try await LeaseCountingServer.start()
        defer { server.stop() }
        let store = VoiceConfigStore(
            fetcher: FixedFetcher(config: VoiceClientConfig(stt: nil, tts: nil)), profile: "p",
            now: { .zero })
        let transcriber = RestTranscriber(
            rest: server.rest, profile: "p", voiceConfig: store, sttLease: "mercury:voice-input:t")

        await transcriber.prepare()
        #expect(await eventually { server.sawLeaseRequest })
    }

    @Test func noLeaseNameMeansNoWarmUp() async throws {
        let server = try await LeaseCountingServer.start()
        defer { server.stop() }
        let transcriber = RestTranscriber(rest: server.rest, profile: "p", voiceConfig: nil)

        await transcriber.prepare()
        try? await Task.sleep(for: .milliseconds(150))
        #expect(!server.sawLeaseRequest)
    }

    private static let directConfig = VoiceClientConfig(
        stt: DirectSTTConfig(json: [
            "mode": "direct", "wire": "openai-multipart", "provider": "openai",
            "base_url": "https://api.example.com/v1", "api_key": "sk-test",
        ]),
        tts: nil)
}

private final class GatedAcquire: @unchecked Sendable {
    private let lock = NSLock()
    private var _calls = 0
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    var calls: Int { lock.withLock { _calls } }

    func run() async {
        await withCheckedContinuation { continuation in
            let resumeNow = lock.withLock {
                _calls += 1
                if isOpen { return true }
                waiters.append(continuation)
                return false
            }
            if resumeNow { continuation.resume() }
        }
    }

    func open() {
        let pending = lock.withLock {
            isOpen = true
            defer { waiters = [] }
            return waiters
        }
        pending.forEach { $0.resume() }
    }
}

private struct FixedFetcher: VoiceConfigFetching {
    let config: VoiceClientConfig
    func voiceConfig(profile: String?) async throws -> VoiceClientConfig { config }
}

/// Answers everything 200 `{}`. Voice config is faked in these tests, so the
/// lease acquire is the only request that can reach it.
private final class LeaseCountingServer: @unchecked Sendable {
    private let server: ScriptedHTTPServer
    let rest: HermesRESTClient

    var sawLeaseRequest: Bool { server.requestReceived }

    private init(_ server: ScriptedHTTPServer) {
        self.server = server
        self.rest = HermesRESTClient(
            endpoint: ServerEndpoint(baseURL: URL(string: "http://127.0.0.1:\(server.port)")!),
            token: "t")
    }

    static func start() async throws -> LeaseCountingServer {
        LeaseCountingServer(try await ScriptedHTTPServer.start(status: 200, body: Data("{}".utf8)))
    }

    func stop() { server.stop() }
}
