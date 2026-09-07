import Foundation

/// Persisted end-of-turn silence: how much trailing quiet ends the user's
/// turn (issue #24). One knob drives both endpoints that answer "am I done
/// talking" — the listening-phase VAD and the barge-in capture. Defaults to
/// the desktop-parity constant; the SwiftUI sliders bind the same key via
/// @AppStorage. Read at each mic arm, so a change applies from the next turn
/// without restarting the conversation.
public enum TurnSilencePreference {
    public static let key = "endOfTurnSilenceSeconds"

    /// Slider bounds: under half a second the VAD clips ordinary
    /// mid-sentence pauses; past four the conversation drags.
    public static let range: ClosedRange<Double> = 0.5...4.0
    public static let defaultSeconds = VoiceConstants.endOfTurnSilence.asSeconds

    public static var seconds: Double {
        get { seconds(in: .standard) }
        set { setSeconds(newValue, in: .standard) }
    }

    /// The same read and write against an explicit store, so the clamping can
    /// be exercised without a process-global write other suites would see.
    static func seconds(in defaults: UserDefaults) -> Double {
        guard defaults.object(forKey: key) != nil else { return defaultSeconds }
        return defaults.double(forKey: key).clamped(to: range)
    }

    static func setSeconds(_ newValue: Double, in defaults: UserDefaults) {
        defaults.set(newValue.clamped(to: range), forKey: key)
    }

    public static var duration: Duration { .seconds(seconds) }
}

extension Double {
    func clamped(to range: ClosedRange<Double>) -> Double {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
