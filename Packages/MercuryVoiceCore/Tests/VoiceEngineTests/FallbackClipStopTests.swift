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
        let stopReturned = Flag()
        let stopCompletedDuringStart = Flag()

        clip.onStart {
            // A real second thread attempts Stop while the start is in flight.
            Thread {
                player.stop()
                stopReturned.set()
            }.start()
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

    /// The start now runs under the same non-recursive lock that `finish` takes,
    /// so a clip that completes the instant it starts is the shape that would
    /// deadlock if `AVAudioPlayer` ever delivered its completion synchronously
    /// from `play()`. Measured: it does not, on either platform -- these resolve
    /// in milliseconds. The assertion is secondary; the test not hanging is the
    /// property.
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
}
