import Foundation
import Testing

@testable import VoiceEngine

/// The explicit microphone-permission step that runs before the first mic
/// arm (issue #23 §1.4): denial parks the engine in a dedicated, recoverable
/// state instead of surfacing as a raw audio-engine error.
@Suite("Microphone authorization")
struct MicrophoneAuthorizationTests {
    struct Harness {
        let engine: ConversationEngine<TestClock>
        let recorder = FakeRecorder()
        let microphone: FakeMicrophoneAuthorizer
        let denials = ConversationEngineTests.Harness.CountBox()
        let fatals = ConversationEngineTests.Harness.CountBox()

        init(authorization: MicrophoneAuthorization) {
            let microphone = FakeMicrophoneAuthorizer(authorization)
            self.microphone = microphone
            engine = ConversationEngine(
                recorder: recorder,
                bargeMonitor: FakeBargeMonitor(),
                transcriber: FakeTranscriber(),
                speech: FakeSpeech(),
                agent: FakeAgent(),
                microphone: microphone,
                callbacks: ConversationCallbacks(
                    onFatalError: { [fatals] _ in fatals.bump() },
                    onMicrophoneDenied: { [denials] in denials.bump() }),
                clock: TestClock())
        }
    }

    @Test func grantedPermissionArmsTheMic() async {
        let h = Harness(authorization: .granted)
        await h.engine.start()
        #expect(await h.engine.status == .listening)
        #expect(h.recorder.startCount == 1)
        #expect(h.microphone.requestCount == 1)
        #expect(await h.engine.uiState.microphoneDenied == false)
    }

    @Test func deniedPermissionParksWithoutTouchingTheRecorder() async {
        let h = Harness(authorization: .denied)
        await h.engine.start()
        let state = await h.engine.uiState
        #expect(state.microphoneDenied)
        #expect(state.status == .idle)
        #expect(state.enabled == false)
        #expect(h.recorder.startCount == 0)
        #expect(h.denials.count == 1)
        // Dedicated state, not the generic fatal alert.
        #expect(h.fatals.count == 0)
    }

    @Test func deniedEngineIgnoresListenNowUntilRestarted() async {
        let h = Harness(authorization: .denied)
        await h.engine.start()
        await h.engine.listenNow()
        #expect(h.recorder.startCount == 0)
        #expect(h.microphone.requestCount == 1)
    }

    @Test func restartAfterGrantClearsTheDeniedState() async {
        let h = Harness(authorization: .denied)
        await h.engine.start()
        #expect(await h.engine.uiState.microphoneDenied)

        h.microphone.authorization = .granted
        await h.engine.start()
        #expect(await h.engine.status == .listening)
        #expect(await h.engine.uiState.microphoneDenied == false)
        #expect(h.recorder.startCount == 1)
    }

    @Test func restartWhileStillDeniedStaysDenied() async {
        let h = Harness(authorization: .denied)
        await h.engine.start()
        await h.engine.start()
        #expect(await h.engine.uiState.microphoneDenied)
        #expect(h.denials.count == 2)
        #expect(h.recorder.startCount == 0)
    }

    @Test func permissionIsCheckedOnEveryArmNotJustTheFirst() async {
        // Revoked mid-conversation (macOS Settings toggle): the next re-arm
        // must land in the denied state rather than an audio-engine error.
        let h = Harness(authorization: .granted)
        await h.engine.start()
        #expect(await h.engine.status == .listening)
        await h.engine.stopSpeech()  // back to idle without ending
        h.microphone.authorization = .denied
        await h.engine.listenNow()
        #expect(await h.engine.uiState.microphoneDenied)
        #expect(h.recorder.startCount == 1)
    }

    @Test func defaultAuthorizerIsGranted() async {
        // Existing callers (and every other test) construct the engine
        // without an authorizer; they must keep arming the mic.
        let recorder = FakeRecorder()
        let engine = ConversationEngine(
            recorder: recorder, bargeMonitor: FakeBargeMonitor(),
            transcriber: FakeTranscriber(), speech: FakeSpeech(), agent: FakeAgent(),
            clock: TestClock())
        await engine.start()
        #expect(recorder.startCount == 1)
    }
}
