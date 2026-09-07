import Foundation
import HermesKit
import Testing
import VoiceEngine

@testable import MercuryVoice

/// Audit finding R27 / issue #79 — the lifetime of a spoken prompt notice.
///
/// `present()` shows the approval/clarify sheet and then hands the spoken
/// notice to an unstructured task that pauses the loop and speaks. Both of
/// those are suspensions, and the reason the notice exists does not survive
/// them: between the sheet going up and the clip coming out the conversation
/// can be ended or superseded (issues #38, #77), the prompt can expire, be
/// answered, be replaced, or be cleared by the post-reconnect prompt read, and
/// playback can be stopped. The task re-checked none of it, and the
/// `playFallback(text:)` convenience it called reads the speech generation at
/// entry — i.e. *after* the pause — so it adopted the bump `end()` had just
/// made and spoke into a conversation that was over.
///
/// Every wait here is a `CallGate` or a task value; nothing sleeps or polls.
/// The barriers are placed at the three points the notice can be caught at:
/// inside the engine pause, inside synthesis, and immediately before the clip
/// plays.
///
/// Serialized, for the same reason `R25ConversationOwnershipTests` is: these
/// tests drive the real `startVoiceLoop`, which takes
/// `ConversationController.levelMeterOwner` and installs a handler on the
/// process-global `AudioCaptureService.shared`. Each test tears its
/// controllers down, which gives both back.
@MainActor
@Suite("R27 prompt-announcement lifetime", .serialized)
struct R27PromptAnnouncementTests {

    static let runtimeID = "rt1"
    static let storedID = "st1"
    static let approvalNotice = "Hermes is asking for approval to run a command."
    static let clarifyNotice = "Hermes has a question for you."

    // MARK: Harness

    /// A conversation with a real engine behind it: `begin()` runs the actual
    /// `openSession` and `startVoiceLoop`, so `engine.setPaused(true)` is a
    /// genuine actor hop and `teardown()` is the real End.
    private func liveConversation(
        service: ScriptedSessionService,
        speech: SequencedSpeech,
        recorder: PausableRecorder,
        pendingApproval: JSONValue? = nil,
        pendingClarify: JSONValue? = nil
    ) async -> ConversationController {
        service.enqueueResume(
            Fixtures.resumeResult(
                runtimeID: Self.runtimeID, storedID: Self.storedID,
                pendingApproval: pendingApproval, pendingClarify: pendingClarify))
        let controller = ConversationController(
            connection: makeUndialedConnection(),
            profile: nil,
            sessionService: service,
            speech: speech,
            audio: ConversationController.AudioStack(
                recorder: recorder,
                bargeMonitor: SilentBargeMonitor(),
                transcriber: SilentTranscriber(),
                microphone: AlwaysGrantedMicrophone()))
        await controller.begin(mode: .resume(storedID: Self.storedID))
        return controller
    }

    private func approvalEvent(seq: Int, requestID: String) -> GatewayEvent {
        Fixtures.event(
            Fixtures.approvalRequest(
                sessionID: Self.runtimeID, seq: seq, command: "rm -rf /tmp/x",
                requestID: requestID))
    }

    private func clarifyEvent(seq: Int, requestID: String) -> GatewayEvent {
        Fixtures.event(
            Fixtures.clarifyRequest(
                sessionID: Self.runtimeID, seq: seq, requestID: requestID,
                question: "Which branch?"))
    }

    // MARK: The pause barrier — End

