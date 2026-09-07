import Foundation
import Testing

@testable import VoiceEngine

// MARK: - Gate

/// Gates the `isPlaying` probe the monitor awaits in the middle of every
/// chunk. That await is the only suspension point inside the pump's loop
/// body, so holding it parks a run in exactly the window where Stop, a
/// restart and mute land — after the loop-top cancellation and suspension
/// checks have already passed (issue #66).
private final class PlayingGate: @unchecked Sendable {
    private let lock = NSLock()
    private var _entered = 0
    private var _parked = 0
    private var _resumed = 0
    private var holding = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    /// One per chunk the run has actually reached the probe for — the test's
    /// lock-step signal that the pump consumed what was emitted.
    var entered: Int { locked { _entered } }
    /// Probes currently suspended inside the gate.
    var parked: Int { locked { _parked } }
    /// Probes that went into the gate and have since returned to their
    /// caller. This says the gated continuation resumed — not that the
    /// monitor has finished the post-hop work that follows it.
    var resumed: Int { locked { _resumed } }

    /// Park every probe from here on instead of answering it.
    func hold() { locked { holding = true } }

    /// Release the parked probes and stop holding.
    func open() {
        let pending: [CheckedContinuation<Void, Never>] = locked {
            holding = false
            let pending = waiters
            waiters.removeAll()
            _parked -= pending.count
            return pending
        }
        for waiter in pending { waiter.resume() }
    }

    /// The `isPlaying` closure handed to `start`. Always answers "not
    /// playing": the monitor runs while the agent is thinking too, and the
    /// quiet-floor path is the one with a deterministic trip sequence.
    func probe() async -> Bool {
        let park: Bool = locked {
            _entered += 1
            return holding
        }
        guard park else { return false }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let immediate: CheckedContinuation<Void, Never>? = locked {
                guard holding else { return continuation }
                _parked += 1
                waiters.append(continuation)
                return nil
            }
            immediate?.resume()
        }
        locked { _resumed += 1 }
        return false
    }
}

// MARK: - Callback recorder

private final class BargeCallbacks: @unchecked Sendable {
    private let lock = NSLock()
    private var _speechCount = 0
    private var _utterances: [RecordedUtterance?] = []

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    var speechCount: Int { locked { _speechCount } }
    var utterances: [RecordedUtterance?] { locked { _utterances } }

    func speech() { locked { _speechCount += 1 } }
    func utterance(_ value: RecordedUtterance?) { locked { _utterances.append(value) } }
}

// MARK: - Chunk timeline

/// Virtual time in the monitor comes from sample counts, not the wall clock:
/// at 16 kHz a 2000-sample chunk is one 125 ms hop.
///
/// The hop is 1/8 s on purpose. `BargeDetector` measures its 300 ms sustained
/// window with `Duration.seconds(Double(elapsedSamples) / sampleRate)`, and
/// that conversion rounds: with a 100 ms hop the difference between two
/// instants three hops apart can land a few attoseconds *over* 300 ms, which
/// prunes the window's oldest entry and silently un-fills it. Hop times that
/// are exact binary fractions make the timeline below deterministic.
private let testRate: Double = 16000
private let hopSamples = 2000
private let hopSeconds = Double(hopSamples) / testRate

private func quietChunk(samples: Int = hopSamples) -> AudioChunk {
    AudioChunk(samples: [Float](repeating: 0, count: samples), sampleRate: testRate)
}

/// 0.5 full-scale normalizes to level 1.0, far above the 0.075 trigger.
private func loudChunk() -> AudioChunk {
    AudioChunk(samples: [Float](repeating: 0.5, count: hopSamples), sampleRate: testRate)
}

/// A single quiet hop long enough that the *next* hop endpoints the capture,
/// rounded up to a whole number of hops so the timeline stays exact.
private func endOfTurnGapChunk(
    silence: Duration = VoiceConstants.endOfTurnSilence
) -> AudioChunk {
    let hops = ((silence.asSeconds + hopSeconds) / hopSeconds).rounded(.up)
    return quietChunk(samples: Int(hops) * hopSamples)
}

/// Emit one chunk and wait until the run has reached the probe for it, so the
/// test stays in lock-step with the pump instead of racing its buffer.
@discardableResult
private func feed(
    _ chunk: AudioChunk, _ capture: FakeAudioCapture, _ gate: PlayingGate
) async -> Bool {
    let target = gate.entered + 1
    capture.emit(chunk)
    return await eventually { gate.entered >= target }
}

