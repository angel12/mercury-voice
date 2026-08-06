import AVFoundation
import Foundation

/// Platform audio-session shims. On macOS this is a no-op; on iOS the
/// conversation needs `.playAndRecord` + `.voiceChat` (which also enables the
/// system echo canceller and noise suppressor).
public enum AudioSessionManager {
    #if os(iOS)
        public static func activateForVoice() throws {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(
                .playAndRecord,
                mode: .voiceChat,
                options: [.defaultToSpeaker, .allowBluetoothA2DP])
            try session.setActive(true)
        }

        public static func deactivate() {
            try? AVAudioSession.sharedInstance().setActive(
                false, options: [.notifyOthersOnDeactivation])
        }
    #else
        public static func activateForVoice() throws {}
        public static func deactivate() {}
    #endif
}