    /// The conversation ends while the notice is suspended inside the engine
    /// pause. Nothing may be heard afterwards: the sheet is gone, the engine
    /// is dead, and the session is closed.
    @Test("ending the conversation during the pause silences the notice")
    func endDuringThePauseSilencesTheNotice() async {
        let service = ScriptedSessionService()
        let speech = SequencedSpeech()
        let recorder = PausableRecorder()
        let controller = await liveConversation(
            service: service, speech: speech, recorder: recorder)

        let pause = CallGate()
        recorder.parkNextCancel(at: pause)
        controller.handle(event: approvalEvent(seq: 11, requestID: "a1"))
        await pause.waitUntilEntered()

        // End, all the way through: the engine ends and the session closes
        // while the notice is still parked in the pause it asked for.
        await controller.teardown()
        await pause.release()
        await controller.awaitPromptAnnouncements()

        #expect(speech.spoken.isEmpty)
        // Not merely refused at the speaker: an ended conversation never
        // asks for the clip at all.
        #expect(speech.refused.isEmpty)
        #expect(service.closedIDs == [Self.runtimeID])
    }

    /// End → Start. The replacement conversation is already running by the
    /// time the ended one's notice resumes; the user is looking at a new
    /// session and must not hear the old one's approval prompt.
    @Test("a notice from an ended conversation is not heard over the next one")
    func aNoticeFromAnEndedConversationIsNotHeardOverTheNextOne() async {
        let firstService = ScriptedSessionService()
        let firstSpeech = SequencedSpeech()
        let firstRecorder = PausableRecorder()
        let first = await liveConversation(
            service: firstService, speech: firstSpeech, recorder: firstRecorder)

        let pause = CallGate()
        firstRecorder.parkNextCancel(at: pause)
        first.handle(event: approvalEvent(seq: 11, requestID: "a1"))
        await pause.waitUntilEntered()

        await first.teardown()

        // The next conversation is live before the parked notice resumes.
        let secondService = ScriptedSessionService()
        let secondSpeech = SequencedSpeech()
        let secondRecorder = PausableRecorder()
        let second = await liveConversation(
            service: secondService, speech: secondSpeech, recorder: secondRecorder)

        await pause.release()
        await first.awaitPromptAnnouncements()

        #expect(firstSpeech.spoken.isEmpty)
        #expect(firstSpeech.refused.isEmpty)
        #expect(secondSpeech.spoken.isEmpty)
        #expect(second.approval == nil)

        await second.teardown()
    }

    /// The window `supersede()` exists for: a newer launch has taken the
    /// conversation, but the asynchronous `teardown()` behind it has not run
    /// yet, so nothing has cancelled the notice and nothing has stopped
    /// playback. The controller's own dropped-ness is the only fact that says
    /// this notice is dead — which is why it is checked, and not inferred from
    /// cancellation.
    @Test("a superseded controller does not announce, before its teardown runs")
    func aSupersededControllerDoesNotAnnounceBeforeItsTeardownRuns() async {
        let service = ScriptedSessionService()
        let speech = SequencedSpeech()
        let recorder = PausableRecorder()
        let controller = await liveConversation(
            service: service, speech: speech, recorder: recorder)

        let pause = CallGate()
        recorder.parkNextCancel(at: pause)
        controller.handle(event: approvalEvent(seq: 11, requestID: "a1"))
        await pause.waitUntilEntered()

        // Dropped, not yet torn down: the sheet is still set, the epoch has
        // not moved, and the speech generation is untouched.
        controller.supersede()

        await pause.release()
        await controller.awaitPromptAnnouncements()

        #expect(speech.spoken.isEmpty)
        #expect(speech.refused.isEmpty)

        await controller.teardown()
    }

    // MARK: The pause barrier — the prompt itself goes away

    /// The clarify expires while its notice is parked in the pause. The sheet
    /// is already gone and listening has resumed; announcing a question the
    /// user can no longer answer is the audible half of the same staleness.
    @Test("a clarify that expires during the pause is not announced")
    func aClarifyThatExpiresDuringThePauseIsNotAnnounced() async {
        let service = ScriptedSessionService()
        let speech = SequencedSpeech()
        let recorder = PausableRecorder()
        let controller = await liveConversation(
            service: service, speech: speech, recorder: recorder)

        let pause = CallGate()
        recorder.parkNextCancel(at: pause)
        controller.handle(event: clarifyEvent(seq: 11, requestID: "q1"))
        await pause.waitUntilEntered()

        controller.handle(
            event: Fixtures.event(
                Fixtures.clarifyExpire(sessionID: Self.runtimeID, seq: 12, requestID: "q1")))
        #expect(controller.clarify == nil)

        await pause.release()
        await controller.awaitPromptAnnouncements()

        #expect(speech.spoken.isEmpty)
        #expect(speech.refused.isEmpty)

        await controller.teardown()
    }

