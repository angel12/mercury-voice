import AVFoundation
import Foundation
import Testing

@testable import VoiceEngine

/// Stands in for the `AVAudioPlayer` the fallback player decodes. `startPlaying`
/// can be held open, which is the window the stop/start handoff bug lives in.
private final class TestClip: PlayableClip, @unchecked Sendable {
    private let lock = NSLock()
    private var _isPlaying = false
    private var _startCount = 0
    private var _stopCount = 0
    private var _duringStart: (@Sendable () -> Void)?
    private let startSucceeds: Bool

    /// `startSucceeds: false` only matters on the pre-fix path: a fake clip has
    /// no delegate to report completion, so a start that "succeeds" would leave
    /// the continuation unresolved and hang rather than fail. After the fix the
    /// start is never reached at all.
    init(startSucceeds: Bool = true) {
        self.startSucceeds = startSucceeds
    }

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    var isPlaying: Bool { locked { _isPlaying } }
    var startCount: Int { locked { _startCount } }
    var stopCount: Int { locked { _stopCount } }

    /// Run `body` inside the next start, before the clip is playing.
    func onStart(_ body: @escaping @Sendable () -> Void) { locked { _duringStart = body } }

    func startPlaying() -> Bool {
        let hook = locked { () -> (@Sendable () -> Void)? in
            defer { _duringStart = nil }
            return _duringStart
        }
        hook?()
        locked {
            _startCount += 1
            _isPlaying = startSucceeds
        }
        return startSucceeds
    }

    func stopPlaying() {
        locked {
            _stopCount += 1
            _isPlaying = false
        }
    }
}

/// Reports completion synchronously from inside `startPlaying()`, re-entering
/// `FallbackClipPlayer.finish` on the thread that already holds the lock. Real
/// `AVAudioPlayer` was not observed doing this, but the clip seam makes it
/// reachable and a non-recursive lock hangs the speech output permanently
/// when it happens (issue #65).
private final class SynchronouslyCompletingClip: PlayableClip {
    private let delegate: AVAudioPlayerDelegate
    private let carrier: AVAudioPlayer
    private let released: Flag
    var isPlaying: Bool { false }

    /// - Parameter released: set when this clip is deallocated, so a test can
    ///   tell whether the player still retains it.
    init(delegate: AVAudioPlayerDelegate, carrier: AVAudioPlayer, released: Flag) {
        self.delegate = delegate
        self.carrier = carrier
        self.released = released
    }

    deinit { released.set() }

    func startPlaying() -> Bool {
        delegate.audioPlayerDidFinishPlaying?(carrier, successfully: true)
        return true
    }

    func stopPlaying() {}
}

private final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
    func set() { lock.lock(); value = true; lock.unlock() }
}

@Suite("Fallback clip stop/start handoff")
struct FallbackClipStopTests {
    /// 50 ms of silence: real decodable audio for `AVAudioPlayer`, inaudible,
    /// and short enough that a clip which does start finishes immediately.
    private static var silentClip: Data {
        WAVEncoder.encode(
            samples: [Float](repeating: 0, count: 800),
            sampleRate: WAVEncoder.targetSampleRate)
    }

    // MARK: R12 — Stop before the clip starts must be terminal

    @Test func stopBeforeTheClipIsBuiltIsTerminal() async {
        let clip = TestClip(startSucceeds: false)
        let player = FallbackClipPlayer(makeClip: { _, _ in clip })

        // Stop lands while the caller is still suspended on its way into
        // play() -- the actor hop in HermesSpeechOutput.playFallback and
        // DirectSpeechSession.pump.
        player.stop()
        let finished = await player.play(data: Data([1, 2, 3]))

        #expect(finished == false)
        #expect(clip.startCount == 0)
        #expect(clip.isPlaying == false)
    }

    @Test func aRealClipStoppedBeforeEntryNeverReportsPlayback() async {
        let player = FallbackClipPlayer()

        player.stop()
        let finished = await player.play(data: Self.silentClip)

        #expect(finished == false)
        #expect(player.isPlaying == false)
    }

    // MARK: R12 — Stop must not interleave between the handoff and the start

