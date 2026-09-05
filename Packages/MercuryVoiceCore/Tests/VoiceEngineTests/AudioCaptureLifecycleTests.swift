import AVFoundation
import Foundation
import Testing

@testable import VoiceEngine

/// Stands in for the `AVAudioEngine` the capture service builds. Starts
/// "running" because the real factory only returns an engine it has already
/// started — so a built-but-discarded engine is a live microphone until
/// something stops it.
private final class FakeCaptureEngine: CaptureEngine, @unchecked Sendable {
    private let lock = NSLock()
    private var _isRunning = true
    private var _stopCount = 0

    var isRunning: Bool { lock.lock(); defer { lock.unlock() }; return _isRunning }
    var stopCount: Int { lock.lock(); defer { lock.unlock() }; return _stopCount }

    func stopCapture() {
        lock.lock()
        _isRunning = false
        _stopCount += 1
        lock.unlock()
    }

    /// An interruption stops audio I/O without telling anyone (issue #31).
    func stopSilently() {
        lock.lock()
        _isRunning = false
        lock.unlock()
    }
}

/// Engine factory with a gate: `onNextBuild` runs at the moment the service is
/// between "the engine is started" and "the engine is published", which is the
/// window the publication race lives in. Everything happens on the calling
/// thread, so the interleaving is exact rather than merely likely.
private final class GatedEngineFactory: @unchecked Sendable {
    private let lock = NSLock()
    private var _built: [FakeCaptureEngine] = []
    private var _duringBuild: (@Sendable () -> Void)?
    private var _failure: Error?

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    var built: [FakeCaptureEngine] { locked { _built } }
    var buildCount: Int { locked { _built.count } }

    /// Run `body` inside the next build, once.
    func onNextBuild(_ body: @escaping @Sendable () -> Void) { locked { _duringBuild = body } }
    /// Fail the next build, once, as a dead route would.
    func failNextBuild(_ error: Error) { locked { _failure = error } }

    var make: CaptureEngineFactory {
        { [self] _ in
            if let failure = locked({ defer { _failure = nil }; return _failure }) { throw failure }
            let engine = FakeCaptureEngine()
            locked { _built.append(engine) }
            let hook = locked { () -> (@Sendable () -> Void)? in
                defer { _duringBuild = nil }
                return _duringBuild
            }
            hook?()
            return engine
        }
    }
}

@Suite("Audio capture engine lifecycle")
struct AudioCaptureLifecycleTests {
    // MARK: R11 — publication must be validated against the state it was started for

    @Test func aBuildFinishingAfterTheLastConsumerLeavesIsNotPublished() throws {
        let factory = GatedEngineFactory()
        let service = AudioCaptureService(makeEngine: factory.make)
        let (id, _) = try service.openStream()
        #expect(factory.buildCount == 1)

        // The last consumer goes away while the replacement engine is already
        // started but not yet published: `closeStream` sees no published
        // engine and stops nothing, so only the publication check can catch it.
        factory.onNextBuild { service.closeStream(id) }
        service.reconfigure()

        #expect(factory.buildCount == 2)
        #expect(factory.built[0].isRunning == false)
        let replacement = try #require(factory.built.last)
        #expect(replacement.isRunning == false)

        // Nothing stale was left published either: the next consumer has to
        // build its own engine rather than adopt one nobody can stop.
        let (later, _) = try service.openStream()
        #expect(factory.buildCount == 3)
        service.closeStream(later)
    }

    @Test func aRebuildRequestedDuringABuildSupersedesIt() throws {
        let factory = GatedEngineFactory()
        let service = AudioCaptureService(makeEngine: factory.make)
        let (id, _) = try service.openStream()

        // The route moves again while the first rebuild's engine is starting.
        // The engine in flight was built on the route that just changed, so it
        // must be discarded rather than published.
        factory.onNextBuild { service.reconfigure() }
        service.reconfigure()

        try #require(factory.buildCount == 3)
        #expect(factory.built[1].isRunning == false)
        #expect(factory.built[2].isRunning == true)

        // The survivor really is the published one: a new consumer joins it
        // instead of starting a fourth engine.
        let (second, _) = try service.openStream()
        #expect(factory.buildCount == 3)

        service.closeStream(id)
        service.closeStream(second)
        #expect(factory.built[2].isRunning == false)
    }

    @Test func aConsumerArrivingDuringABuildAdoptsItInsteadOfStartingASecondEngine() throws {
        let factory = GatedEngineFactory()
        let service = AudioCaptureService(makeEngine: factory.make)
        let second = Box<UUID?>(nil)

        factory.onNextBuild { second.set(try? service.openStream().id) }
        let (first, _) = try service.openStream()

        // One microphone, not two racing for it.
        #expect(factory.buildCount == 1)
        #expect(factory.built[0].isRunning == true)

        service.closeStream(first)
        #expect(factory.built[0].isRunning == true)
        service.closeStream(try #require(second.current))
        #expect(factory.built[0].isRunning == false)
    }

    // MARK: Preserved lifecycle behaviour

    @Test func theEngineRunsOnlyWhileConsumersExist() throws {
        let factory = GatedEngineFactory()
        let service = AudioCaptureService(makeEngine: factory.make)

        service.reconfigure()
        #expect(factory.buildCount == 0)

        let (id, _) = try service.openStream()
        #expect(factory.buildCount == 1)
        #expect(factory.built[0].isRunning == true)

        service.closeStream(id)
        #expect(factory.built[0].isRunning == false)
        #expect(factory.built[0].stopCount == 1)

        let (again, _) = try service.openStream()
        #expect(factory.buildCount == 2)
        service.closeStream(again)
    }

    @Test func aFailedBuildFinishesConsumersAndLeavesTheServiceStartable() async throws {
        let factory = GatedEngineFactory()
        let service = AudioCaptureService(makeEngine: factory.make)
        factory.failNextBuild(MercuryAudioError.noInputDevice)

        #expect(throws: MercuryAudioError.self) { try service.openStream() }
        #expect(factory.buildCount == 0)

        // A failed start must not wedge the service: the next consumer builds.
        let (id, stream) = try service.openStream()
        #expect(factory.buildCount == 1)
        #expect(factory.built[0].isRunning == true)

        service.closeStream(id)
        var delivered = 0
        for await _ in stream { delivered += 1 }
        #expect(delivered == 0)
    }

    @Test func ensureRunningRebuildsAnEngineThatDiedSilently() throws {
        let factory = GatedEngineFactory()
        let service = AudioCaptureService(makeEngine: factory.make)
        let (id, _) = try service.openStream()

        service.ensureRunning()
        #expect(factory.buildCount == 1)

        factory.built[0].stopSilently()
        service.ensureRunning()
        #expect(factory.buildCount == 2)
        #expect(factory.built[1].isRunning == true)

        service.closeStream(id)
        #expect(factory.built[1].isRunning == false)
    }
}

/// Test-owned mutable state reachable from the factory's `@Sendable` hook.
private final class Box<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value

    init(_ value: Value) { self.value = value }

    var current: Value { lock.lock(); defer { lock.unlock() }; return value }
    func set(_ newValue: Value) { lock.lock(); value = newValue; lock.unlock() }
}