    /// The reconnect's post-batch prompt read is authoritative: an approval it
    /// does not report was answered elsewhere, expired, or died with the
    /// backend, and `adoptPendingPrompts(clearStale:)` clears the sheet and
    /// bumps the epoch. A notice parked in the pause belongs to that cleared
    /// approval and must go with it.
    @Test("an approval retired by the post-reconnect read is not announced")
    func anApprovalRetiredByTheReconnectReadIsNotAnnounced() async {
        let service = ScriptedSessionService()
        let speech = SequencedSpeech()
        let recorder = PausableRecorder()
        let controller = await liveConversation(
            service: service, speech: speech, recorder: recorder)

        let pause = CallGate()
        recorder.parkNextCancel(at: pause)
        controller.handle(event: approvalEvent(seq: 11, requestID: "a1"))
        await pause.waitUntilEntered()

        // Same runtime id and epoch back, a lossless batch, and a prompt read
        // that reports nothing pending.
        service.enqueueResume(
            Fixtures.resumeResult(runtimeID: Self.runtimeID, storedID: Self.storedID))
        service.enqueueBatch(
            Fixtures.replayBatch([
                Fixtures.messageComplete(sessionID: Self.runtimeID, seq: 12)
            ]))
        service.enqueueActivation(
            Fixtures.activateResult(runtimeID: Self.runtimeID, sessionKey: Self.storedID))
        await controller.connectionBecameReady(isReconnect: true)
        #expect(controller.approval == nil)

        await pause.release()
        await controller.awaitPromptAnnouncements()

        #expect(speech.spoken.isEmpty)
        #expect(speech.refused.isEmpty)

        await controller.teardown()
    }

    /// A second approval replaces the first while the first notice is parked.
    /// Only the prompt on screen is worth announcing, and the notices are the
    /// same words either way — so the count is what distinguishes "announced
    /// the current prompt" from "announced it twice, once for a sheet that no
    /// longer exists".
    @Test("a replaced approval announces only the prompt on screen")
    func aReplacedApprovalAnnouncesOnlyThePromptOnScreen() async {
        let service = ScriptedSessionService()
        let speech = SequencedSpeech()
        let recorder = PausableRecorder()
        let controller = await liveConversation(
            service: service, speech: speech, recorder: recorder)

        let pause = CallGate()
        recorder.parkNextCancel(at: pause)
        controller.handle(event: approvalEvent(seq: 11, requestID: "a1"))
        await pause.waitUntilEntered()

        controller.handle(event: approvalEvent(seq: 12, requestID: "a2"))
        #expect(controller.approval?.requestID == "a2")

        await pause.release()
        await controller.awaitPromptAnnouncements()

        #expect(speech.spoken == [Self.approvalNotice])
        #expect(speech.refused.isEmpty)

        await controller.teardown()
    }

    // MARK: The generation barrier — a Stop inside the pause

    /// Playback is stopped while the notice is parked in the pause. The
    /// generation is the engine's stop protocol, and the notice belongs to the
    /// one that was current when it was queued — the `stopPlayback()` here is
    /// exactly what `stopSpeech()`, a barge-in trip and the start of a new
    /// reply stream each do to it.
    ///
    /// This is the case the `playFallback(text:)` convenience cannot express:
    /// it reads the generation after the pause, so the stop is absorbed as
    /// this clip's own and the notice is played anyway.
    @Test("a stop during the pause silences the notice")
    func aStopDuringThePauseSilencesTheNotice() async {
        let service = ScriptedSessionService()
        let speech = SequencedSpeech()
        let recorder = PausableRecorder()
        let controller = await liveConversation(
            service: service, speech: speech, recorder: recorder)

        let pause = CallGate()
        recorder.parkNextCancel(at: pause)
        controller.handle(event: approvalEvent(seq: 11, requestID: "a1"))
        await pause.waitUntilEntered()

        await speech.stopPlayback()

        await pause.release()
        await controller.awaitPromptAnnouncements()

        // The sheet is still up — this is not staleness, it is a stop.
        #expect(controller.approval?.requestID == "a1")
        #expect(speech.spoken.isEmpty)
        #expect(speech.refused == [Self.approvalNotice])

        await controller.teardown()
    }