/// Five quiet hops lock the noise floor (400 ms of calibration completes on
/// the hop at 500 ms) and two loud hops start filling the 300 ms sustained
/// window; the *third* loud hop is the one that trips, and is left to the
/// caller so it can be gated.
private func feedUpToTheTrippingHop(_ capture: FakeAudioCapture, _ gate: PlayingGate) async -> Bool
{
    for _ in 0..<5 {
        guard await feed(quietChunk(), capture, gate) else { return false }
    }
    for _ in 0..<2 {
        guard await feed(loudChunk(), capture, gate) else { return false }
    }
    return true
}

// MARK: - Scope

/// Owns the gates and monitors a test creates, and tears them down however
/// the body exits: every gate is opened so no probe is left parked, then
/// every monitor is stopped so no pump outlives the test.
private final class MonitorScope: @unchecked Sendable {
    private let lock = NSLock()
    private var gates: [PlayingGate] = []
    private var monitors: [BargeInMonitor] = []

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    func gate() -> PlayingGate {
        let gate = PlayingGate()
        locked { gates.append(gate) }
        return gate
    }

    func monitor(
        capture: any AudioCaptureStreaming,
        detachCaptureOnSuspend: Bool,
        utteranceSilence: Duration = VoiceConstants.endOfTurnSilence
    ) -> BargeInMonitor {
        let monitor = BargeInMonitor(
            capture: capture,
            detachCaptureOnSuspend: detachCaptureOnSuspend,
            utteranceSilence: utteranceSilence)
        locked { monitors.append(monitor) }
        return monitor
    }

    func teardown() async {
        let (gates, monitors) = locked { (self.gates, self.monitors) }
        for gate in gates { gate.open() }
        for monitor in monitors { await monitor.stop() }
    }
}

/// Runs `body` in a scope and tears it down whether the body returns or
/// throws, so an early exit cannot strand a parked probe or leave a pump
/// running past the test.
private func withMonitorScope(_ body: (MonitorScope) async throws -> Void) async rethrows {
    let scope = MonitorScope()
    do {
        try await body(scope)
    } catch {
        await scope.teardown()
        throw error
    }
    await scope.teardown()
}

// MARK: - Tests

@Suite("BargeInMonitor stale runs")
struct BargeInMonitorStaleRunTests {

    /// Preservation, and the proof that the timeline above really drives the
    /// detector: an ungated run trips, endpoints, releases the capture and
    /// delivers the utterance.
    @Test func anUngatedRunTripsEndpointsAndDelivers() async throws {
        try await withMonitorScope { scope in
            let capture = FakeAudioCapture()
            let gate = scope.gate()
            let calls = BargeCallbacks()
            let monitor = scope.monitor(capture: capture, detachCaptureOnSuspend: false)
            try await monitor.start(
                isPlaying: { await gate.probe() },
                onSpeech: { calls.speech() },
                onUtterance: { calls.utterance($0) })

            #expect(await feedUpToTheTrippingHop(capture, gate))
            #expect(await feed(loudChunk(), capture, gate))
            #expect(await eventually { calls.speechCount == 1 })

            #expect(await feed(endOfTurnGapChunk(), capture, gate))
            #expect(await feed(quietChunk(), capture, gate))

            #expect(await eventually { calls.utterances.count == 1 })
            let utterance = try #require(calls.utterances.first ?? nil)
            #expect(utterance.heardSpeech)
            #expect(!utterance.audio.isEmpty)
            #expect(await eventually { capture.activeCount == 0 })
            #expect(capture.closeCount == 1)
        }
    }