    @Test func stopCannotCompleteBetweenTheHandoffAndTheStart() async {
        let clip = TestClip()
        let player = FallbackClipPlayer(makeClip: { _, _ in clip })
        let stopAttempted = Flag()
        let stopReturned = Flag()
        let stopCompletedDuringStart = Flag()

        clip.onStart {
            // A real second thread attempts Stop while the start is in flight.
            Thread {
                stopAttempted.set()
                player.stop()
                stopReturned.set()
            }.start()
            // Handshake first: wait (bounded) until that thread has reached the
            // stop() call boundary. Without it, "parked on the lock" and "never
            // scheduled" are indistinguishable and the test below would pass on
            // a thread that never ran. This proves the attempt was made, not
            // that it entered the lock acquisition.
            let attempt = Date().addingTimeInterval(2)
            while Date() < attempt, !stopAttempted.isSet {
                Thread.sleep(forTimeInterval: 0.005)
            }
            guard stopAttempted.isSet else { return }
            // Bounded, not a join: if start and stop are serialized this thread
            // is parked on the lock and the wait simply expires. If Stop *can*
            // complete here, the start that follows it is the defect.
            let deadline = Date().addingTimeInterval(0.5)
            while Date() < deadline, !stopReturned.isSet {
                Thread.sleep(forTimeInterval: 0.005)
            }
            if stopReturned.isSet { stopCompletedDuringStart.set() }
        }

        let finished = await player.play(data: Data([1, 2, 3]))

        // The competing thread reached stop(); the 0.5 s below measured
        // serialization rather than an unscheduled thread.
        #expect(stopAttempted.isSet)
        #expect(stopCompletedDuringStart.isSet == false)
        #expect(clip.isPlaying == false)
        #expect(clip.stopCount == 1)
        #expect(finished == false)
    }

    // MARK: Preserved behaviour

    @Test func aClipThatPlaysThroughReportsSuccess() async {
        let player = FallbackClipPlayer()
        let finished = await player.play(data: Self.silentClip)
        #expect(finished == true)
    }

    /// Degenerate real clips: the shortest thing `AVAudioPlayer` will decode,
    /// started under the lock that `finish` takes. These executions completed
    /// asynchronously in milliseconds, but that is an observation about these
    /// runs, not a guarantee -- the synchronous case is pinned separately by
    /// `aSynchronousCompletionInsideTheStartResolvesInsteadOfDeadlocking`.
    @Test func aClipShortEnoughToFinishImmediatelyDoesNotReenterTheLock() async {
        let oneSample = WAVEncoder.encode(
            samples: [0], sampleRate: WAVEncoder.targetSampleRate)
        let player = FallbackClipPlayer()
        _ = await player.play(data: oneSample)
        #expect(player.isPlaying == false)

        let empty = WAVEncoder.encode(samples: [], sampleRate: WAVEncoder.targetSampleRate)
        let emptyPlayer = FallbackClipPlayer()
        _ = await emptyPlayer.play(data: empty)
        #expect(emptyPlayer.isPlaying == false)
    }

    @Test func undecodableDataFailsWithoutStartingAnything() async {
        let player = FallbackClipPlayer()
        let finished = await player.play(data: Data([0, 1, 2, 3]))
        #expect(finished == false)
        #expect(player.isPlaying == false)
    }

    // MARK: R12 -- the start runs under the lock, so reentrancy must be safe

    /// Against a non-recursive lock this hangs rather than fails: `finish` waits
    /// on the lock the start still holds. Reaching the expectations at all is
    /// the property; run under an external timeout when mutating the lock.
    @Test func aSynchronousCompletionInsideTheStartResolvesInsteadOfDeadlocking() async {
        let released = Flag()
        let player = Self.playerWithSynchronouslyCompletingClip(released: released)

        let finished = await player.play(data: Data([1, 2, 3]))

        #expect(finished == true)
        #expect(player.isPlaying == false)
        // The reentrant finish cleared `player`, so nothing retains the clip.
        // Bounded wait: the continuation resumes from inside the start, so the
        // start's own frame may not have released its local reference yet.
        #expect(Self.became(released))
    }

    /// A Stop arriving after the reentrant completion must find the continuation
    /// already consumed. A second resume would trap the checked continuation, so
    /// returning from this test at all is the "exactly once" evidence.
    @Test func aSynchronousCompletionFollowedByStopResolvesOnceAndRetainsNothing() async {
        let released = Flag()
        let player = Self.playerWithSynchronouslyCompletingClip(released: released)

        let finished = await player.play(data: Data([1, 2, 3]))
        player.stop()

        #expect(finished == true)
        #expect(player.isPlaying == false)
        #expect(Self.became(released))
    }

    /// Bounded poll for a flag set on another thread or a frame still unwinding.
    private static func became(_ flag: Flag, within: TimeInterval = 2) -> Bool {
        let deadline = Date().addingTimeInterval(within)
        while Date() < deadline, !flag.isSet { Thread.sleep(forTimeInterval: 0.005) }
        return flag.isSet
    }

    /// The clip is built inside the factory so the test holds no strong
    /// reference of its own -- `released` then reports only the player's.
    private static func playerWithSynchronouslyCompletingClip(
        released: Flag
    ) -> FallbackClipPlayer {
        let silence = Self.silentClip
        return FallbackClipPlayer(makeClip: { _, delegate in
            SynchronouslyCompletingClip(
                delegate: delegate,
                carrier: try AVAudioPlayer(data: silence),
                released: released)
        })
    }
}
