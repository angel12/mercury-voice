import Testing

/// Only tests that reach `startVoiceLoop` share this serialized parent.
/// Separate `.serialized` suites do NOT exclude each other. Keep the real
/// process-global meter in these fixtures: injecting another capture service
/// does not isolate `ConversationController.levelMeterOwner`.
///
/// New tests that successfully call `begin`, `startConversation`, or
/// `continueSession` must join this parent and finish their owned teardown.
/// Tests that only call `openSession` do not install the meter and stay parallel.
@MainActor
@Suite("Process-global level meter", .serialized, .timeLimit(.minutes(1)))
struct SharedMeterTests {
    @MainActor
    @Suite("Conversation ownership (R25)")
    struct R25ConversationOwnershipTests {}

    @MainActor
    @Suite("R27 prompt-announcement lifetime")
    struct R27PromptAnnouncementTests {}

    @MainActor
    @Suite("Nonblocking browse refresh with voice (R26)")
    struct R26VoiceStartBrowsePumpTests {}
}
