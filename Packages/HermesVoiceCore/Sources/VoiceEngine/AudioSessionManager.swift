import AVFoundation
import Foundation

/// Platform audio-session shims. On macOS this is a no-op; on iOS the
/// conversation needs `.playAndRecord` + `.voiceChat` (which also enables the
/// system echo canceller and noise suppressor).
public enum AudioSessionManager {
    #if os(iOS)
        public static func activateForVoice() throws {
            let session = AVAudioSession.sharedInstance()
            // HFP is the only Bluetooth profile with a mic channel; A2DP is
            // output-only. With both allowed the system uses HFP while the
            // mic is active, so headset input works at the cost of call-grade
            // output quality during the conversation.
            try session.setCategory(
                .playAndRecord,
                mode: .voiceChat,
                options: [.defaultToSpeaker, .allowBluetoothHFP, .allowBluetoothA2DP])
            try session.setActive(true)
            // Re-assert the user's mic choice; preferred input resets when
            // the session deactivates. Best-effort — a missing device just
            // leaves the system's route.
            if let uid = AudioDevicePreference.inputUID,
                let port = session.availableInputs?.first(where: { $0.uid == uid })
            {
                try? session.setPreferredInput(port)
            }
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
