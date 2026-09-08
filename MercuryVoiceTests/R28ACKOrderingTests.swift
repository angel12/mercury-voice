import HermesKit
import Testing

@testable import MercuryVoice

@Suite(.timeLimit(.minutes(1)))
@MainActor
struct R28ACKOrderingTests {
    @Test(arguments: [false, true])
    func earlyAssistantEventsPreservePromptOrder(completeBeforeACK: Bool) async throws {
        let service = ScriptedSessionService()
        service.enqueueCreate(Fixtures.resumeResult(runtimeID: "runtime", storedID: "stored"))
        let gate = CallGate()
        let controller = ConversationController(
            connection: makeUndialedConnection(), profile: nil,
            sessionService: service, speech: RecordingSpeech(),
            submitPrompt: { _, _, _ in await gate.arrive() })
        try await controller.openSession(mode: .create(cwd: nil, title: nil))
        controller.textDraft = "question"
        DevChatView(controller: controller).send()
        await gate.waitUntilEntered()
        controller.handle(
            event: Fixtures.event(
                Fixtures.eventParams(
                    type: GatewayEvent.Kind.messageStart, sessionID: "runtime", seq: 1)))
        controller.handle(
            event: Fixtures.event(
                Fixtures.eventParams(
                    type: GatewayEvent.Kind.messageDelta, sessionID: "runtime", seq: 2,
                    payload: .object(["text": .string("early ")]))))
        if completeBeforeACK {
            controller.handle(
                event: Fixtures.event(
                    Fixtures.messageComplete(
                        sessionID: "runtime", seq: 3, text: "early answer")))
        }
        #expect(controller.devMessages.filter { $0.role == "user" }.isEmpty)
        await gate.release()
        await controller.textSubmissionTask?.value
        if !completeBeforeACK {
            controller.handle(
                event: Fixtures.event(
                    Fixtures.eventParams(
                        type: GatewayEvent.Kind.messageDelta, sessionID: "runtime", seq: 3,
                        payload: .object(["text": .string("answer")]))))
            controller.handle(
                event: Fixtures.event(
                    Fixtures.messageComplete(
                        sessionID: "runtime", seq: 4, text: "early answer")))
        }
        #expect(controller.devMessages.map(\.role) == ["user", "assistant"])
        #expect(controller.devMessages.map(\.text) == ["question", "early answer"])
        #expect(controller.pendingText == nil)
        #expect(controller.failedText == nil)
        #expect(controller.textDraft.isEmpty)
        await controller.teardown()
    }

