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
    private var floorLocked = false
    private var calibratedSince: Duration?
    private var everSawPlayback = false
    private var lastPlayingAt: Duration?
    private var graceUntil: Duration = .zero
    private var recentAbove: [(above: Bool, at: Duration)] = []
    private var tripped = false
    private var trippedAt: Duration = .zero
    private var quietSince: Duration?

    public init() {}

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
        }
        wasQuietLastHop = !playing

        var trigger = max(
            VoiceConstants.bargeMinTriggerLevel, quietFloor * VoiceConstants.bargeFloorMultiplier)
        if playing {
            trigger = min(
                max(trigger, VoiceConstants.bargePlaybackMinTrigger),
                VoiceConstants.bargeTriggerCeiling)
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
        if let quiet = quietSince, now - quiet >= VoiceConstants.bargeUtteranceSilence {
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
}

extension Duration {
    static func * (lhs: Duration, rhs: Double) -> Duration {
        .seconds(lhs.asSeconds * rhs)
    }
}
