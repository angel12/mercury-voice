import HermesKit
import Testing

@testable import MercuryVoice

@Suite(.timeLimit(.minutes(1)))
@MainActor
struct R28TextSubmissionTests {
    @Test func failedSubmissionRetainsTextAndSurfacesSafeError() async throws {
        let service = ScriptedSessionService()
        service.enqueueCreate(Fixtures.resumeResult(runtimeID: "runtime", storedID: "stored"))
        let gate = CallGate()
        let controller = ConversationController(
            connection: makeUndialedConnection(), profile: nil,
            sessionService: service, speech: RecordingSpeech(),
            submitPrompt: { _, _, _ in
                await gate.arrive()
                throw HermesError.connectionClosed("secret-token")
            })
        try await controller.openSession(mode: .create(cwd: nil, title: nil))
        controller.textDraft = " keep this message "
        controller.submitTextPrompt(controller.textDraft)
        await gate.waitUntilEntered()
        #expect(controller.pendingText == "keep this message")
        #expect(controller.textDraft == " keep this message ")
        await gate.release()
        await controller.textSubmissionTask?.value
        #expect(controller.pendingText == nil)
        #expect(controller.failedText == "keep this message")
        #expect(controller.textSubmissionError != nil)
        #expect(controller.textSubmissionError?.contains("secret-token") != true)
        #expect(controller.devMessages.isEmpty)
        let uncertainError = controller.textSubmissionError
        controller.connectionLost()
        controller.submitTextPrompt("keep this message")
        #expect(controller.textSubmissionError == uncertainError)
        await controller.teardown()
    }

    @Test func explicitRetrySendsOnceAndClearsOnlyTheAcknowledgedDraft() async throws {
        let service = ScriptedSessionService()
        service.enqueueCreate(Fixtures.resumeResult(runtimeID: "runtime", storedID: "stored"))
        let submission = TextSubmissionScript()
        let controller = ConversationController(
            connection: makeUndialedConnection(), profile: nil,
            sessionService: service, speech: RecordingSpeech(),
            submitPrompt: { sid, text, interrupted in
                try await submission.submit(sid, text, interrupted)
            })
        try await controller.openSession(mode: .create(cwd: nil, title: nil))
        controller.textDraft = " retry me "
        controller.submitTextPrompt(controller.textDraft)
        await controller.textSubmissionTask?.value
        #expect(controller.failedText == "retry me")
        #expect(await submission.texts == ["retry me"])
        controller.submitTextPrompt(controller.failedText ?? "missing")
        await controller.textSubmissionTask?.value
        #expect(await submission.texts == ["retry me", "retry me"])
        #expect(controller.devMessages.map(\.text) == ["retry me"])
        #expect(controller.failedText == nil)
        #expect(controller.textSubmissionError == nil)
        #expect(controller.textDraft.isEmpty)
        await controller.teardown()
    }

    @Test func overlapIsRejectedWithoutReplacingPendingTextOrEditedDraft() async throws {
        let service = ScriptedSessionService()
        service.enqueueCreate(Fixtures.resumeResult(runtimeID: "runtime", storedID: "stored"))
        let gate = CallGate()
        let calls = TextSubmissionCalls()
        let controller = ConversationController(
            connection: makeUndialedConnection(), profile: nil,
            sessionService: service, speech: RecordingSpeech(),
            submitPrompt: { _, text, _ in
                await calls.record(text)
                await gate.arrive()
            })
        try await controller.openSession(mode: .create(cwd: nil, title: nil))
        controller.textDraft = "first"
        controller.submitTextPrompt(controller.textDraft)
        let firstTask = controller.textSubmissionTask
        await gate.waitUntilEntered()
        controller.textDraft = "new draft"
        controller.submitTextPrompt(controller.textDraft)
        #expect(controller.pendingText == "first")
        await gate.release()
        await firstTask?.value
        await controller.textSubmissionTask?.value
        #expect(await calls.texts == ["first"])
        #expect(controller.devMessages.map(\.text) == ["first"])
        #expect(controller.textDraft == "new draft")
        await controller.teardown()
    }

    @Test(arguments: [false, true], [false, true])
    func endedSubmissionCannotPublishLateCompletion(fails: Bool, supersedeOnly: Bool) async throws {
        let service = ScriptedSessionService()
        service.enqueueCreate(Fixtures.resumeResult(runtimeID: "runtime", storedID: "stored"))
        let gate = CallGate()
        let calls = TextSubmissionCalls()
        let controller = ConversationController(
            connection: makeUndialedConnection(), profile: nil,
            sessionService: service, speech: RecordingSpeech(),
            submitPrompt: { _, text, _ in
                await calls.record(text)
                await gate.arrive()
                if fails { throw HermesError.notConnected }
            })
        try await controller.openSession(mode: .create(cwd: nil, title: nil))
        controller.textDraft = "abandoned"
        controller.submitTextPrompt(controller.textDraft)
        let oldTask = controller.textSubmissionTask
        await gate.waitUntilEntered()
        if supersedeOnly { controller.supersede() } else { await controller.teardown() }
        await gate.release()
        await oldTask?.value
        #expect(controller.devMessages.isEmpty)
        #expect(controller.failedText == nil)
        #expect(controller.pendingText == nil)
        #expect(controller.textSubmissionError == nil)
        #expect(controller.textDraft == "abandoned")
        controller.submitTextPrompt("too late")
        await controller.textSubmissionTask?.value
        #expect(await calls.texts == ["abandoned"])
        await controller.teardown()
    }

