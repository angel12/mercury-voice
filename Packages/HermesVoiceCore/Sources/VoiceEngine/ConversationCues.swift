import AVFoundation
import Foundation

/// Persisted on/off switch for the conversation cue sounds (issue #15).
/// Defaults to on; the SwiftUI toggles bind the same key via @AppStorage.
public enum CuePreference {
    public static let key = "audioCuesEnabled"

    public static var enabled: Bool {
        get {
            UserDefaults.standard.object(forKey: key) == nil
                ? true
                : UserDefaults.standard.bool(forKey: key)
        }
        set { UserDefaults.standard.set(newValue, forKey: key) }
    }
}

/// Plays the short synthesized cue sounds of the conversation loop:
/// a two-note "got it" blip when a spoken turn is captured, and a soft
/// single tick while the agent is thinking. Clips are generated once at
/// init — no bundled assets. Cues are deliberately short and quiet so the
/// echo canceller keeps them away from the barge-in monitor.
public final class ConversationCuePlayer: @unchecked Sendable {
    private let lock = NSLock()
    private let turnCapturedClip: Data
    private let thinkingTickClip: Data
    // One live player per cue slot; a cue replacing itself mid-play just
    // drops the old (sub-quarter-second) clip.
    private var turnCapturedPlayer: AVAudioPlayer?
    private var thinkingTickPlayer: AVAudioPlayer?

    public init() {
        // "Got it": two quick rising notes (E5 → A5).
        turnCapturedClip = Self.encodeClip(
            notes: [
                Note(frequency: 659.25, duration: 0.07, amplitude: 0.22),
                Note(frequency: 880.00, duration: 0.09, amplitude: 0.22),
            ],
            gap: 0.02)
        // Thinking tick: a single soft mid blip.
        thinkingTickClip = Self.encodeClip(
            notes: [Note(frequency: 587.33, duration: 0.06, amplitude: 0.10)],
            gap: 0)
    }

    public func playTurnCaptured() {
        guard CuePreference.enabled else { return }
        lock.lock()
        turnCapturedPlayer = Self.play(turnCapturedClip, replacing: turnCapturedPlayer)
        lock.unlock()
    }

    public func playThinkingTick() {
        guard CuePreference.enabled else { return }
        lock.lock()
        thinkingTickPlayer = Self.play(thinkingTickClip, replacing: thinkingTickPlayer)
        lock.unlock()
    }

    private static func play(_ clip: Data, replacing old: AVAudioPlayer?) -> AVAudioPlayer? {
        old?.stop()
        guard let player = try? AVAudioPlayer(data: clip) else { return nil }
        #if os(macOS)
            // Honor the selected output like FallbackClipPlayer; only pass
            // UIDs that resolve to a live device.
            if let uid = AudioDevicePreference.outputUID,
                MacAudioDevices.resolve(uid: uid) != nil
            {
                player.currentDevice = uid
            }
        #endif
        return player.play() ? player : nil
    }

    // MARK: Synthesis

    private struct Note {
        var frequency: Double
        var duration: Double
        var amplitude: Double
    }

    private static let sampleRate = 24000.0

    private static func encodeClip(notes: [Note], gap: Double) -> Data {
        var samples: [Float] = []
        for (index, note) in notes.enumerated() {
            if index > 0 {
                samples.append(
                    contentsOf: [Float](repeating: 0, count: Int(gap * sampleRate)))
            }
            samples.append(contentsOf: synthesize(note))
        }
        return WAVEncoder.encodePCM16(samples, sampleRate: Int(sampleRate))
    }

    /// A sine with a touch of second harmonic (less buzzer, more chime) and
    /// short attack/release ramps so the clip starts and ends without clicks.
    private static func synthesize(_ note: Note) -> [Float] {
        let count = Int(note.duration * sampleRate)
        let ramp = min(Int(0.008 * sampleRate), count / 2)
        var out = [Float]()
        out.reserveCapacity(count)
        for i in 0..<count {
            let t = Double(i) / sampleRate
            let phase = 2 * Double.pi * note.frequency * t
            var value = sin(phase) + 0.3 * sin(2 * phase)
            var envelope = 1.0
            if i < ramp { envelope = Double(i) / Double(ramp) }
            if i >= count - ramp { envelope = Double(count - i) / Double(ramp) }
            value *= note.amplitude * envelope / 1.3  // renormalize the harmonic
            out.append(Float(value))
        }
        return out
    }
}