    // MARK: The synthesis barrier

    /// Preservation, not a discriminator: this passes before the fix too.
    /// Once synthesis is under way the generation is the only thing left that
    /// can refuse the clip, and `HermesSpeechOutput` re-checks it when the
    /// clip comes back (issue #34). What this pins is that the controller
    /// keeps that contract reachable — it hands `playFallback` a generation to
    /// check rather than one it just read for it.
    ///
    /// Stated limit: a prompt that is answered or expires *during* synthesis
    /// is not caught here. There is no check point inside the synthesis
    /// suspension, and the notice plays. See the report for issue #79.
    @Test("an End during synthesis refuses the clip")
    func anEndDuringSynthesisRefusesTheClip() async {
        let service = ScriptedSessionService()
        let speech = SequencedSpeech()
        let recorder = PausableRecorder()
        let controller = await liveConversation(
            service: service, speech: speech, recorder: recorder)

        let synthesis = CallGate()
        speech.parkSynthesis(at: synthesis)
        controller.handle(event: approvalEvent(seq: 11, requestID: "a1"))
        await synthesis.waitUntilEntered()

        await controller.teardown()
        await synthesis.release()
        await controller.awaitPromptAnnouncements()

        #expect(speech.spoken.isEmpty)
        #expect(speech.refused == [Self.approvalNotice])
    }

    // MARK: The prompt that is actually current

    /// The whole point of the notice: an approval that is still on screen,
    /// in a live conversation, with nothing stopped, is paused for and spoken.
    @Test("the current prompt is paused for and announced")
    func theCurrentPromptIsPausedForAndAnnounced() async {
        let service = ScriptedSessionService()
        let speech = SequencedSpeech()
        let recorder = PausableRecorder()
        let controller = await liveConversation(
            service: service, speech: speech, recorder: recorder)

        let beforePlay = CallGate()
        speech.parkBeforePlay(at: beforePlay)
        controller.handle(event: approvalEvent(seq: 11, requestID: "a1"))

        // The loop is parked before a word is spoken — the mic must not stay
        // armed through the sheet.
        await beforePlay.waitUntilEntered()
        #expect(recorder.cancelCalls == 1)

        await beforePlay.release()
        await controller.awaitPromptAnnouncements()

        #expect(speech.spoken == [Self.approvalNotice])
        #expect(speech.refused.isEmpty)
        #expect(controller.approval?.requestID == "a1")

        await controller.teardown()
    }

    /// The same for the clarify sheet, which announces different words.
    @Test("a current clarify is announced")
    func aCurrentClarifyIsAnnounced() async {
        let service = ScriptedSessionService()
        let speech = SequencedSpeech()
        let recorder = PausableRecorder()
        let controller = await liveConversation(
            service: service, speech: speech, recorder: recorder)

        controller.handle(event: clarifyEvent(seq: 11, requestID: "q1"))
        await controller.awaitPromptAnnouncements()

        #expect(speech.spoken == [Self.clarifyNotice])
        #expect(speech.refused.isEmpty)

        await controller.teardown()
    }