    /// Stop lands while the run is parked in the `isPlaying` hop, on the very
    /// chunk that would trip. The run is obsolete when it resumes and must
    /// announce nothing.
    @Test func stopDuringTheHopCannotAnnounceSpeech() async throws {
        try await withMonitorScope { scope in
            let capture = FakeAudioCapture()
            let gate = scope.gate()
            let calls = BargeCallbacks()
            let monitor = scope.monitor(capture: capture, detachCaptureOnSuspend: false)
            try await monitor.start(
                isPlaying: { await gate.probe() },
                onSpeech: { calls.speech() },
                onUtterance: { calls.utterance($0) })

            #expect(await feedUpToTheTrippingHop(capture, gate))
            gate.hold()
            capture.emit(loudChunk())
            #expect(await eventually { gate.parked == 1 })

            await monitor.stop()
            #expect(capture.activeCount == 0)
            gate.open()
            #expect(await eventually { gate.resumed == 1 })

            #expect(!(await eventually(timeout: 0.3) { calls.speechCount > 0 }))
            #expect(calls.utterances.isEmpty)
            #expect(capture.closeCount == 1)
        }
    }

    /// Mute lands in the hop under the macOS policy, where the stream stays
    /// attached. Audio heard while muted must not trip — and the monitor must
    /// still work after the mute is lifted.
    @Test func muteDuringTheHopDiscardsWhatWasHeardAndRecovers() async throws {
        try await withMonitorScope { scope in
            let capture = FakeAudioCapture()
            let gate = scope.gate()
            let calls = BargeCallbacks()
            let monitor = scope.monitor(capture: capture, detachCaptureOnSuspend: false)
            try await monitor.start(
                isPlaying: { await gate.probe() },
                onSpeech: { calls.speech() },
                onUtterance: { calls.utterance($0) })

            #expect(await feedUpToTheTrippingHop(capture, gate))
            gate.hold()
            capture.emit(loudChunk())
            #expect(await eventually { gate.parked == 1 })

            await monitor.setSuspended(true)
            gate.open()

            // The window before the mute is lifted is load-bearing, not
            // padding: it lets the resumed run observe `suspended` before the
            // test clears it. Unmuting straight after `open()` races it.
            #expect(!(await eventually(timeout: 0.3) { calls.speechCount > 0 }))
            #expect(calls.speechCount == 0)
            // macOS keeps the voice-processing input attached while muted.
            #expect(capture.activeCount == 1)
            #expect(capture.closeCount == 0)

            // Recovery: the discard reset the detector rather than wedging it,
            // so a fresh sequence after the mute is lifted still trips once.
            let beforeRecovery = calls.speechCount
            await monitor.setSuspended(false)
            #expect(await feedUpToTheTrippingHop(capture, gate))
            #expect(await feed(loudChunk(), capture, gate))
            #expect(await eventually { calls.speechCount == beforeRecovery + 1 })
        }
    }

    /// Mute lands in the hop while the run is mid-capture, so the only thing
    /// standing between the muted audio and the user is the discard: the
    /// half-built capture must go, and lifting the mute and letting the turn
    /// end must deliver nothing. Nothing else in this suite fails if the
    /// post-hop branch keeps its `continue` but drops the discard.
    @Test func muteMidCaptureDiscardsTheHalfBuiltCapture() async throws {
        try await withMonitorScope { scope in
            let capture = FakeAudioCapture()
            let gate = scope.gate()
            let calls = BargeCallbacks()
            let monitor = scope.monitor(capture: capture, detachCaptureOnSuspend: false)
            try await monitor.start(
                isPlaying: { await gate.probe() },
                onSpeech: { calls.speech() },
                onUtterance: { calls.utterance($0) })

            #expect(await feedUpToTheTrippingHop(capture, gate))
            #expect(await feed(loudChunk(), capture, gate))
            #expect(await eventually { calls.speechCount == 1 })

            // Park a `.capturing` chunk — one that appends to the capture
            // rather than trips — and mute while it is in the hop.
            gate.hold()
            capture.emit(loudChunk())
            #expect(await eventually { gate.parked == 1 })
            await monitor.setSuspended(true)
            gate.open()

            // Same ordering as above: let the resumed run see the mute before
            // it is lifted. No chunk arrives while muted, so the post-hop
            // discard is the only thing that can clear the capture.
            #expect(!(await eventually(timeout: 0.3) { calls.speechCount > 1 }))
            await monitor.setSuspended(false)

            #expect(await feed(endOfTurnGapChunk(), capture, gate))
            #expect(await feed(quietChunk(), capture, gate))
            #expect(!(await eventually(timeout: 0.3) { !calls.utterances.isEmpty }))
            #expect(capture.activeCount == 1)
        }
    }

