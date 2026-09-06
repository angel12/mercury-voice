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

    func monitor(capture: any AudioCaptureStreaming) -> BargeInMonitor {
        let monitor = BargeInMonitor(capture: capture, detachCaptureOnSuspend: false)
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

/// Detector hop used for speech and endpointing. 125 ms is an exact binary
/// fraction, so the 300 ms sustained window fills in three hops.
private let speechHopSeconds = 0.125

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

/// Counts are at `WAVEncoder.targetSampleRate` (16 kHz). The monitor may
/// lock a different capture rate; encode always resamples to this output.
///
/// Constructed 16 kHz / 125 ms timeline:
/// - 5.25 s of recent −echo inside the 5.5 s ring (two 125 ms onset hops
///   occupy the other 0.25 s) → 84,000 samples
/// - three 125 ms speech hops (two onset + trip) → 6,000 samples
/// - 0 early +echo
/// - full utterance 7.125 s → 114,000 samples (ring + trip hop + 1.375 s
///   endpoint gap + captureEnded hop)
private let expectedRecentEchoSamples = 84_000
private let expectedSpeechSamples = 6_000
private let expectedEarlyEchoSamples = 0
private let expectedDurationSeconds = 7.125
private let expectedWAVSamples = 114_000

private func sampleCount(seconds: Double, rate: Double) -> Int {
    Int((seconds * rate).rounded())
}

private func chunk(amplitude: Float, seconds: Double, rate: Double) -> AudioChunk {
    AudioChunk(
        samples: [Float](repeating: amplitude, count: sampleCount(seconds: seconds, rate: rate)),
        sampleRate: rate)
}

private func endOfTurnGapChunk(rate: Double) -> AudioChunk {
    let hops = ((TurnSilencePreference.seconds + speechHopSeconds) / speechHopSeconds)
        .rounded(.up)
    return chunk(amplitude: 0, seconds: hops * speechHopSeconds, rate: rate)
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

private func expectExactRetainedWindow(_ utterance: RecordedUtterance) {
    #expect(utterance.heardSpeech)
    #expect(utterance.duration.asSeconds == expectedDurationSeconds)
    let pcm = pcm16Samples(utterance.audio)
    #expect(pcm.count == expectedWAVSamples)
    #expect(pcm.filter { matchesAmplitude($0, echoAmplitude) }.count == expectedEarlyEchoSamples)
    #expect(pcm.filter { matchesAmplitude($0, -echoAmplitude) }.count == expectedRecentEchoSamples)
    #expect(pcm.filter { matchesAmplitude($0, speechAmplitude) }.count == expectedSpeechSamples)
}

private func captureAfterSustainedEcho(
    sampleRate: Double,
    echoHopSeconds: Double,
    oversizedEarlyEcho: Bool,
    scope: MonitorScope
) async throws -> RecordedUtterance {
    let capture = FakeAudioCapture()
    let gate = scope.gate()
    let calls = BargeCallbacks()
    let monitor = scope.monitor(capture: capture)
    try await monitor.start(
        isPlaying: { await gate.probe() },
        onSpeech: { calls.speech() },
        onUtterance: { calls.utterance($0) })

    if oversizedEarlyEcho {
        #expect(earlyEchoSeconds > 5.5)
        #expect(
            await feed(
                chunk(amplitude: echoAmplitude, seconds: earlyEchoSeconds, rate: sampleRate),
                capture, gate))
    } else {
        let hops = sampleCount(seconds: earlyEchoSeconds, rate: 1 / echoHopSeconds)
        for _ in 0..<hops {
            #expect(
                await feed(
                    chunk(amplitude: echoAmplitude, seconds: echoHopSeconds, rate: sampleRate),
                    capture, gate))
        }
    }
    let recentHops = sampleCount(seconds: recentEchoSeconds, rate: 1 / echoHopSeconds)
    for _ in 0..<recentHops {
        #expect(
            await feed(
                chunk(amplitude: -echoAmplitude, seconds: echoHopSeconds, rate: sampleRate),
                capture, gate))
    }
    // Two loud hops fill the 300 ms window; the third trips.
    for _ in 0..<3 {
        #expect(
            await feed(
                chunk(amplitude: speechAmplitude, seconds: speechHopSeconds, rate: sampleRate),
                capture, gate))
    }
    #expect(await eventually { calls.speechCount == 1 })
    #expect(await feed(endOfTurnGapChunk(rate: sampleRate), capture, gate))
    #expect(
        await feed(chunk(amplitude: 0, seconds: speechHopSeconds, rate: sampleRate), capture, gate))
    #expect(await eventually { calls.utterances.count == 1 })
    return try #require(calls.utterances.first ?? nil)
}

@Suite("BargeInMonitor pre-roll bound")
struct BargeInMonitorPreRollTests {

    @Test func preRollCapIsFiveSecondsPlusNamedOnsetAllowance() {
        #expect(VoiceConstants.bargePreRollRestart == .seconds(5))
        #expect(VoiceConstants.bargePreRollOnsetAllowance == .milliseconds(500))
        #expect(
            sampleCount(seconds: expectedDurationSeconds, rate: WAVEncoder.targetSampleRate)
                == expectedWAVSamples)
    }

    /// Issue #70: sustained playback echo sits above the static 0.075 floor
    /// and never trips, so a loudness-gated trim never fires and the next
    /// interruption would swallow the whole reply. The captured PCM must be
    /// the exact 5.5 s trailing window plus post-trip audio — not merely
    /// "shorter than unbounded" and "some recent samples present."
    @Test func interruptionAfterSustainedEchoKeepsExactRetainedWindow() async throws {
        try await withMonitorScope { scope in
            let utterance = try await captureAfterSustainedEcho(
                sampleRate: 16_000,
                echoHopSeconds: speechHopSeconds,
                oversizedEarlyEcho: false,
                scope: scope)
            expectExactRetainedWindow(utterance)
        }
    }

    /// Same constructed timeline at other locked rates and chunk sizes,
    /// including one early-echo chunk larger than the 5.5 s cap. WAV
    /// normalization keeps the expected 16 kHz composition.
    @Test(arguments: [
        (8_000.0, 0.125, false),
        (48_000.0, 0.125, false),
        (16_000.0, 0.050, false),
        (8_000.0, 0.125, true),
        (16_000.0, 0.125, true),
        (48_000.0, 0.125, true),
    ])
    func preRollBoundHoldsAcrossSampleRatesAndChunkSizes(
        sampleRate: Double, echoHopSeconds: Double, oversizedEarlyEcho: Bool
    ) async throws {
        try await withMonitorScope { scope in
            let utterance = try await captureAfterSustainedEcho(
                sampleRate: sampleRate,
                echoHopSeconds: echoHopSeconds,
                oversizedEarlyEcho: oversizedEarlyEcho,
                scope: scope)
            expectExactRetainedWindow(utterance)
        }
    }
}
