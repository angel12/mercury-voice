import Foundation

/// Pure barge-in decision logic — a port of `lib/voice-barge-in.ts`'s tick
/// loop, extracted from the audio plumbing so it can be unit-tested with
/// synthetic level timelines.
///
/// Feed it one normalized level sample per hop along with whether TTS is
/// audibly playing; it answers when speech has tripped and when the captured
/// utterance has endpointed.
public struct BargeDetector: Sendable {
    public enum Verdict: Equatable, Sendable {
        case quiet
        /// Sustained speech detected — stop playback, start retaining audio.
        case tripped
        /// Speech is in progress (post-trip, pre-endpoint).
        case capturing
        /// Post-trip endpoint reached (trailing silence or hard cap).
        case captureEnded
    }

    private var floorSamples: [Double] = []
    private var quietFloor: Double = 0
    private var echoSamples: [Double] = []
    private var echoFloor: Double = 0
    private var floorLocked = false
    private var calibratedSince: Duration?
    private var everSawPlayback = false
    private var lastPlayingAt: Duration?
    private var graceUntil: Duration = .zero
    private var recentAbove: [(above: Bool, at: Duration)] = []
    private var tripped = false
    private var trippedAt: Duration = .zero
    private var quietSince: Duration?
    /// Post-trip trailing silence that endpoints the capture — injectable so
    /// the user's end-of-turn setting (issue #24) also governs barge turns.
    private let utteranceSilence: Duration

    public init(utteranceSilence: Duration = VoiceConstants.bargeUtteranceSilence) {
        self.utteranceSilence = utteranceSilence
    }

    public var hasTripped: Bool { tripped }

    /// `now` is time since the monitor started; one call per level hop.
    public mutating func process(level: Double, at now: Duration, playing: Bool) -> Verdict {
        if tripped {
            return processCapture(level: level, at: now)
        }

        // Noise-floor calibration: only quiet-phase (not-playing) samples
        // feed the median — echo cancellation is not trusted.
        if !playing, !floorLocked {
            pushFloorSample(level)
            if calibratedSince == nil { calibratedSince = now }
        }
        if playing || calibratedSince.map({ now - $0 >= VoiceConstants.bargeCalibration }) == true {
            floorLocked = true
        }

        // Grace window on the quiet→playing edge, but not for brief
        // inter-sentence gaps (they'd chain grace windows forever).
        if playing {
            let gapLongEnough =
                lastPlayingAt.map { now - $0 >= VoiceConstants.bargePlaybackGapForGrace } ?? true
            if !everSawPlayback || (wasQuietLastHop && gapLongEnough) {
                graceUntil = now + VoiceConstants.bargePlaybackGrace
            }
            everSawPlayback = true
            lastPlayingAt = now
            // Every playback-phase level feeds the echo median (issue #12):
            // with output on a separate engine the system AEC has no
            // reference, so the mic hears the speakers and the trigger must
            // ride above that. User speech is brief relative to the window,
            // so the median tracks the echo, not the interruption.
            pushEchoSample(level)
        }
        wasQuietLastHop = !playing

        var trigger = max(
            VoiceConstants.bargeMinTriggerLevel, quietFloor * VoiceConstants.bargeFloorMultiplier)
        if playing {
            trigger = min(
                max(trigger, VoiceConstants.bargePlaybackMinTrigger),
                VoiceConstants.bargeTriggerCeiling)
            // The echo term is deliberately not capped by the ceiling: when
            // the speakers are loud enough that echo alone exceeds it, any
            // lower trigger just loops the agent's voice back at itself.
            if echoSamples.count >= VoiceConstants.bargeEchoMinSamples {
                trigger = max(trigger, echoFloor * VoiceConstants.bargeEchoFloorMultiplier)
            }
        }

        // Post-lock drift: quiet samples below the trigger keep feeding the
        // median while output is quiet.
        if floorLocked, !playing, level < trigger {
            pushFloorSample(level)
        }

        let above = floorLocked && level >= trigger && now >= graceUntil
        recentAbove.append((above, now))
        while let first = recentAbove.first, now - first.at > VoiceConstants.bargeSustainedWindow {
            recentAbove.removeFirst()
        }
        let aboveCount = recentAbove.lazy.filter(\.above).count
        let span = recentAbove.first.map { now - $0.at } ?? .zero
        let windowFilled =
            span >= VoiceConstants.bargeSustainedWindow * VoiceConstants.bargeSustainedMajority
        let majority =
            Double(aboveCount) >= Double(recentAbove.count) * VoiceConstants.bargeSustainedMajority

        if above, windowFilled, majority {
            tripped = true
            trippedAt = now
            quietSince = nil
            return .tripped
        }
        return .quiet
    }

    private var wasQuietLastHop = true

    private mutating func processCapture(level: Double, at now: Duration) -> Verdict {
        // Endpointing uses the raw minimum trigger, not the phase-aware one.
        if level >= VoiceConstants.bargeMinTriggerLevel {
            quietSince = nil
        } else if quietSince == nil {
            quietSince = now
        }
        if let quiet = quietSince, now - quiet >= utteranceSilence {
            return .captureEnded
        }
        if now - trippedAt >= VoiceConstants.bargeUtteranceMax {
            return .captureEnded
        }
        return .capturing
    }

    private mutating func pushFloorSample(_ level: Double) {
        floorSamples.append(level)
        if floorSamples.count > VoiceConstants.bargeFloorSampleCap {
            floorSamples.removeFirst()
        }
        // Upper median, matching the reference's `sorted[length >> 1]`.
        let sorted = floorSamples.sorted()
        quietFloor = sorted[sorted.count >> 1]
    }

    private mutating func pushEchoSample(_ level: Double) {
        echoSamples.append(level)
        if echoSamples.count > VoiceConstants.bargeEchoSampleCap {
            echoSamples.removeFirst()
        }
        let sorted = echoSamples.sorted()
        echoFloor = sorted[sorted.count >> 1]
    }
}

extension Duration {
    static func * (lhs: Duration, rhs: Double) -> Duration {
        .seconds(lhs.asSeconds * rhs)
    }
}