    /// Mute lands in the hop under the iOS policy, which releases the capture
    /// consumer so the engine (and the privacy indicator) can stop. The run
    /// is obsolete on resume and must announce nothing.
    @Test func muteThatDetachesDuringTheHopCannotAnnounceSpeech() async throws {
        try await withMonitorScope { scope in
            let capture = FakeAudioCapture()
            let gate = scope.gate()
            let calls = BargeCallbacks()
            let monitor = scope.monitor(capture: capture, detachCaptureOnSuspend: true)
            try await monitor.start(
                isPlaying: { await gate.probe() },
                onSpeech: { calls.speech() },
                onUtterance: { calls.utterance($0) })

            #expect(await feedUpToTheTrippingHop(capture, gate))
            gate.hold()
            capture.emit(loudChunk())
            #expect(await eventually { gate.parked == 1 })

            await monitor.setSuspended(true)
            #expect(capture.streamClosed)
            gate.open()
            #expect(await eventually { gate.resumed == 1 })

            #expect(!(await eventually(timeout: 0.3) { calls.speechCount > 0 }))
            #expect(calls.utterances.isEmpty)
        }
    }

    /// A restart lands while the run is parked on the chunk that endpoints
    /// its capture — the one path that both delivers and tears down. The
    /// obsolete run must not deliver to the callbacks it was started with,
    /// and must not close the stream or cancel the pump that replaced it.
    @Test func aRestartDuringTheHopLeavesTheReplacementRunning() async throws {
        try await withMonitorScope { scope in
            let capture = FakeAudioCapture()
            let firstGate = scope.gate()
            let first = BargeCallbacks()
            let monitor = scope.monitor(capture: capture, detachCaptureOnSuspend: false)
            try await monitor.start(
                isPlaying: { await firstGate.probe() },
                onSpeech: { first.speech() },
                onUtterance: { first.utterance($0) })

            #expect(await feedUpToTheTrippingHop(capture, firstGate))
            #expect(await feed(loudChunk(), capture, firstGate))
            #expect(await eventually { first.speechCount == 1 })
            #expect(await feed(endOfTurnGapChunk(), capture, firstGate))

            firstGate.hold()
            capture.emit(quietChunk())
            #expect(await eventually { firstGate.parked == 1 })

            let secondGate = scope.gate()
            let second = BargeCallbacks()
            try await monitor.start(
                isPlaying: { await secondGate.probe() },
                onSpeech: { second.speech() },
                onUtterance: { second.utterance($0) })
            #expect(capture.openCount == 2)
            #expect(capture.activeCount == 1)
            #expect(capture.closeCount == 1)

            firstGate.open()
            // The obsolete run's continuation has returned before anything
            // below is judged. It does not prove the run finished its
            // post-hop work — only that it is past the gate.
            #expect(await eventually { firstGate.resumed == 1 })

            // The obsolete run delivers nothing to the callbacks it was born
            // with.
            #expect(!(await eventually(timeout: 0.3) { !first.utterances.isEmpty }))
            // …and it has not torn down the replacement.
            #expect(capture.closeCount == 1)
            #expect(capture.activeCount == 1)
            // The replacement pump is still alive: it consumes what it is fed.
            #expect(await feed(quietChunk(), capture, secondGate))
            #expect(second.speechCount == 0)
            #expect(second.utterances.isEmpty)
        }
    }
}

// MARK: - Capture flag
//
// The suite below is about `BargeInMonitor.isCapturing` — the synchronous flag
// the engine reads to answer "does a barge capture own the mic?" (issue #87).
// The engine's guards are only as good as *when* the monitor raises and drops
// it, and that ordering is invisible to the engine tests, which use a fake
// monitor. It is asserted here on the real one, on the gate, chunk timeline
// and scope above.

/// Samples `isCapturing` from *inside* the monitor's own callbacks. The
/// invariant is an ordering — up before `onSpeech`, down before `onUtterance`
/// — and a sample taken after a callback has returned cannot see it.
private final class CaptureFlagLog: @unchecked Sendable {
    private let lock = NSLock()
    private var _atSpeech: [Bool] = []
    private var _atUtterance: [Bool] = []
    private var _utterances: [RecordedUtterance?] = []

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    /// The flag as each `onSpeech` saw it, in order.
    var atSpeech: [Bool] { locked { _atSpeech } }
    /// The flag as each `onUtterance` saw it, in order.
    var atUtterance: [Bool] { locked { _atUtterance } }
    var utterances: [RecordedUtterance?] { locked { _utterances } }

