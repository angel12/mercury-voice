import Foundation
import Testing

@testable import VoiceEngine

// MARK: - Gate

/// Gates the `isPlaying` probe so each emitted chunk is consumed in lock-step.
/// Answers "playing" so the adaptive echo floor can classify sustained
/// louder leakage as quiet (issue #70 / #12).
private final class PlayingGate: @unchecked Sendable {
    private let lock = NSLock()
    private var _entered = 0
    private var _parked = 0
    private var holding = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    var entered: Int { locked { _entered } }

    func hold() { locked { holding = true } }

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

    func probe() async -> Bool {
        let park: Bool = locked {
            _entered += 1
            return holding
        }
        guard park else { return true }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let immediate: CheckedContinuation<Void, Never>? = locked {
                guard holding else { return continuation }
                _parked += 1
                waiters.append(continuation)
                return nil
            }
            immediate?.resume()
        }
        return true
    }
}

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
        onQuietPreRoll: (@Sendable ([Float]) -> Void)? = nil
    ) -> BargeInMonitor {
        let monitor = BargeInMonitor(
            capture: capture,
            detachCaptureOnSuspend: false,
            onQuietPreRoll: onQuietPreRoll)
        locked { monitors.append(monitor) }
        return monitor
    }

    func teardown() async {
        let (gates, monitors) = locked { (self.gates, self.monitors) }
        for gate in gates { gate.open() }
        for monitor in monitors { await monitor.stop() }
    }
}

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

// MARK: - Chunk timeline

/// 125 ms is an exact binary fraction, so the 300 ms sustained window fills
/// in three hops. 50 ms needs six hops and its own endpoint gap.
private let binaryHopSeconds = 0.125
private let fiftyMsHopSeconds = 0.050

/// Echo amplitude whose normalized RMS is 0.3 — above `bargeMinTriggerLevel`
/// (0.075) so the old loudness-gated trim refuses to rotate, but below the
/// playback echo trigger (~0.45) so the detector stays `.quiet`.
private let echoLevel = 0.3
private let echoAmplitude = Float(echoLevel * VoiceConstants.rmsNormalizationDivisor)
private let speechAmplitude: Float = 0.5

/// Echo long enough that an unbounded pre-roll is obviously past the 5.5 s
/// cap. Early audio uses +echo, recent audio uses −echo, so the next
/// interruption can be checked for contamination vs. the trailing window.
private let earlyEchoSeconds = 8.0
private let recentEchoSeconds = 6.0

/// WAV-rate composition for one hop size. Onset, endpoint gap, and the
/// capture-ended hop all use that hop — not a global 125 ms timeline.
private struct RetainedWindow {
    let hopSeconds: Double
    let tripHops: Int
    let recentEchoSamples: Int
    let speechSamples: Int
    let earlyEchoSamples: Int
    let durationSeconds: Double
    let wavSamples: Int
}

private func preRollCapSeconds() -> Double {
    (VoiceConstants.bargePreRollRestart + VoiceConstants.bargePreRollOnsetAllowance)
        .asSeconds
}

