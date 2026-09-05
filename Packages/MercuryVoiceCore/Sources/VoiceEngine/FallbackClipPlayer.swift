import AVFoundation
import Foundation

/// The whole-clip fallback sink: a synthesized clip in, "did it finish" out.
/// `FallbackClipPlayer` in production; tests substitute a fake so the
/// fallback path can be driven without an audio device (issue #34).
protocol FallbackClipPlaying: AnyObject, Sendable {
    var isPlaying: Bool { get }
    /// Resolves when playback finishes (true) or is stopped/fails (false).
    func play(data: Data) async -> Bool
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
    private let lock = NSRecursiveLock()
    private var player: PlayableClip?
    private var finishContinuation: CheckedContinuation<Bool, Never>?
    private let makeClip: ClipFactory
    /// Set by `stop()` and never cleared. Guards the window in which this
    /// player exists but `play` has not run yet.
    private var stopped = false

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

    /// Resolves when playback finishes (true) or is stopped/fails (false).
    func play(data: Data) async -> Bool {
        await withCheckedContinuation { continuation in
            lock.lock()
            // A Stop that arrived before the clip was built stays decided:
            // the caller has already been told this clip is cancelled, and
            // finally reaching `play` must not undo that.
            guard !stopped else {
                lock.unlock()
                continuation.resume(returning: false)
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
                lock.unlock()
                if !started {
                    finish(success: false)
                }
            } catch {
                lock.unlock()
                continuation.resume(returning: false)
            }
        }
    }

    /// Stop playback and make this player terminal: any later `play` resolves
    /// `false` without starting anything.
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
        lock.unlock()
        continuation?.resume(returning: success)
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