    func speech(_ flag: Bool) { locked { _atSpeech.append(flag) } }

    func utterance(_ flag: Bool, _ value: RecordedUtterance?) {
        locked {
            _atUtterance.append(flag)
            _utterances.append(value)
        }
    }
}

/// A started real monitor whose callbacks sample the flag, plus the fake
/// capture and gate that drive it.
private struct FlagRig {
    let capture: FakeAudioCapture
    let gate: PlayingGate
    let log: CaptureFlagLog
    let monitor: BargeInMonitor

    init(_ scope: MonitorScope, detachCaptureOnSuspend: Bool = false) async throws {
        capture = FakeAudioCapture()
        gate = scope.gate()
        log = CaptureFlagLog()
        monitor = scope.monitor(
            capture: capture, detachCaptureOnSuspend: detachCaptureOnSuspend)
        let (monitor, log, gate) = (self.monitor, self.log, self.gate)
        try await monitor.start(
            isPlaying: { await gate.probe() },
            onSpeech: { log.speech(monitor.isCapturing) },
            onUtterance: { log.utterance(monitor.isCapturing, $0) })
    }

    /// Calibrate, then trip, returning only once `onSpeech` has fired — so the
    /// flag has settled before anything is judged.
    func trip() async -> Bool {
        guard await feedUpToTheTrippingHop(capture, gate) else { return false }
        guard await feed(loudChunk(), capture, gate) else { return false }
        return await eventually { log.atSpeech.count == 1 }
    }
}

@Suite("BargeInMonitor capture flag")
struct BargeInMonitorCaptureFlagTests {

    /// The ordering the engine's guard rests on. `onSpeech` only reaches the
    /// engine an actor hop later, so the flag has to be up *before* it fires;
    /// the capture is the engine's business from the moment it is handed over,
    /// so the flag has to be down *before* `onUtterance` fires.
    @Test func theFlagIsUpInsideOnSpeechAndDownInsideOnUtterance() async throws {
        try await withMonitorScope { scope in
            let rig = try await FlagRig(scope)
            #expect(!rig.monitor.isCapturing)

            #expect(await rig.trip())
            #expect(rig.log.atSpeech == [true])
            #expect(rig.monitor.isCapturing)

            // A `.capturing` hop leaves it up.
            #expect(await feed(loudChunk(), rig.capture, rig.gate))
            #expect(rig.monitor.isCapturing)

            #expect(await feed(endOfTurnGapChunk(), rig.capture, rig.gate))
            #expect(await feed(quietChunk(), rig.capture, rig.gate))
            #expect(await eventually { rig.log.utterances.count == 1 })
            #expect(rig.log.atUtterance == [false])
            #expect(!rig.monitor.isCapturing)

            let utterance = try #require(rig.log.utterances.first ?? nil)
            #expect(utterance.heardSpeech)
            #expect(rig.capture.activeCount == 0)
        }
    }

    /// Stop under a live capture. Nothing will ever be delivered, so `detach`
    /// clearing the flag is the only thing that stops the engine from reading
    /// a capture that no longer exists.
    @Test func stopUnderALiveCaptureClearsTheFlag() async throws {
        try await withMonitorScope { scope in
            let rig = try await FlagRig(scope)
            #expect(await rig.trip())
            #expect(rig.monitor.isCapturing)

            await rig.monitor.stop()
            #expect(!rig.monitor.isCapturing)
            #expect(!(await eventually(timeout: 0.3) { !rig.log.utterances.isEmpty }))
            #expect(rig.capture.activeCount == 0)
        }
    }

    /// Mute under the macOS policy: the stream stays attached and the pump
    /// discards what it hears, so the flag must come down on the mute itself
    /// rather than on some later chunk.
    @Test func muteUnderALiveCaptureClearsTheFlagOnTheMacOSPolicy() async throws {
        try await withMonitorScope { scope in
            let rig = try await FlagRig(scope, detachCaptureOnSuspend: false)
            #expect(await rig.trip())
            #expect(rig.monitor.isCapturing)

            await rig.monitor.setSuspended(true)
            #expect(!rig.monitor.isCapturing)
            #expect(rig.capture.activeCount == 1)

            // Audio heard while muted must not raise it again. No lock-step
            // wait on the gate here: the suspended branch `continue`s before
            // the probe, so nothing would ever enter it.
            rig.capture.emit(loudChunk())
            #expect(!(await eventually(timeout: 0.3) { rig.monitor.isCapturing }))
        }
    }