private func retainedWindow(hopSeconds: Double) -> RetainedWindow {
    let wavRate = WAVEncoder.targetSampleRate
    let capSeconds = preRollCapSeconds()
    let majoritySpan =
        VoiceConstants.bargeSustainedWindow.asSeconds * VoiceConstants.bargeSustainedMajority
    var tripHops = 1
    while Double(tripHops - 1) * hopSeconds < majoritySpan {
        tripHops += 1
        precondition(tripHops < 100, "sustained window never filled at hop \(hopSeconds)")
    }
    let onsetSeconds = Double(tripHops - 1) * hopSeconds
    let speechSeconds = Double(tripHops) * hopSeconds
    let recentEcho = capSeconds - onsetSeconds
    let gapHops = ((TurnSilencePreference.seconds + hopSeconds) / hopSeconds).rounded(.up)
    let gapSeconds = gapHops * hopSeconds
    let recentEchoSamples = sampleCount(seconds: recentEcho, rate: wavRate)
    let speechSamples = sampleCount(seconds: speechSeconds, rate: wavRate)
    let gapSamples = sampleCount(seconds: gapSeconds, rate: wavRate)
    let finalSamples = sampleCount(seconds: hopSeconds, rate: wavRate)
    let wavSamples = recentEchoSamples + speechSamples + gapSamples + finalSamples
    return RetainedWindow(
        hopSeconds: hopSeconds,
        tripHops: tripHops,
        recentEchoSamples: recentEchoSamples,
        speechSamples: speechSamples,
        earlyEchoSamples: 0,
        durationSeconds: Double(wavSamples) / wavRate,
        wavSamples: wavSamples)
}

private func sampleCount(seconds: Double, rate: Double) -> Int {
    Int((seconds * rate).rounded())
}

private func chunk(amplitude: Float, seconds: Double, rate: Double) -> AudioChunk {
    AudioChunk(
        samples: [Float](repeating: amplitude, count: sampleCount(seconds: seconds, rate: rate)),
        sampleRate: rate)
}

private func mixedOversizedChunk(rate: Double) -> AudioChunk {
    let capSamples = Int(preRollCapSeconds() * rate)
    let totalSamples = sampleCount(seconds: earlyEchoSeconds, rate: rate)
    precondition(totalSamples > capSamples)
    let prefix = [Float](repeating: echoAmplitude, count: totalSamples - capSamples)
    let tail = [Float](repeating: -echoAmplitude, count: capSamples)
    return AudioChunk(samples: prefix + tail, sampleRate: rate)
}

private func endOfTurnGapChunk(hopSeconds: Double, rate: Double) -> AudioChunk {
    let hops = ((TurnSilencePreference.seconds + hopSeconds) / hopSeconds).rounded(.up)
    return chunk(amplitude: 0, seconds: hops * hopSeconds, rate: rate)
}

@discardableResult
private func feed(
    _ chunk: AudioChunk, _ capture: FakeAudioCapture, _ gate: PlayingGate
) async -> Bool {
    let target = gate.entered + 1
    capture.emit(chunk)
    return await eventually { gate.entered >= target }
}

private func pcm16Samples(_ wav: Data) -> [Int16] {
    let payload = wav.dropFirst(44)
    return payload.withUnsafeBytes { buf in
        Array(buf.bindMemory(to: Int16.self)).map { Int16(littleEndian: $0) }
    }
}

private func matchesAmplitude(_ sample: Int16, _ amplitude: Float) -> Bool {
    let expected = Int16(amplitude * 32767)
    return abs(Int(sample) - Int(expected)) <= 2
}

private func matchesFloat(_ sample: Float, _ amplitude: Float) -> Bool {
    abs(sample - amplitude) <= 1e-5
}

private func expectExactRetainedWindow(_ utterance: RecordedUtterance, _ window: RetainedWindow) {
    #expect(utterance.heardSpeech)
    #expect(utterance.duration.asSeconds == window.durationSeconds)
    let pcm = pcm16Samples(utterance.audio)
    #expect(pcm.count == window.wavSamples)
    #expect(pcm.filter { matchesAmplitude($0, echoAmplitude) }.count == window.earlyEchoSamples)
    #expect(pcm.filter { matchesAmplitude($0, -echoAmplitude) }.count == window.recentEchoSamples)
    #expect(pcm.filter { matchesAmplitude($0, speechAmplitude) }.count == window.speechSamples)
}

private final class PreRollSnapshots: @unchecked Sendable {
    private let lock = NSLock()
    private var _shots: [[Float]] = []

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    var shots: [[Float]] { locked { _shots } }
    func add(_ samples: [Float]) { locked { _shots.append(samples) } }
}

