import Foundation
import Testing

@testable import VoiceEngine

/// Route changes rebuild the capture engine mid-stream and switch hardware
/// rates (48 kHz built-in mic ↔ 8/16 kHz Bluetooth HFP) while consumer
/// streams stay attached — these cover the issue #43 normalization that
/// keeps one capture buffer at one rate.
@Suite("Rate-locked resampling")
struct RateLockedResamplerTests {
    private func chunk(seconds: Double, rate: Double, value: Float = 0.5) -> AudioChunk {
        AudioChunk(
            samples: [Float](repeating: value, count: Int(seconds * rate)),
            sampleRate: rate)
    }

    @Test func locksToFirstChunkRate() {
        var resampler = RateLockedResampler()
        #expect(resampler.sampleRate == 0)
        let first = chunk(seconds: 0.5, rate: 48000)
        #expect(resampler.normalize(first) == first.samples)  // passthrough
        #expect(resampler.sampleRate == 48000)
    }

    @Test func sameRatePassesThroughUntouched() {
        var resampler = RateLockedResampler()
        _ = resampler.normalize(chunk(seconds: 0.1, rate: 16000))
        let next = chunk(seconds: 0.1, rate: 16000, value: 0.25)
        #expect(resampler.normalize(next) == next.samples)
    }

    /// A route change to a lower hardware rate: one second of audio must
    /// stay one second of audio in the locked-rate buffer.
    @Test func mixedRatesPreserveDuration() {
        var resampler = RateLockedResampler()
        var buffer: [Float] = []
        buffer += resampler.normalize(chunk(seconds: 1, rate: 48000))
        buffer += resampler.normalize(chunk(seconds: 1, rate: 16000))  // BT connects
        buffer += resampler.normalize(chunk(seconds: 1, rate: 48000))  // …and drops

        let duration = Double(buffer.count) / resampler.sampleRate
        #expect(abs(duration - 3.0) < 0.01)
    }

    @Test func upsamplingLowerRateChunksWorks() {
        var resampler = RateLockedResampler()
        _ = resampler.normalize(chunk(seconds: 1, rate: 8000))  // HFP first
        let upsampled = resampler.normalize(chunk(seconds: 1, rate: 48000))
        #expect(abs(Double(upsampled.count) - 8000) < 80)  // 1s at the locked 8 kHz
    }

    /// Constant signal survives the averaging resampler — no artifacts that
    /// would skew RMS level (VAD) math.
    @Test func resamplingPreservesConstantSignal() {
        var resampler = RateLockedResampler()
        _ = resampler.normalize(chunk(seconds: 0.1, rate: 16000))
        let normalized = resampler.normalize(chunk(seconds: 0.1, rate: 48000, value: 0.5))
        #expect(normalized.allSatisfy { abs($0 - 0.5) < 0.001 })
    }

    @Test func resetUnlocksTheRate() {
        var resampler = RateLockedResampler()
        _ = resampler.normalize(chunk(seconds: 0.1, rate: 48000))
        resampler.reset()
        _ = resampler.normalize(chunk(seconds: 0.1, rate: 16000))
        #expect(resampler.sampleRate == 16000)
    }

    @Test func invalidRateChunkIsPassedThroughWithoutLocking() {
        var resampler = RateLockedResampler()
        _ = resampler.normalize(AudioChunk(samples: [0.1, 0.2], sampleRate: 0))
        #expect(resampler.sampleRate == 0)  // still unlocked
        _ = resampler.normalize(chunk(seconds: 0.1, rate: 48000))
        #expect(resampler.sampleRate == 48000)
    }

    /// End-to-end: a mixed-rate utterance encodes to a WAV whose data length
    /// matches its true duration at the encoder's fixed 16 kHz output.
    @Test func mixedRateBufferEncodesToCorrectWAVLength() {
        var resampler = RateLockedResampler()
        var buffer: [Float] = []
        buffer += resampler.normalize(chunk(seconds: 1, rate: 48000))
        buffer += resampler.normalize(chunk(seconds: 1, rate: 16000))

        let wav = WAVEncoder.encode(samples: buffer, sampleRate: resampler.sampleRate)
        // 44-byte header + 2 seconds × 16000 Hz × 2 bytes/sample.
        let expected = 44 + 2 * 16000 * 2
        #expect(abs(wav.count - expected) < 200)
    }
}
