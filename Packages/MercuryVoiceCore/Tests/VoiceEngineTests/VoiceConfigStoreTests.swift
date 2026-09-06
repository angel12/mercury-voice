import Foundation
import Testing

@testable import HermesKit
@testable import VoiceEngine

// MARK: - Support

private let sampleConfig = VoiceClientConfig(
    json: try! JSONDecoder().decode(
        JSONValue.self,
        from: Data(
            """
            {"stt": {"mode": "direct", "wire": "openai-multipart",
                      "base_url": "https://api.example.com/v1", "api_key": "k"},
             "tts": {"mode": "direct", "wire": "openai-speech",
                      "base_url": "https://api.example.com/v1", "api_key": "k"}}
            """.utf8)))

private let http404 = HermesError.httpError(status: 404, detail: "Not Found")
private let http500 = HermesError.httpError(status: 500, detail: "boom")

private final class ManualTime: @unchecked Sendable {
    private let lock = NSLock()
    private var _now: Duration = .zero

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    var now: Duration { locked { _now } }
    func advance(_ duration: Duration) { locked { _now += duration } }
}

private final class ScriptedFetcher: VoiceConfigFetching, @unchecked Sendable {
    private let lock = NSLock()
    private var results: [Result<VoiceClientConfig, Error>]
    private var _calls = 0

    init(_ results: Result<VoiceClientConfig, Error>...) {
        self.results = results
    }

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    var calls: Int { locked { _calls } }

    func voiceConfig(profile: String?) async throws -> VoiceClientConfig {
        let result: Result<VoiceClientConfig, Error> = locked {
            _calls += 1
            return results.removeFirst()
        }
        return try result.get()
    }
}

/// Parks each lookup so Stop/invalidate can land while HTTP is still in flight.
private final class GatedFetcher: VoiceConfigFetching, @unchecked Sendable {
    private let lock = NSLock()
    private var _calls = 0
    private var _waiting = false
    private var waiter: CheckedContinuation<Result<VoiceClientConfig, Error>, Never>?

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    var calls: Int { locked { _calls } }
    var isWaiting: Bool { locked { _waiting } }

    func voiceConfig(profile: String?) async throws -> VoiceClientConfig {
        let result: Result<VoiceClientConfig, Error> = await withCheckedContinuation { cont in
            lock.lock()
            _calls += 1
            _waiting = true
            waiter = cont
            lock.unlock()
        }
        return try result.get()
    }

    func release(_ result: Result<VoiceClientConfig, Error>) {
        lock.lock()
        _waiting = false
        let waiter = waiter
        self.waiter = nil
        lock.unlock()
        waiter?.resume(returning: result)
    }
}

private func store(
    _ fetcher: any VoiceConfigFetching, time: ManualTime = ManualTime()
) -> VoiceConfigStore {
    VoiceConfigStore(fetcher: fetcher, profile: "p", now: { time.now })
}

// MARK: - Issue #73

@Suite("Voice config negative cache")
struct VoiceConfigStoreTests {

    @Test func repeatedUnsupportedLookupsHitTheNetworkOnce() async {
        let fetcher = ScriptedFetcher(.failure(http404), .failure(http404))
        let store = store(fetcher)
        #expect(await store.stt() == nil)
        #expect(await store.tts() == nil)
        #expect(fetcher.calls == 1)
    }

    @Test func unsupportedCacheExpiresOnTheTtl() async {
        let time = ManualTime()
        let fetcher = ScriptedFetcher(.failure(http404), .failure(http404))
        let store = store(fetcher, time: time)
        #expect(await store.stt() == nil)
        time.advance(.seconds(60))
        #expect(await store.stt() == nil)
        #expect(fetcher.calls == 2)
    }

    @Test func unauthorizedIsNotCached() async {
        let fetcher = ScriptedFetcher(
            .failure(HermesError.unauthorized), .failure(HermesError.unauthorized))
        let store = store(fetcher)
        #expect(await store.stt() == nil)
        #expect(await store.stt() == nil)
        #expect(fetcher.calls == 2)
    }

    @Test func transportFailureIsNotCached() async {
        let fetcher = ScriptedFetcher(
            .failure(URLError(.notConnectedToInternet)),
            .failure(URLError(.notConnectedToInternet)))
        let store = store(fetcher)
        #expect(await store.stt() == nil)
        #expect(await store.stt() == nil)
        #expect(fetcher.calls == 2)
    }

    @Test func otherHTTPFailuresAreNotCached() async {
        let fetcher = ScriptedFetcher(.failure(http500), .failure(http500))
        let store = store(fetcher)
        #expect(await store.stt() == nil)
        #expect(await store.stt() == nil)
        #expect(fetcher.calls == 2)
    }

    @Test func successfulConfigIsStillCached() async {
        let fetcher = ScriptedFetcher(.success(sampleConfig), .success(sampleConfig))
        let store = store(fetcher)
        #expect(await store.stt() != nil)
        #expect(await store.tts() != nil)
        #expect(fetcher.calls == 1)
    }

    @Test func invalidateDropsTheUnsupportedCache() async {
        let fetcher = ScriptedFetcher(.failure(http404), .failure(http404))
        let store = store(fetcher)
        #expect(await store.stt() == nil)
        await store.invalidate()
        #expect(await store.stt() == nil)
        #expect(fetcher.calls == 2)
    }

    @Test func inFlightUnsupportedAfterInvalidateDoesNotPopulateTheCache() async {
        let fetcher = GatedFetcher()
        let store = store(fetcher)

        let first = Task { await store.stt() }
        #expect(await eventually { fetcher.isWaiting })
        #expect(fetcher.calls == 1)

        await store.invalidate()
        fetcher.release(.failure(http404))
        #expect(await eventually { fetcher.isWaiting && fetcher.calls == 2 })

        fetcher.release(.success(sampleConfig))
        #expect(await first.value != nil)
        #expect(fetcher.calls == 2)

        #expect(await store.stt() != nil)
        #expect(fetcher.calls == 2)
    }
}