    @Test func knownRefusalIsSafeAndDistinguishedFromUncertainDelivery() async throws {
        let service = ScriptedSessionService()
        service.enqueueCreate(Fixtures.resumeResult(runtimeID: "runtime", storedID: "stored"))
        let controller = ConversationController(
            connection: makeUndialedConnection(), profile: nil,
            sessionService: service, speech: RecordingSpeech(),
            submitPrompt: { _, _, _ in
                throw HermesError.rpcError(
                    code: HermesError.RPCCode.sessionSlotRefused, message: "secret-token",
                    data: ["reason": .string(HermesError.RefusalReason.sessionNotOwned)])
            })
        try await controller.openSession(mode: .create(cwd: nil, title: nil))
        controller.submitTextPrompt("refused")
        await controller.textSubmissionTask?.value
        #expect(controller.failedText == "refused")
        #expect(controller.textSubmissionError?.contains("Another app") == true)
        #expect(controller.textSubmissionError?.contains("secret-token") == false)
        await controller.teardown()
    }

    @Test func shippingSendActionRetainsDraftOnFailure() async {
        let controller = makeController(service: ScriptedSessionService())
        controller.textDraft = "view draft"
        let view = DevChatView(controller: controller)
        view.send()
        #expect(controller.pendingText == "view draft")
        #expect(controller.textDraft == "view draft")
        await controller.textSubmissionTask?.value
        #expect(controller.failedText == "view draft")
        #expect(controller.textDraft == "view draft")
        await controller.teardown()
    }

    @Test func newSendCannotDiscardUnresolvedFailedText() async {
        let controller = makeController(service: ScriptedSessionService())
        controller.submitTextPrompt("failed original")
        await controller.textSubmissionTask?.value
        controller.textDraft = "different draft"
        controller.submitTextPrompt(controller.textDraft)
        await controller.textSubmissionTask?.value
        #expect(controller.failedText == "failed original")
        #expect(controller.textDraft == "different draft")
        await controller.teardown()
    }

    @Test func dismissFailurePreservesDraftAndAllowsNewSend() async {
        let controller = makeController(service: ScriptedSessionService())
        controller.submitTextPrompt("old failure")
        await controller.textSubmissionTask?.value
        controller.textDraft = "new draft"
        controller.dismissFailedText()
        #expect(controller.failedText == nil)
        #expect(controller.textSubmissionError == nil)
        #expect(controller.textDraft == "new draft")
        DevChatView(controller: controller).send()
        #expect(controller.pendingText == "new draft")
        controller.dismissFailedText()
        #expect(controller.pendingText == "new draft")
        await controller.textSubmissionTask?.value
        #expect(controller.failedText == "new draft")
        await controller.teardown()
    }

    @Test func disconnectedSendWaitsForExplicitRetryAfterReconnect() async throws {
        let service = ScriptedSessionService()
        service.enqueueCreate(Fixtures.resumeResult(runtimeID: "runtime", storedID: "stored"))
        let calls = TextSubmissionCalls()
        let controller = ConversationController(
            connection: makeUndialedConnection(), profile: nil,
            sessionService: service, speech: RecordingSpeech(),
            submitPrompt: { _, text, _ in await calls.record(text) })
        try await controller.openSession(mode: .create(cwd: nil, title: nil))
        controller.connectionLost()
        controller.textDraft = "offline draft"
        controller.submitTextPrompt(controller.textDraft)
        await controller.textSubmissionTask?.value
        #expect(await calls.texts.isEmpty)
        #expect(controller.failedText == "offline draft")
        #expect(controller.textSubmissionError?.contains("Not connected") == true)
        await controller.connectionBecameReady(isReconnect: false)
        #expect(await calls.texts.isEmpty)
        controller.submitTextPrompt("offline draft")
        await controller.textSubmissionTask?.value
        #expect(await calls.texts == ["offline draft"])
        #expect(controller.textDraft.isEmpty)
        await controller.teardown()
    }

    @Test func unacknowledgedTextIsNotASentBubble() async {
        let controller = makeController(service: ScriptedSessionService())
        controller.submitTextPrompt("keep this message")
        #expect(controller.devMessages.isEmpty)
        await controller.teardown()
    }
}

private actor TextSubmissionCalls {
    private(set) var texts: [String] = []
    func record(_ text: String) { texts.append(text) }
}

private actor TextSubmissionScript {
    private(set) var texts: [String] = []

    func submit(_ sessionID: String, _ text: String, _ interrupted: Bool) throws {
        #expect(sessionID == "runtime")
        #expect(!interrupted)
        texts.append(text)
        if texts.count == 1 {
            throw HermesError.notConnected
        }
    }
}
