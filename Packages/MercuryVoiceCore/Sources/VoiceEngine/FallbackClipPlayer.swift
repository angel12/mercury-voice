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
    /// Never became audible: the data would not decode, or `play()` refused.
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

/// Plays a whole TTS clip returned by `POST /api/audio/speak` as a data URL.
final class FallbackClipPlayer: NSObject, AVAudioPlayerDelegate, FallbackClipPlaying,
    @unchecked Sendable
{
    private let lock = NSLock()
    private var player: AVAudioPlayer?
    private var finishContinuation: CheckedContinuation<ClipPlayback, Never>?
    /// Latched where the distinction is actually known: `AVAudioPlayer.play()`
    /// returning true is the moment the clip became audible. Everything after
    /// that is an interruption, not a failure to start.
    private var began = false

    var isPlaying: Bool {
        lock.lock()
        defer { lock.unlock() }
        return player?.isPlaying ?? false
    }

    /// Resolves when playback ends, however it ends.
    func play(data: Data) async -> ClipPlayback {
        await withCheckedContinuation { continuation in
            lock.lock()
            began = false
            do {
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
                player.delegate = self
                self.player = player
                self.finishContinuation = continuation
                // Latched before `play()` rather than after: the delegate
                // can fire the moment playback ends, and a clip short enough
                // to finish inside that window would otherwise be reported as
                // never having started.
                began = true
                lock.unlock()
                if !player.play() {
                    lock.lock()
                    began = false
                    lock.unlock()
                    finish(success: false)
                }
            } catch {
                lock.unlock()
                continuation.resume(returning: .neverStarted)
            }
        }
    }

    func stop() {
        lock.lock()
        let player = player
        lock.unlock()
        player?.stop()
        finish(success: false)
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
