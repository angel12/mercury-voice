import Foundation

/// Encodes mono float samples as a 16 kHz mono int16 PCM WAV file —
/// the format `/api/audio/transcribe` accepts as `audio/wav`.
public enum WAVEncoder {
    public static let targetSampleRate: Double = 16000
    public static let mimeType = "audio/wav"

    /// Downsample (naive decimation with averaging) and encode.
    public static func encode(samples: [Float], sampleRate: Double) -> Data {
        let resampled: [Float]
        if abs(sampleRate - targetSampleRate) < 1 {
            resampled = samples
        } else {
            resampled = resample(samples, from: sampleRate, to: targetSampleRate)
        }
        return encodePCM16(resampled, sampleRate: Int(targetSampleRate))
    }

    static func resample(_ samples: [Float], from source: Double, to target: Double) -> [Float] {
        guard !samples.isEmpty, source > 0, target > 0 else { return [] }
        let ratio = source / target
        let outCount = max(1, Int(Double(samples.count) / ratio))
        var out = [Float]()
        out.reserveCapacity(outCount)
        for i in 0..<outCount {
            // Average the source window covered by this output sample —
            // cheap anti-aliasing that's plenty for speech-to-text.
            let start = Int(Double(i) * ratio)
            let end = min(samples.count, max(start + 1, Int(Double(i + 1) * ratio)))
            var sum: Float = 0
            for j in start..<end { sum += samples[j] }
            out.append(sum / Float(end - start))
        }
        return out
    }

    static func encodePCM16(_ samples: [Float], sampleRate: Int) -> Data {
        let byteRate = sampleRate * 2
        let dataSize = samples.count * 2

        var data = Data(capacity: 44 + dataSize)
        data.append(contentsOf: Array("RIFF".utf8))
        appendUInt32(&data, UInt32(36 + dataSize))
        data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8))
        appendUInt32(&data, 16)  // PCM chunk size
        appendUInt16(&data, 1)  // PCM format
        appendUInt16(&data, 1)  // mono
        appendUInt32(&data, UInt32(sampleRate))
        appendUInt32(&data, UInt32(byteRate))
        appendUInt16(&data, 2)  // block align
        appendUInt16(&data, 16)  // bits per sample
        data.append(contentsOf: Array("data".utf8))
        appendUInt32(&data, UInt32(dataSize))

        for sample in samples {
            let clamped = max(-1, min(1, sample))
            let value = Int16(clamped * 32767)
            appendUInt16(&data, UInt16(bitPattern: value))
        }
        return data
    }

    private static func appendUInt16(_ data: inout Data, _ value: UInt16) {
        withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
    }

    private static func appendUInt32(_ data: inout Data, _ value: UInt32) {
        withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
    }
}
