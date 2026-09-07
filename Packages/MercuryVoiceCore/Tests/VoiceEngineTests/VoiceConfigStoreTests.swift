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

/// Parks each lookup so Stop/invalidate can land while HTTP is still in
/// flight. A FIFO of waiters lets F0 complete while F1 stays parked.
private final class GatedFetcher: VoiceConfigFetching, @unchecked Sendable {
    private let lock = NSLock()
    private var _calls = 0
    private var _resumed = 0
    private var waiters: [CheckedContinuation<Result<VoiceClientConfig, Error>, Never>] = []

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    var calls: Int { locked { _calls } }
    /// Currently suspended `voiceConfig` calls. Drops when a waiter is resumed,
    /// before that call returns to the store.
    var parked: Int { locked { waiters.count } }
    /// Parked calls that have returned to the store's fetch Task.
    var resumed: Int { locked { _resumed } }
    var isWaiting: Bool { parked > 0 }

    func voiceConfig(profile: String?) async throws -> VoiceClientConfig {
        let result: Result<VoiceClientConfig, Error> = await withCheckedContinuation { cont in
            lock.lock()
            _calls += 1
            waiters.append(cont)
            lock.unlock()
        }
        locked { _resumed += 1 }
        return try result.get()
    }

    func release(_ result: Result<VoiceClientConfig, Error>) {
        releaseOldest(result)
    }

    /// Resume the oldest parked lookup. F1 stays parked when F0 is released.
    func releaseOldest(_ result: Result<VoiceClientConfig, Error>) {
        lock.lock()
        precondition(!waiters.isEmpty, "no parked lookup to release")
        let waiter = waiters.removeFirst()
        lock.unlock()
        waiter.resume(returning: result)
    }
}

/// Stale F0 result vs replacement F1. The shared cleanup path must not let
/// any of these populate the cache or clear F1.
enum OverlapFixture: String, Sendable, CustomTestStringConvertible {
    case staleSuccess
    case staleUnsupported
    case staleTransient

    var testDescription: String { rawValue }

    var stale: Result<VoiceClientConfig, Error> {
        switch self {
        case .staleSuccess: .success(sampleConfig)
        case .staleUnsupported: .failure(http404)
        case .staleTransient: .failure(http500)
        }
    }

    var replacement: Result<VoiceClientConfig, Error> {
        switch self {
        case .staleSuccess: .failure(http404)
        case .staleUnsupported, .staleTransient: .success(sampleConfig)
        }
    }

    var expectConfig: Bool {
        switch self {
        case .staleSuccess: false
        case .staleUnsupported, .staleTransient: true
        }
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

    /// Park F0, invalidate, confirm F1 is in flight, then release F0 while
    /// F1 stays parked. Unconditional `inflight = nil` on F0's cleanup
    /// starts a third request; generation-guarded cleanup does not.
    @Test(arguments: [
        OverlapFixture.staleSuccess,
        OverlapFixture.staleUnsupported,
        OverlapFixture.staleTransient,
    ])
    func staleCompletionDoesNotClearNewerInflight(_ fixture: OverlapFixture) async {
        let fetcher = GatedFetcher()
        let store = store(fetcher)

        let oldWaiter = Task { await store.stt() }
        #expect(await eventually { fetcher.parked == 1 && fetcher.calls == 1 })

        await store.invalidate()

        let newWaiter = Task { await store.stt() }
        #expect(await eventually { fetcher.parked == 2 && fetcher.calls == 2 })

        fetcher.releaseOldest(fixture.stale)
        #expect(await eventually { fetcher.resumed == 1 && fetcher.parked >= 1 })
        #expect(fetcher.parked == 1, "F1 must stay parked while F0 completes")

        // F0 retries on the actor after returning. A cleared inflight starts
        // F2 (calls == 3, parked == 2); a live F1 is joined. Require the
        // (calls, parked) pair to hold across yields so the actor retry is
        // inside the snapshot, not just F0's fetcher return.
        let coalesced = Task { await store.stt() }
        let settled = await eventually {
            let snapshot = (fetcher.calls, fetcher.parked)
            await Task.yield()
            await Task.yield()
            return (fetcher.calls, fetcher.parked) == snapshot && fetcher.resumed >= 1
        }
        #expect(settled)
        #expect(fetcher.calls == 2)
        #expect(fetcher.parked == 1)

        // Drain every parked fetch so a missing generation guard fails
        // `calls == 2` instead of hanging waiters on F2.
        while fetcher.parked > 0 {
            fetcher.releaseOldest(fixture.replacement)
        }
        for _ in 0..<8 where fetcher.parked > 0 {
            fetcher.releaseOldest(fixture.replacement)
            await Task.yield()
        }

        let oldValue = await oldWaiter.value
        let newValue = await newWaiter.value
        let coalescedValue = await coalesced.value
        #expect((oldValue != nil) == fixture.expectConfig)
        #expect((newValue != nil) == fixture.expectConfig)
        #expect((coalescedValue != nil) == fixture.expectConfig)
        #expect(fetcher.calls == 2)

        #expect((await store.stt() != nil) == fixture.expectConfig)
        #expect(fetcher.calls == 2)
    }
}
