import Foundation
import Testing

@testable import VoiceEngine

/// Issue #146 item 5: an in-app "Interrupt by speaking" switch. Upstream's
/// desktop honours the backend's `voice.barge_in`, but the only way to read
/// it is the whole profile config (keys included), so the app keeps its own
/// switch instead — on by default, like `voice.barge_in`.
@Suite("Barge-in preference")
struct BargeInPreferenceTests {
    private func isolatedDefaults() -> UserDefaults {
        let suiteName = "BargeInPreferenceTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }

    @Test func onByDefault() {
        #expect(BargeInPreference.isEnabled(in: isolatedDefaults()))
    }

    @Test func anExplicitOffSticks() {
        let defaults = isolatedDefaults()
        defaults.set(false, forKey: BargeInPreference.key)
        #expect(!BargeInPreference.isEnabled(in: defaults))
        defaults.set(true, forKey: BargeInPreference.key)
        #expect(BargeInPreference.isEnabled(in: defaults))
    }
}

@Suite("Barge-in switch in the engine")
struct BargeInSwitchEngineTests {
    @Test func offMeansTheMonitorNeverArms() async {
        let h = ConversationEngineTests.Harness(bargeInEnabled: { false })
        await h.enterThinking()
        // The thinking phase is where the monitor normally arms.
        h.agent.setPending(PendingSpeech(id: "0", text: "A reply long enough.", pending: true))
        await h.engine.agentStateChanged()
        #expect(await h.status(is: .speaking))
        try? await Task.sleep(for: .milliseconds(100))
        #expect(h.barge.startCount == 0)
    }

    @Test func onArmsItAsBefore() async {
        let h = ConversationEngineTests.Harness(bargeInEnabled: { true })
        await h.enterThinking()
        #expect(await eventually { h.barge.startCount >= 1 })
    }
}
