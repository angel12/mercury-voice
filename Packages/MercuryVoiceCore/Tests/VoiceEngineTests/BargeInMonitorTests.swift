import Foundation
import Testing

@testable import VoiceEngine

@Suite("Barge mute capture policy")
struct BargeMutePolicyTests {
    @Test func detachesOnlyOnIOS() {
        #expect(shouldDetachBargeCaptureWhileMuted(isIOS: true))
        #expect(!shouldDetachBargeCaptureWhileMuted(isIOS: false))
    }
}

@Suite("BargeInMonitor suspend capture")
struct BargeInMonitorSuspendTests {
    @Test func setSuspendedClosesCaptureWhenDetachPolicyIsOn() async throws {
        let capture = FakeAudioCapture()
        let monitor = BargeInMonitor(capture: capture, detachCaptureOnSuspend: true)
        try await monitor.start(
            isPlaying: { false }, onSpeech: {}, onUtterance: { _ in })
        #expect(capture.activeCount == 1)

        await monitor.setSuspended(true)
        #expect(capture.streamClosed)
        #expect(capture.activeCount == 0)
        #expect(capture.closeCount == 1)
    }

    @Test func setSuspendedKeepsCaptureAttachedWhenDetachPolicyIsOff() async throws {
        let capture = FakeAudioCapture()
        let monitor = BargeInMonitor(capture: capture, detachCaptureOnSuspend: false)
        try await monitor.start(
            isPlaying: { false }, onSpeech: {}, onUtterance: { _ in })
        #expect(capture.activeCount == 1)

        await monitor.setSuspended(true)
        #expect(!capture.streamClosed)
        #expect(capture.activeCount == 1)
        #expect(capture.closeCount == 0)
    }
}
