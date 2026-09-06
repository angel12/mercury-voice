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

/// Same 125 ms hop as the stale-run tests: exact binary fraction, so the
/// detector's 300 ms window does not round-trip over the fill threshold.
private let testRate: Double = 16000
private let hopSamples = 2000
private let hopSeconds = Double(hopSamples) / testRate

/// Echo amplitude whose normalized RMS is 0.3 — above `bargeMinTriggerLevel`
/// (0.075) so the old loudness-gated trim refuses to rotate, but below the
/// playback echo trigger (~0.45) so the detector stays `.quiet`.
private let echoLevel = 0.3
private let echoAmplitude = Float(echoLevel * VoiceConstants.rmsNormalizationDivisor)
private let speechAmplitude: Float = 0.5

private func echoChunk(sign: Float, samples: Int = hopSamples) -> AudioChunk {
    AudioChunk(
        samples: [Float](repeating: sign * echoAmplitude, count: samples),
        sampleRate: testRate)
}

private func speechChunk() -> AudioChunk {
    AudioChunk(
        samples: [Float](repeating: speechAmplitude, count: hopSamples),
        sampleRate: testRate)
}

private func quietChunk(samples: Int = hopSamples) -> AudioChunk {
    AudioChunk(samples: [Float](repeating: 0, count: samples), sampleRate: testRate)
}

private func endOfTurnGapChunk() -> AudioChunk {
    let hops = ((TurnSilencePreference.seconds + hopSeconds) / hopSeconds).rounded(.up)
    return quietChunk(samples: Int(hops) * hopSamples)
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

/// Echo long enough that an unbounded pre-roll is obviously past the 5.5 s
/// cap. Early hops use +echo, recent hops use −echo, so the next interruption
/// can be checked for contamination vs. the trailing window.
private let earlyEchoHops = 64  // 8.0 s
private let recentEchoHops = 48  // 6.0 s

private var maxRetainedSeconds: Double {
    (VoiceConstants.bargePreRollRestart + VoiceConstants.bargePreRollOnsetAllowance)
        .asSeconds
}

/// Post-trip audio the bound does not cover: the tripping hop plus the
/// endpointing silence. Slack is one extra hop.
private var postTripSlackSeconds: Double {
    hopSeconds + TurnSilencePreference.seconds + hopSeconds + hopSeconds
}

@Suite("BargeInMonitor pre-roll bound")
struct BargeInMonitorPreRollTests {

    /// Issue #70: sustained playback echo sits above the static 0.075 floor
    /// and never trips, so a loudness-gated trim never fires and the next
    /// interruption would swallow the whole reply.
    @Test func sustainedNontrippingEchoDoesNotGrowPreRollPastTheBound() async throws {
        try await withMonitorScope { scope in
            let capture = FakeAudioCapture()
            let gate = scope.gate()
            let calls = BargeCallbacks()
            let monitor = scope.monitor(capture: capture)
            try await monitor.start(
                isPlaying: { await gate.probe() },
                onSpeech: { calls.speech() },
                onUtterance: { calls.utterance($0) })

            for _ in 0..<earlyEchoHops {
                #expect(await feed(echoChunk(sign: 1), capture, gate))
            }
            for _ in 0..<recentEchoHops {
                #expect(await feed(echoChunk(sign: -1), capture, gate))
            }
            // Two loud hops fill the 300 ms window; the third trips.
            #expect(await feed(speechChunk(), capture, gate))
            #expect(await feed(speechChunk(), capture, gate))
            #expect(await feed(speechChunk(), capture, gate))
            #expect(await eventually { calls.speechCount == 1 })

            #expect(await feed(endOfTurnGapChunk(), capture, gate))
            #expect(await feed(quietChunk(), capture, gate))
            #expect(await eventually { calls.utterances.count == 1 })

            let utterance = try #require(calls.utterances.first ?? nil)
            #expect(utterance.heardSpeech)
            let duration = utterance.duration.asSeconds
            #expect(duration <= maxRetainedSeconds + postTripSlackSeconds)
            // Unbounded 8 s + 6 s of echo would land well above 10 s.
            #expect(duration < 10)
        }
    }

    /// The interruption after that echo must contain the trailing window and
    /// the onset, not the early reply leakage.
    @Test func interruptionAfterSustainedEchoKeepsRecentAudioNotTheEarlyEcho() async throws {
        try await withMonitorScope { scope in
            let capture = FakeAudioCapture()
            let gate = scope.gate()
            let calls = BargeCallbacks()
            let monitor = scope.monitor(capture: capture)
            try await monitor.start(
                isPlaying: { await gate.probe() },
                onSpeech: { calls.speech() },
                onUtterance: { calls.utterance($0) })

            for _ in 0..<earlyEchoHops {
                #expect(await feed(echoChunk(sign: 1), capture, gate))
            }
            for _ in 0..<recentEchoHops {
                #expect(await feed(echoChunk(sign: -1), capture, gate))
            }
            #expect(await feed(speechChunk(), capture, gate))
            #expect(await feed(speechChunk(), capture, gate))
            #expect(await feed(speechChunk(), capture, gate))
            #expect(await eventually { calls.speechCount == 1 })
            #expect(await feed(endOfTurnGapChunk(), capture, gate))
            #expect(await feed(quietChunk(), capture, gate))
            #expect(await eventually { calls.utterances.count == 1 })

            let utterance = try #require(calls.utterances.first ?? nil)
            let pcm = pcm16Samples(utterance.audio)
            #expect(!pcm.isEmpty)

            let earlyCount = pcm.filter { matchesAmplitude($0, echoAmplitude) }.count
            let recentCount = pcm.filter { matchesAmplitude($0, -echoAmplitude) }.count
            let speechCount = pcm.filter { matchesAmplitude($0, speechAmplitude) }.count

            #expect(earlyCount == 0)
            #expect(recentCount > 0)
            #expect(speechCount > 0)
            // Onset: at least the two pre-trip hops plus the tripping hop.
            #expect(speechCount >= hopSamples * 3)
        }
    }
}