    /// Preservation: the two sheets are independent state and a resume payload
    /// can carry both, so neither notice may retire the other. Ownership is
    /// per sheet for exactly this reason — one shared slot would cancel the
    /// approval notice on its way to speaking the clarify one.
    ///
    /// The two notices race each other onto the speaker, so only the set is
    /// asserted; which is heard first is not a guarantee this code makes, and
    /// did not make before.
    @Test("a payload pending on both sheets announces both")
    func aPayloadPendingOnBothSheetsAnnouncesBoth() async {
        let service = ScriptedSessionService()
        let speech = SequencedSpeech()
        let recorder = PausableRecorder()
        let controller = await liveConversation(
            service: service, speech: speech, recorder: recorder,
            pendingApproval: Fixtures.approvalPayload(command: "ls", requestID: "a1"),
            pendingClarify: Fixtures.clarifyPayload(requestID: "q1", question: "Which?"))

        await controller.awaitPromptAnnouncements()

        #expect(Set(speech.spoken) == [Self.approvalNotice, Self.clarifyNotice])
        #expect(speech.refused.isEmpty)

        await controller.teardown()
    }
}

// MARK: - Doubles

/// A recorder whose next `cancel()` can be parked on demand.
///
/// `setPaused(true)` cancels the recorder before it does anything else, so
/// arming this suspends the announcement task *inside* the engine pause —
/// the first of the two hops between deciding to speak a notice and speaking
/// it. One-shot: the End (or the replacement notice) that follows cancels the
/// recorder again and must not park behind the same gate.
final class PausableRecorder: VoiceRecording, @unchecked Sendable {
    private let lock = NSLock()
    private var _startCalls = 0
    private var _cancelCalls = 0
    private var nextGate: CallGate?

    var startCalls: Int { lock.withLock { _startCalls } }
    var cancelCalls: Int { lock.withLock { _cancelCalls } }

    func parkNextCancel(at gate: CallGate) { lock.withLock { nextGate = gate } }

    func start(vad: VADParameters, onAutoStop: @escaping @Sendable () -> Void) async throws {
        lock.withLock { _startCalls += 1 }
    }

    func stop() async -> RecordedUtterance? { nil }

    func cancel() async {
        let gate: CallGate? = lock.withLock {
            _cancelCalls += 1
            defer { nextGate = nil }
            return nextGate
        }
        await gate?.arrive()
    }
}

/// Speech that records instead of synthesizing, and enforces the
/// `expectedSequence` contract exactly as `HermesSpeechOutput` does: checked
/// at entry, and again when the clip comes back from synthesis (issue #34).
///
/// A refused clip is recorded separately from a spoken one, so a test can tell
/// "never asked for" apart from "asked for and not played".
final class SequencedSpeech: SpeechPlaying, @unchecked Sendable {
    private let lock = NSLock()
    private var _spoken: [String] = []
    private var _refused: [String] = []
    private var _stops = 0
    private var synthesisGate: CallGate?
    private var beforePlayGate: CallGate?

    var spoken: [String] { lock.withLock { _spoken } }
    var refused: [String] { lock.withLock { _refused } }

    /// Park inside the synthesis suspension: past the entry check, with no
    /// clip yet.
    func parkSynthesis(at gate: CallGate) { lock.withLock { synthesisGate = gate } }
    /// Park past both generation checks, with the clip in hand and about to
    /// be audible.
    func parkBeforePlay(at gate: CallGate) { lock.withLock { beforePlayGate = gate } }

    func startStream() async -> (any SpeechStreaming)? { nil }

    func playFallback(text: String, expectedSequence: Int) async -> Bool {
        guard accept(text, at: expectedSequence) else { return false }
        await lock.withLock { synthesisGate }?.arrive()
        guard accept(text, at: expectedSequence) else { return false }
        await lock.withLock { beforePlayGate }?.arrive()
        lock.withLock { _spoken.append(text) }
        return true
    }

    /// True while `expected` is still the current generation; records the
    /// refusal otherwise.
    private func accept(_ text: String, at expected: Int) -> Bool {
        lock.withLock {
            guard _stops != expected else { return true }
            _refused.append(text)
            return false
        }
    }

    func stopPlayback() async { lock.withLock { _stops += 1 } }

    var sequence: Int {
        get async { lock.withLock { _stops } }
    }
    var isSpeaking: Bool {
        get async { false }
    }
}