private func captureAfterSustainedEcho(
    sampleRate: Double,
    hopSeconds: Double,
    scope: MonitorScope
) async throws -> RecordedUtterance {
    let window = retainedWindow(hopSeconds: hopSeconds)
    let capture = FakeAudioCapture()
    let gate = scope.gate()
    let calls = BargeCallbacks()
    let monitor = scope.monitor(capture: capture)
    try await monitor.start(
        isPlaying: { await gate.probe() },
        onSpeech: { calls.speech() },
        onUtterance: { calls.utterance($0) })

    let earlyHops = sampleCount(seconds: earlyEchoSeconds, rate: 1 / hopSeconds)
    for _ in 0..<earlyHops {
        #expect(
            await feed(
                chunk(amplitude: echoAmplitude, seconds: hopSeconds, rate: sampleRate),
                capture, gate))
    }
    let recentHops = sampleCount(seconds: recentEchoSeconds, rate: 1 / hopSeconds)
    for _ in 0..<recentHops {
        #expect(
            await feed(
                chunk(amplitude: -echoAmplitude, seconds: hopSeconds, rate: sampleRate),
                capture, gate))
    }
    for _ in 0..<window.tripHops {
        #expect(
            await feed(
                chunk(amplitude: speechAmplitude, seconds: hopSeconds, rate: sampleRate),
                capture, gate))
    }
    #expect(await eventually { calls.speechCount == 1 })
    #expect(await feed(endOfTurnGapChunk(hopSeconds: hopSeconds, rate: sampleRate), capture, gate))
    #expect(
        await feed(chunk(amplitude: 0, seconds: hopSeconds, rate: sampleRate), capture, gate))
    #expect(await eventually { calls.utterances.count == 1 })
    return try #require(calls.utterances.first ?? nil)
}

private func tripAfterPreRoll(
    hopSeconds: Double,
    sampleRate: Double,
    capture: FakeAudioCapture,
    gate: PlayingGate,
    calls: BargeCallbacks
) async throws -> RecordedUtterance {
    let window = retainedWindow(hopSeconds: hopSeconds)
    for _ in 0..<window.tripHops {
        #expect(
            await feed(
                chunk(amplitude: speechAmplitude, seconds: hopSeconds, rate: sampleRate),
                capture, gate))
    }
    #expect(await eventually { calls.speechCount == 1 })
    #expect(await feed(endOfTurnGapChunk(hopSeconds: hopSeconds, rate: sampleRate), capture, gate))
    #expect(
        await feed(chunk(amplitude: 0, seconds: hopSeconds, rate: sampleRate), capture, gate))
    #expect(await eventually { calls.utterances.count == 1 })
    return try #require(calls.utterances.first ?? nil)
}

@Suite("BargeInMonitor pre-roll bound")
struct BargeInMonitorPreRollTests {

    @Test func preRollCapIsFiveSecondsPlusNamedOnsetAllowance() {
        #expect(VoiceConstants.bargePreRollRestart == .seconds(5))
        #expect(VoiceConstants.bargePreRollOnsetAllowance == .milliseconds(500))
        let hop125 = retainedWindow(hopSeconds: binaryHopSeconds)
        #expect(hop125.tripHops == 3)
        #expect(hop125.recentEchoSamples == 84_000)
        #expect(hop125.speechSamples == 6_000)
        #expect(hop125.durationSeconds == 7.125)
        #expect(hop125.wavSamples == 114_000)
        let hop50 = retainedWindow(hopSeconds: fiftyMsHopSeconds)
        #expect(hop50.tripHops == 6)
        #expect(hop50.recentEchoSamples == 84_000)
        #expect(hop50.speechSamples == 4_800)
        #expect(hop50.durationSeconds == 6.9)
        #expect(hop50.wavSamples == 110_400)
    }

