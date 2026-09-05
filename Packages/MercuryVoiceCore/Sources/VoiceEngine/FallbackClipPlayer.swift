import AVFoundation
import Foundation

/// What became of one clip.
///
/// This used to be a `Bool` meaning "did it finish", which collapsed four
/// different endings into `false`: undecodable data, `play()` refusing, a
/// stop, and a decode error after audio was already coming out of the
/// speaker. Callers that must know whether the user heard anything — the
/// direct session's `.fallback` decision (issue #69) — cannot recover that
/// from one bit.
enum ClipPlayback: Sendable {
    /// Played to the end.
    case completed
    /// Became audible and was cut short: a stop, or a decode error mid-clip.
    case interrupted
    /// Never became audible: the data would not decode, `play()` refused, or
    /// a Stop had already made this player terminal.
    case neverStarted
}

/// The whole-clip fallback sink: a synthesized clip in, what became of it out.
/// `FallbackClipPlayer` in production; tests substitute a fake so the
/// fallback path can be driven without an audio device (issue #34).
protocol FallbackClipPlaying: AnyObject, Sendable {
    var isPlaying: Bool { get }
    /// Resolves when playback ends, however it ends.
    func play(data: Data) async -> ClipPlayback
    func stop()
}

/// What the clip lifecycle actually does with a decoded clip. Extracted so the
/// stop/start handoff can be driven deterministically without an audio device
/// (issue #65); in production this is always `AVAudioPlayer`.
protocol PlayableClip: AnyObject {
    var isPlaying: Bool { get }
    /// Begin playback; `false` means it could not start.
    func startPlaying() -> Bool
    func stopPlaying()
}

extension AVAudioPlayer: PlayableClip {
    func startPlaying() -> Bool { play() }
    func stopPlaying() { stop() }
}

/// Decodes `data` into a clip ready to start, reporting completion to
/// `delegate`. Everything device-facing lives behind this.
typealias ClipFactory =
    @Sendable (_ data: Data, _ delegate: AVAudioPlayerDelegate) throws -> PlayableClip

/// Plays a whole TTS clip returned by `POST /api/audio/speak` as a data URL.
///
/// Single-use, and terminal after `stop()`: both callers mint one of these per
/// clip and can be interrupted on the actor hop that reaches `play`, so a Stop
/// that lands before the clip is even built has to stay decided (issue #65).
final class FallbackClipPlayer: NSObject, AVAudioPlayerDelegate, FallbackClipPlaying,
    @unchecked Sendable
{
    /// Recursive because the start now runs under this lock: a clip that
    /// reported completion synchronously from `startPlaying()` would re-enter
    /// `finish` on the same thread and deadlock a non-recursive lock. On the
    /// reentrant path `player` and `finishContinuation` are already published,
    /// so `finish` resolves once and the outer `play` merely unlocks (#65).
    /// `began` deliberately is *not* published yet on that path — nothing was
    /// audible, so a synchronous failure has to read it as false (#69).
    private let lock = NSRecursiveLock()
    private var player: PlayableClip?
    private var finishContinuation: CheckedContinuation<ClipPlayback, Never>?
    private let makeClip: ClipFactory
    /// Set by `stop()` and never cleared. Guards the window in which this
    /// player exists but `play` has not run yet.
    private var stopped = false
    /// Latched where the distinction is actually known: `startPlaying()`
    /// returning true is the moment the clip became audible. Everything after
    /// that is an interruption, not a failure to start. Only ever read under
    /// the lock, and only ever set while the start still holds it.
    private var began = false

    override convenience init() {
        self.init(makeClip: FallbackClipPlayer.makeAudioPlayerClip)
    }

    init(makeClip: @escaping ClipFactory) {
        self.makeClip = makeClip
        super.init()
    }

    var isPlaying: Bool {
        lock.lock()
        defer { lock.unlock() }
        return player?.isPlaying ?? false
    }

    /// Resolves when playback ends, however it ends.
    func play(data: Data) async -> ClipPlayback {
        await withCheckedContinuation { continuation in
            lock.lock()
            // A Stop that arrived before the clip was built stays decided:
            // the caller has already been told this clip is cancelled, and
            // finally reaching `play` must not undo that. Nothing was ever
            // audible, so this is `neverStarted` rather than an interruption.
            guard !stopped else {
                lock.unlock()
                continuation.resume(returning: .neverStarted)
                return
            }
            do {
                let player = try makeClip(data, self)
                self.player = player
                self.finishContinuation = continuation
                // Started under the same lock that publishes it, so a Stop
                // cannot land in between: it either arrives first and is
                // refused above, or waits here and stops a clip that really
                // did start.
                let started = player.startPlaying()
                // Latched only on a successful start, and only after the call
                // returns. Serializing the start under the lock is what makes
                // this safe and what makes it necessary (#65 + #69):
                //
                //  - An asynchronous completion runs `finish` on another
                //    thread, which blocks on this same lock until the latch is
                //    published, so it can never read a stale `false`. That is
                //    the race that forced the latch *before* the start while
                //    `play` still unlocked first.
                //  - A clip that completes synchronously from `startPlaying()`
                //    re-enters `finish` on this thread with `began` still
                //    false, so a synchronous failure resolves `neverStarted`
                //    rather than claiming the user heard something. Latching
                //    first would reintroduce the #69 defect on that path.
                //
                // Setting it afterwards on an already-resolved continuation is
                // harmless: the player is single-use and terminal.
                if started { began = true }
                lock.unlock()
                if !started {
                    // A no-op when a synchronous completion already resolved.
                    finish(success: false)
                }
            } catch {
                lock.unlock()
                continuation.resume(returning: .neverStarted)
            }
        }
    }

    /// Stop playback and make this player terminal: any later `play` resolves
    /// `neverStarted` without starting anything.
    func stop() {
        lock.lock()
        stopped = true
        let player = player
        lock.unlock()
        player?.stopPlaying()
        finish(success: false)
    }

    /// Production clip: an `AVAudioPlayer` decoded from the whole clip and
    /// routed to the selected output, not yet started.
    private static func makeAudioPlayerClip(
        data: Data, delegate: AVAudioPlayerDelegate
    ) throws -> PlayableClip {
        let player = try AVAudioPlayer(data: data)
        #if os(macOS)
            // Honor the selected output; only pass UIDs that resolve
            // to a live device — a stale UID would fail playback.
            if let uid = AudioDevicePreference.outputUID,
                MacAudioDevices.resolve(uid: uid) != nil
            {
                player.currentDevice = uid
            }
        #endif
        player.delegate = delegate
        return player
    }

    private func finish(success: Bool) {
        lock.lock()
        let continuation = finishContinuation
        finishContinuation = nil
        player = nil
        let started = began
        began = false
        lock.unlock()
        continuation?.resume(returning: success ? .completed : (started ? .interrupted : .neverStarted))
    }

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        finish(success: flag)
    }

    func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        finish(success: false)
    }

    /// Decode a `data:<mime>;base64,<payload>` URL.
    static func decodeDataURL(_ dataURL: String) -> Data? {
        guard dataURL.hasPrefix("data:"),
            let comma = dataURL.firstIndex(of: ",")
        else { return nil }
        let header = dataURL[dataURL.startIndex..<comma]
        guard header.contains(";base64") else { return nil }
        return Data(base64Encoded: String(dataURL[dataURL.index(after: comma)...]))
    }
}