    // Preservation controls: exercise the same reconciliation with a retained
    // history boundary and with that boundary evicted by the transcript cap.
    @Test(arguments: [1, 100])
    func earlyCompletionsRespectBoundedHistory(completionCount: Int) async throws {
        let service = ScriptedSessionService()
        service.enqueueCreate(Fixtures.resumeResult(runtimeID: "runtime", storedID: "stored"))
        let gate = CallGate()
        let controller = ConversationController(
            connection: makeUndialedConnection(), profile: nil,
            sessionService: service, speech: RecordingSpeech(),
            submitPrompt: { _, _, _ in await gate.arrive() })
        try await controller.openSession(mode: .create(cwd: nil, title: nil))
        let history = (1...100).map { "history \($0)" }
        for (index, text) in history.enumerated() {
            controller.handle(
                event: Fixtures.event(
                    Fixtures.messageComplete(
                        sessionID: "runtime", seq: index + 1, text: text)))
        }
        controller.textDraft = "question"
        DevChatView(controller: controller).send()
        await gate.waitUntilEntered()
        let answers = (1...completionCount).map { "answer \($0)" }
        for (index, text) in answers.enumerated() {
            controller.handle(
                event: Fixtures.event(
                    Fixtures.messageComplete(
                        sessionID: "runtime", seq: index + 101, text: text)))
        }
        #expect(controller.pendingText == "question")
        #expect(controller.devMessages.allSatisfy { $0.role == "assistant" })
        await gate.release()
        await controller.textSubmissionTask?.value
        #expect(
            controller.devMessages.map(\.text)
                == Array((history + ["question"] + answers).suffix(100)))
        #expect(controller.pendingText == nil)
        #expect(controller.failedText == nil)
        await controller.teardown()
    }

    @Test func explicitRetryUsesItsOwnBoundaryAfterUncertainEarlyAnswer() async throws {
        let service = ScriptedSessionService()
        service.enqueueCreate(Fixtures.resumeResult(runtimeID: "runtime", storedID: "stored"))
        let firstGate = CallGate()
        let retryGate = CallGate()
        let calls = ACKSubmissionCalls()
        let controller = ConversationController(
            connection: makeUndialedConnection(), profile: nil,
            sessionService: service, speech: RecordingSpeech(),
            submitPrompt: { _, text, _ in
                let attempt = await calls.record(text)
                if attempt == 1 {
                    await firstGate.arrive()
                    throw HermesError.connectionClosed("secret")
                }
                await retryGate.arrive()
            })
        try await controller.openSession(mode: .create(cwd: nil, title: nil))
        controller.textDraft = "question"
        DevChatView(controller: controller).send()
        await firstGate.waitUntilEntered()
        controller.handle(
            event: Fixtures.event(
                Fixtures.messageComplete(
                    sessionID: "runtime", seq: 1, text: "uncertain answer")))
        await firstGate.release()
        await controller.textSubmissionTask?.value
        #expect(controller.devMessages.map(\.text) == ["uncertain answer"])
        #expect(controller.failedText == "question")
        #expect(controller.textSubmissionError?.contains("may send this message twice") == true)
        #expect(await calls.texts == ["question"])
        controller.textDraft = "edited draft"
        controller.submitTextPrompt(try #require(controller.failedText))
        await retryGate.waitUntilEntered()
        controller.handle(
            event: Fixtures.event(
                Fixtures.messageComplete(
                    sessionID: "runtime", seq: 2, text: "retry answer")))
        DevChatView(controller: controller).send()
        #expect(controller.pendingText == "question")
        #expect(controller.devMessages.map(\.role) == ["assistant", "assistant"])
        await retryGate.release()
        await controller.textSubmissionTask?.value
        #expect(await calls.texts == ["question", "question"])
        #expect(
            controller.devMessages.map(\.text) == ["uncertain answer", "question", "retry answer"])
        #expect(controller.devMessages.map(\.role) == ["assistant", "user", "assistant"])
        #expect(controller.pendingText == nil)
        #expect(controller.failedText == nil)
        #expect(controller.textSubmissionError == nil)
        #expect(controller.textDraft == "edited draft")
        await controller.teardown()
    }

    @Test func earlyCompletionThenFailureDoesNotInventSentUser() async throws {
        let service = ScriptedSessionService()
        service.enqueueCreate(Fixtures.resumeResult(runtimeID: "runtime", storedID: "stored"))
        let gate = CallGate()
        let controller = ConversationController(
            connection: makeUndialedConnection(), profile: nil,
            sessionService: service, speech: RecordingSpeech(),
            submitPrompt: { _, _, _ in
                await gate.arrive()
                throw HermesError.connectionClosed("secret")
            })
        try await controller.openSession(mode: .create(cwd: nil, title: nil))
        controller.textDraft = "uncertain"
        DevChatView(controller: controller).send()
        await gate.waitUntilEntered()
        controller.handle(
            event: Fixtures.event(
                Fixtures.messageComplete(
                    sessionID: "runtime", seq: 1, text: "accepted remotely")))
        await gate.release()
        await controller.textSubmissionTask?.value
        #expect(controller.devMessages.map(\.role) == ["assistant"])
        #expect(controller.failedText == "uncertain")
        #expect(controller.textDraft == "uncertain")
        #expect(controller.textSubmissionError?.contains("may send this message twice") == true)
        await controller.teardown()
    }
}

private actor ACKSubmissionCalls {
    private(set) var texts: [String] = []

    func record(_ text: String) -> Int {
        texts.append(text)
        return texts.count
    }
}
