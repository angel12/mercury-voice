// Compiled into BOTH the app and the HermesVoiceWidgets extension: the
// Live Activity's attributes and its button intents must be the same types
// in each (issue #28). Keep this file free of HermesKit/VoiceEngine imports —
// the widget extension does not link the packages.
#if os(iOS)
    import ActivityKit
    import AppIntents
    import Foundation

    /// The lock-screen conversation card's data.
    struct ConversationActivityAttributes: ActivityAttributes {
        struct ContentState: Codable, Hashable {
            /// Raw ConversationStatus (idle/listening/transcribing/thinking/
            /// speaking) — a string so the widget needs no VoiceEngine link.
            var status: String
            var muted: Bool
            var title: String?
        }
    }

    /// Seams the button intents call. The app installs these at launch;
    /// LiveActivityIntent always performs in the app's process, so they are
    /// set whenever a conversation can exist. (In the widget process they
    /// stay nil — perform never runs there.)
    @MainActor
    enum ConversationActivityHooks {
        static var toggleMute: (() -> Void)?
        static var stopSpeech: (() -> Void)?
        static var endConversation: (() -> Void)?
    }

    struct ToggleMuteIntent: LiveActivityIntent {
        static let title: LocalizedStringResource = "Mute or Unmute Microphone"
        static let isDiscoverable = false

        @MainActor
        func perform() async throws -> some IntentResult {
            ConversationActivityHooks.toggleMute?()
            return .result()
        }
    }

    struct StopSpeechIntent: LiveActivityIntent {
        static let title: LocalizedStringResource = "Stop Speaking"
        static let isDiscoverable = false

        @MainActor
        func perform() async throws -> some IntentResult {
            ConversationActivityHooks.stopSpeech?()
            return .result()
        }
    }

    struct EndConversationIntent: LiveActivityIntent {
        static let title: LocalizedStringResource = "End Conversation"
        static let isDiscoverable = false

        @MainActor
        func perform() async throws -> some IntentResult {
            ConversationActivityHooks.endConversation?()
            return .result()
        }
    }
#endif