    /// Mute under the iOS policy, which detaches the capture consumer. Same
    /// invariant by a different route.
    @Test func muteUnderALiveCaptureClearsTheFlagOnTheIOSPolicy() async throws {
        try await withMonitorScope { scope in
            let rig = try await FlagRig(scope, detachCaptureOnSuspend: true)
            #expect(await rig.trip())
            #expect(rig.monitor.isCapturing)

            await rig.monitor.setSuspended(true)
            #expect(!rig.monitor.isCapturing)
            #expect(rig.capture.streamClosed)
            #expect(!(await eventually(timeout: 0.3) { !rig.log.utterances.isEmpty }))
        }
    }

    /// The stream ends under a live capture without an endpoint — an external
    /// stop, the path that delivers from the bottom of `run` instead of from
    /// `detach`. The run is over either way, so the flag has to come down with
    /// it: left up, it would outlive the pump that owns it and the engine
    /// would go on believing a dead capture holds the mic.
    @Test func anExternalStreamEndClearsTheFlagBeforeDelivering() async throws {
        try await withMonitorScope { scope in
            let rig = try await FlagRig(scope)
            #expect(await rig.trip())
            #expect(rig.monitor.isCapturing)

            rig.capture.finishUnexpectedly()
            #expect(await eventually { rig.log.utterances.count == 1 })
            #expect(rig.log.atUtterance == [false])
            #expect(!rig.monitor.isCapturing)
        }
    }

    /// A restart lands while the previous run is parked in the `isPlaying`
    /// hop, and the replacement then trips: the flag now belongs to the new
    /// run. The stale run resumes into the post-hop guard, which `return`s.
    /// It must not instead leave the loop — the stream-end cleanup at the
    /// bottom of `run` clears the flag unconditionally, and clearing it here
    /// would hand the mic back while the replacement is still capturing.
    @Test func aStaleRunResumingFromTheHopCannotClearTheReplacementsFlag() async throws {
        try await withMonitorScope { scope in
            let capture = FakeAudioCapture()
            let monitor = scope.monitor(capture: capture, detachCaptureOnSuspend: false)

            let firstGate = scope.gate()
            let first = CaptureFlagLog()
            try await monitor.start(
                isPlaying: { await firstGate.probe() },
                onSpeech: { first.speech(monitor.isCapturing) },
                onUtterance: { first.utterance(monitor.isCapturing, $0) })

            #expect(await feedUpToTheTrippingHop(capture, firstGate))
            #expect(await feed(loudChunk(), capture, firstGate))
            #expect(await eventually { first.atSpeech.count == 1 })
            #expect(monitor.isCapturing)

            // Park the outgoing run mid-capture, with the flag up.
            firstGate.hold()
            capture.emit(loudChunk())
            #expect(await eventually { firstGate.parked == 1 })

            // Re-arm. `start` stops the old run first, which drops the flag…
            let secondGate = scope.gate()
            let second = CaptureFlagLog()
            try await monitor.start(
                isPlaying: { await secondGate.probe() },
                onSpeech: { second.speech(monitor.isCapturing) },
                onUtterance: { second.utterance(monitor.isCapturing, $0) })
            #expect(!monitor.isCapturing)
            #expect(capture.openCount == 2)

            // …and the replacement raises it for a capture of its own.
            #expect(await feedUpToTheTrippingHop(capture, secondGate))
            #expect(await feed(loudChunk(), capture, secondGate))
            #expect(await eventually { second.atSpeech.count == 1 })
            #expect(monitor.isCapturing)

            firstGate.open()
            // Past the gate — as in the restart test above, that is not proof
            // the stale run finished its post-hop work, so the flag is then
            // watched for a window rather than sampled once.
            #expect(await eventually { firstGate.resumed == 1 })
            #expect(!(await eventually(timeout: 0.3) { !monitor.isCapturing }))
            #expect(first.utterances.isEmpty)
            #expect(second.atSpeech == [true])
        }
    }
}
