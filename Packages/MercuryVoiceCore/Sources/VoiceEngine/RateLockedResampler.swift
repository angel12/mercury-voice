import Foundation

/// Locks a capture to the first chunk's sample rate and normalizes every
/// later chunk into it.
///
/// The capture service deliberately keeps consumer streams attached across
/// route-change engine rebuilds (a Bluetooth headset connecting mid-turn),
/// so one stream can switch hardware rates mid-utterance — 48 kHz built-in
/// mic to 8/16 kHz HFP and back. Consumers accumulate raw samples and do all
/// timing in sample counts, so mixing rates in one buffer time-warps the
/// audio and skews VAD/timeout math (issue #43). Resampling each foreign
/// chunk into the locked rate keeps the buffer, the timeline, and the
/// encoded WAV coherent.
struct RateLockedResampler {
    /// The locked rate; 0 until the first valid chunk arrives.
    private(set) var sampleRate: Double = 0

    /// Returns the chunk's samples at the locked rate, locking onto the
    /// first valid chunk's rate.
    mutating func normalize(_ chunk: AudioChunk) -> [Float] {
        guard chunk.sampleRate > 0 else { return chunk.samples }
        if sampleRate <= 0 {
            sampleRate = chunk.sampleRate
            return chunk.samples
        }
        guard chunk.sampleRate != sampleRate else { return chunk.samples }
        return WAVEncoder.resample(chunk.samples, from: chunk.sampleRate, to: sampleRate)
    }

    mutating func reset() {
        sampleRate = 0
    }
}
