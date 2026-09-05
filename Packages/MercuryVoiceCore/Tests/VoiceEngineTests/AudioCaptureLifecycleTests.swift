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
    /// Fail the next build, once, as a dead route would. Checked *after* the
    /// hook, so a hook can fail the very build it is running inside.
    func failNextBuild(_ error: Error) { locked { _failure = error } }

    var make: CaptureEngineFactory {
        { [self] _ in
            let hook = locked { () -> (@Sendable () -> Void)? in
                defer { _duringBuild = nil }
                return _duringBuild
            }
            hook?()
            if let failure = locked({ defer { _failure = nil }; return _failure }) { throw failure }
            let engine = FakeCaptureEngine()
            locked { _built.append(engine) }
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

    // MARK: R11 — a build's failure is news about its own generation only

    @Test func anObsoleteBuildFailureReconcilesInsteadOfGivingUp() throws {
        let factory = GatedEngineFactory()
        let service = AudioCaptureService(makeEngine: factory.make)
        let (id, _) = try service.openStream()

        // The route moves again while the rebuild's engine is starting, and
        // then that start fails. The failure describes a route that has
        // already been abandoned, so the rebuild that superseded it still has
        // to happen.
        factory.onNextBuild {
            service.reconfigure()
            factory.failNextBuild(MercuryAudioError.noInputDevice)
        }
        service.reconfigure()

        try #require(factory.buildCount == 2)
        #expect(factory.built[1].isRunning == true)

        service.closeStream(id)
        #expect(factory.built[1].isRunning == false)
    }

    @Test func anObsoleteBuildFailureDoesNotEndNewerConsumers() throws {
        let factory = GatedEngineFactory()
        let service = AudioCaptureService(makeEngine: factory.make)
        let (first, _) = try service.openStream()
        let second = Box<UUID?>(nil)

        // A consumer that attaches *after* the invalidation belongs to the new
        // generation; the doomed build's failure is not about it.
        factory.onNextBuild {
            service.reconfigure()
            second.set(try? service.openStream().id)
            factory.failNextBuild(MercuryAudioError.noInputDevice)
        }
        service.reconfigure()

        try #require(factory.buildCount == 2)
        let published = factory.built[1]
        #expect(published.isRunning == true)

        // Both are still attached: only closing the last one stops the engine.
        service.closeStream(first)
        #expect(published.isRunning == true)
        service.closeStream(try #require(second.current))
        #expect(published.isRunning == false)
    }

    @Test func theBuildClaimSurvivesAnObsoleteFailureSoTheRetryStaysSingleOwner() throws {
        let factory = GatedEngineFactory()
        let service = AudioCaptureService(makeEngine: factory.make)
        let (first, _) = try service.openStream()
        let second = Box<UUID?>(nil)

        factory.onNextBuild {
            service.reconfigure()
            factory.failNextBuild(MercuryAudioError.noInputDevice)
            // A consumer arriving inside the *retry* has to adopt it, which
            // only holds while the loop still owns the build claim across the
            // obsolete failure.
            factory.onNextBuild {
                second.set(try? service.openStream().id)
            }
        }
        service.reconfigure()

        // The first engine and the retry's -- no third started alongside it.
        try #require(factory.buildCount == 2)
        #expect(factory.built[1].isRunning == true)

        service.closeStream(first)
        #expect(factory.built[1].isRunning == true)
        service.closeStream(try #require(second.current))
        #expect(factory.built[1].isRunning == false)
    }

    @Test func closingEveryConsumerDuringAnObsoleteFailingBuildStopsWithoutRebuilding() throws {
        let factory = GatedEngineFactory()
        let service = AudioCaptureService(makeEngine: factory.make)
        let (id, _) = try service.openStream()

        factory.onNextBuild {
            service.reconfigure()
            service.closeStream(id)
            factory.failNextBuild(MercuryAudioError.noInputDevice)
        }
        service.reconfigure()

        // Reconciling an obsolete failure must not mean retrying forever.
        #expect(factory.buildCount == 1)
        #expect(factory.built[0].isRunning == false)

        // ...and the build claim was still released.
        let (again, _) = try service.openStream()
        #expect(factory.buildCount == 2)
        service.closeStream(again)
    }

    @Test func anObsoleteFailureInsideACallersOwnBuildDoesNotSurfaceToThatCaller() throws {
        let factory = GatedEngineFactory()
        let service = AudioCaptureService(makeEngine: factory.make)

        // openStream's own build is superseded while it runs and then fails.
        // The retry succeeds, so the caller gets a working stream rather than
        // an error about a route that had already been abandoned.
        factory.onNextBuild {
            service.reconfigure()
            factory.failNextBuild(MercuryAudioError.noInputDevice)
        }
        let (id, _) = try service.openStream()

        try #require(factory.buildCount == 1)
        #expect(factory.built[0].isRunning == true)

        // The stream really is the published engine's: closing it stops that
        // engine, which only holds if the caller is its attached consumer.
        service.closeStream(id)
        #expect(factory.built[0].isRunning == false)
    }

    @Test func aCurrentGenerationFailureFinishesEvenAConsumerThatJoinedTheBuild() async throws {
        let factory = GatedEngineFactory()
        let service = AudioCaptureService(makeEngine: factory.make)
        let joiner = Box<AsyncStream<AudioChunk>?>(nil)

        // Nothing invalidates this build, so its failure really is the current
        // generation's news and ends every turn attached to it.
        factory.onNextBuild {
            joiner.set(try? service.openStream().stream)
            factory.failNextBuild(MercuryAudioError.noInputDevice)
        }
        #expect(throws: MercuryAudioError.self) { try service.openStream() }
        #expect(factory.buildCount == 0)

        // Bounded rather than a bare drain: a stream left attached has to fail
        // this test, not hang it.
        let stream = try #require(joiner.current)
        let finished = Box<Bool>(false)
        let pump = Task {
            for await _ in stream {}
            finished.set(true)
        }
        #expect(await eventually { finished.current })
        pump.cancel()

        let (id, _) = try service.openStream()
        #expect(factory.buildCount == 1)
        service.closeStream(id)
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
