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

/// Plays a whole TTS clip returned by `POST /api/audio/speak` as a data URL.
final class FallbackClipPlayer: NSObject, AVAudioPlayerDelegate, FallbackClipPlaying,
    @unchecked Sendable
{
    private let lock = NSLock()
    private var player: AVAudioPlayer?
    private var finishContinuation: CheckedContinuation<Bool, Never>?

    var isPlaying: Bool {
        lock.lock()
        defer { lock.unlock() }
        return player?.isPlaying ?? false
    }

    /// Resolves when playback finishes (true) or is stopped/fails (false).
    func play(data: Data) async -> Bool {
        await withCheckedContinuation { continuation in
            lock.lock()
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
                lock.unlock()
                if !player.play() {
                    finish(success: false)
                }
            } catch {
                lock.unlock()
                continuation.resume(returning: false)
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