    /// Issue #70: sustained playback echo sits above the static 0.075 floor
    /// and never trips, so a loudness-gated trim never fires and the next
    /// interruption would swallow the whole reply. The captured PCM must be
    /// the exact 5.5 s trailing window plus post-trip audio — not merely
    /// "shorter than unbounded" and "some recent samples present."
    @Test func interruptionAfterSustainedEchoKeepsExactRetainedWindow() async throws {
        try await withMonitorScope { scope in
            let window = retainedWindow(hopSeconds: binaryHopSeconds)
            let utterance = try await captureAfterSustainedEcho(
                sampleRate: 16_000,
                hopSeconds: binaryHopSeconds,
                scope: scope)
            expectExactRetainedWindow(utterance, window)
        }
    }

    /// Each case carries its hop through echo, onset, endpoint silence, and
    /// the final chunk, then asserts its own WAV-rate composition.
    @Test(arguments: [
        (8_000.0, 0.125),
        (48_000.0, 0.125),
        (16_000.0, 0.050),
    ])
    func preRollBoundHoldsAcrossSampleRatesAndHopSizes(
        sampleRate: Double, hopSeconds: Double
    ) async throws {
        try await withMonitorScope { scope in
            let window = retainedWindow(hopSeconds: hopSeconds)
            let utterance = try await captureAfterSustainedEcho(
                sampleRate: sampleRate,
                hopSeconds: hopSeconds,
                scope: scope)
            expectExactRetainedWindow(utterance, window)
        }
    }

    /// One quiet chunk larger than the 5.5 s cap, with a distinguishable old
    /// prefix and retained tail inside it. The bounded pre-roll is checked
    /// immediately after that append — later quiet hops would repair a
    /// skipped oversized trim. Capture then trips without another cap-length
    /// of ordinary echo.
    @Test(arguments: [8_000.0, 16_000.0, 48_000.0])
    func oversizedQuietChunkTrimsOldPrefixImmediately(sampleRate: Double) async throws {
        try await withMonitorScope { scope in
            let snapshots = PreRollSnapshots()
            let capture = FakeAudioCapture()
            let gate = scope.gate()
            let calls = BargeCallbacks()
            let monitor = scope.monitor(capture: capture, onQuietPreRoll: { snapshots.add($0) })
            try await monitor.start(
                isPlaying: { await gate.probe() },
                onSpeech: { calls.speech() },
                onUtterance: { calls.utterance($0) })

            // Lock the playback echo floor on ordinary hops *before* the
            // oversized append. After a single 8 s hop the median is still
            // short of `bargeEchoMinSamples`; the first speech hops would
            // then raise the trigger above speech and never trip.
            for _ in 0..<VoiceConstants.bargeEchoMinSamples {
                #expect(
                    await feed(
                        chunk(
                            amplitude: echoAmplitude, seconds: binaryHopSeconds, rate: sampleRate),
                        capture, gate))
            }
            let shotsBeforeOversized = snapshots.shots.count
            let oversized = mixedOversizedChunk(rate: sampleRate)
            #expect(Double(oversized.samples.count) / sampleRate > preRollCapSeconds())
            #expect(await feed(oversized, capture, gate))
            #expect(await eventually { snapshots.shots.count == shotsBeforeOversized + 1 })
            let preRoll = try #require(snapshots.shots.last)
            let capSamples = Int(preRollCapSeconds() * sampleRate)
            #expect(preRoll.count == capSamples)
            #expect(preRoll.filter { matchesFloat($0, echoAmplitude) }.count == 0)
            #expect(preRoll.filter { matchesFloat($0, -echoAmplitude) }.count == capSamples)

            let window = retainedWindow(hopSeconds: binaryHopSeconds)
            let utterance = try await tripAfterPreRoll(
                hopSeconds: binaryHopSeconds,
                sampleRate: sampleRate,
                capture: capture,
                gate: gate,
                calls: calls)
            expectExactRetainedWindow(utterance, window)
        }
    }
}
