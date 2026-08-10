#if os(iOS)
    @preconcurrency import ActivityKit
    import SwiftUI
    import VoiceEngine

    /// Mirrors the live conversation onto the lock screen as a Live
    /// Activity (issue #28): started when a conversation begins, updated on
    /// every voice-state change, ended with the conversation. Updates are
    /// funneled through one serial task chain so out-of-order awaits can't
    /// publish a stale state last.
    @MainActor
    @Observable
    final class ConversationActivityController {
        private var activity: Activity<ConversationActivityAttributes>?
        private var pump: Task<Void, Never> = Task {}

        struct Snapshot: Equatable {
            var state: ConversationUIState
            var title: String?
        }

        func apply(_ snapshot: Snapshot?) {
            guard let snapshot else {
                endActivity()
                return
            }
            let content = ConversationActivityAttributes.ContentState(
                status: snapshot.state.status.rawValue,
                muted: snapshot.state.muted,
                title: snapshot.title)
            if let activity {
                chain { await activity.update(ActivityContent(state: content, staleDate: nil)) }
            } else {
                // Ends any card a killed process left behind before starting
                // fresh — those orphans have dead buttons.
                for orphan in Activity<ConversationActivityAttributes>.activities {
                    chain { await orphan.end(nil, dismissalPolicy: .immediate) }
                }
                activity = try? Activity.request(
                    attributes: ConversationActivityAttributes(),
                    content: ActivityContent(state: content, staleDate: nil))
            }
        }

        private func endActivity() {
            guard let activity else { return }
            self.activity = nil
            chain { await activity.end(nil, dismissalPolicy: .immediate) }
        }

        private func chain(_ operation: @escaping @MainActor () async -> Void) {
            let previous = pump
            pump = Task { @MainActor in
                await previous.value
                await operation()
            }
        }
    }

    /// Drives the controller from RootView: watches the conversation's
    /// UI state and title, and the conversation's presence itself.
    struct ConversationLiveActivityModifier: ViewModifier {
        let model: AppModel
        @State private var controller = ConversationActivityController()

        private var snapshot: ConversationActivityController.Snapshot? {
            model.conversation.map {
                .init(state: $0.voiceState, title: $0.sessionTitle)
            }
        }

        func body(content: Content) -> some View {
            content.onChange(of: snapshot, initial: true) { _, new in
                controller.apply(new)
            }
        }
    }

    extension ConversationActivityHooks {
        /// Wire the Live Activity buttons to the shared model. Called from
        /// AppModel's init, so the hooks exist before any intent can run.
        static func install(model: AppModel) {
            toggleMute = { [weak model] in model?.conversation?.toggleMute() }
            stopSpeech = { [weak model] in model?.conversation?.stopSpeech() }
            endConversation = { [weak model] in model?.endConversation() }
        }
    }
#endif
