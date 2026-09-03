import Foundation

#if canImport(AVFAudio)
    import AVFAudio
#endif

/// Where the app stands with the system microphone permission.
public enum MicrophoneAuthorization: Sendable, Equatable {
    case undetermined
    case granted
    case denied
}

/// The permission seam the engine consults before every mic arm (issue #23
/// §1.4). Asking explicitly, instead of letting `AVAudioEngine.start` trip
/// the system prompt, is what lets a denial land in a dedicated recoverable
/// state rather than an opaque OSStatus error.
public protocol MicrophoneAuthorizing: Sendable {
    /// Resolve the permission: prompt when undetermined, otherwise return
    /// the decided state. Never returns `.undetermined`.
    func request() async -> MicrophoneAuthorization
}

/// Default for callers that don't care (tests, non-capturing hosts).
public struct AlwaysGrantedMicrophone: MicrophoneAuthorizing {
    public init() {}
    public func request() async -> MicrophoneAuthorization { .granted }
}

#if canImport(AVFAudio)
    /// The real permission, via `AVAudioApplication` (iOS 17 / macOS 14).
    public struct SystemMicrophoneAuthorization: MicrophoneAuthorizing {
        public init() {}

        public var current: MicrophoneAuthorization {
            switch AVAudioApplication.shared.recordPermission {
            case .granted: .granted
            case .denied: .denied
            case .undetermined: .undetermined
            @unknown default: .undetermined
            }
        }

        public func request() async -> MicrophoneAuthorization {
            switch current {
            case .granted: return .granted
            case .denied: return .denied
            case .undetermined:
                let granted = await AVAudioApplication.requestRecordPermission()
                return granted ? .granted : .denied
            }
        }
    }
#endif
