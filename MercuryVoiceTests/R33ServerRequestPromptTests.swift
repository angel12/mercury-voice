import Foundation
import HermesKit
import Testing

@testable import MercuryVoice

/// Issue #125 — contract-7 prompts arrive as server→client requests.
///
/// A contract ≥ 7 backend no longer emits `approval.request` /
/// `clarify.request` notifications for the app to answer with
/// `approval.respond` / `clarify.respond`: it sends an `srq-<hex>` JSON-RPC
/// request, withdraws it with `request.cancel {id}`, restores it on reconnect
/// through `open_requests`, and takes the answer through `request.answer`.
/// These tests pin the controller half of that — the sheet each source puts
/// up, which RPC answers it, and that the contract-6 paths still work.
@MainActor
@Suite("R33 contract-7 server-request prompts", .timeLimit(.minutes(1)))
struct R33ServerRequestPromptTests {

    static let runtimeID = "rt1"
    static let storedID = "st1"
    static let watermark = 10
    static let approvalNotice = "Hermes is asking for approval to run a command."
    static let clarifyNotice = "Hermes has a question for you."

    // MARK: Harness

    /// A controller with a live session open at `watermark`.
    private func openedController(
        service: ScriptedSessionService,
        speech: RecordingSpeech = RecordingSpeech(),
        pendingApproval: JSONValue? = nil,
        openRequests: [JSONValue]? = nil
    ) async throws -> ConversationController {
        service.enqueueResume(
            Fixtures.resumeResult(
                runtimeID: Self.runtimeID, storedID: Self.storedID,
                pendingApproval: pendingApproval, openRequests: openRequests))
        let controller = makeController(service: service, speech: speech)
        try await controller.openSession(mode: .resume(storedID: Self.storedID))
        controller.handle(
            event: Fixtures.event(
                Fixtures.messageComplete(sessionID: Self.runtimeID, seq: Self.watermark)))
        return controller
    }

    /// A reconnect whose replay is usable (empty batch), so the post-batch
    /// `session.activate` read decides the sheets.
    private func reconnect(
        _ controller: ConversationController,
        service: ScriptedSessionService,
        pendingApproval: JSONValue? = nil,
        openRequests: [JSONValue]? = nil
    ) async {
        service.enqueueResume(
            Fixtures.resumeResult(runtimeID: Self.runtimeID, storedID: Self.storedID))
        service.enqueueBatch(Fixtures.replayBatch([], latestSeq: Self.watermark))
        service.enqueueActivation(
            Fixtures.activateResult(
                runtimeID: Self.runtimeID, sessionKey: Self.storedID,
                pendingApproval: pendingApproval, openRequests: openRequests))
        await controller.connectionBecameReady(isReconnect: true)
    }

    private func srqApproval(id: String = "srq-a1", requestID: String = "a1") -> JSONValue {
        Fixtures.approvalServerRequest(
            id: id, sessionID: Self.runtimeID, command: "rm -rf /tmp/x", requestID: requestID)
    }

    private func srqClarify(id: String = "srq-q1") -> JSONValue {
        Fixtures.clarifyServerRequest(id: id, sessionID: Self.runtimeID, question: "Which branch?")
    }

    private func answerParams(id: String, _ result: [String: JSONValue]) -> JSONValue {
        .object(["id": .string(id), "result": .object(result)])
    }

    // MARK: Presenting

    @Test("an srq approval presents the sheet and announces it once")
    func srqApprovalPresentsAndAnnouncesOnce() async throws {
        let service = ScriptedSessionService()
        let speech = RecordingSpeech()
        let controller = try await openedController(service: service, speech: speech)

        controller.handle(event: Fixtures.serverRequestEvent(srqApproval()))
        // The same approval also arriving as a live legacy frame (same
        // gateway request_id) is not a second prompt.
        controller.handle(
            event: Fixtures.event(
                Fixtures.approvalRequest(
                    sessionID: Self.runtimeID, seq: 11, command: "rm -rf /tmp/x",
                    requestID: "a1")))
        await controller.awaitPromptAnnouncements()

        #expect(controller.approval?.command == "rm -rf /tmp/x")
        #expect(controller.approval?.serverRequestID == "srq-a1")
        #expect(speech.spoken == [Self.approvalNotice])
        await controller.teardown()
    }

    @Test("an srq clarify presents the sheet")
    func srqClarifyPresents() async throws {
        let service = ScriptedSessionService()
        let speech = RecordingSpeech()
        let controller = try await openedController(service: service, speech: speech)

        controller.handle(event: Fixtures.serverRequestEvent(srqClarify()))
        await controller.awaitPromptAnnouncements()

        #expect(controller.clarify?.question == "Which branch?")
        #expect(controller.clarify?.serverRequestID == "srq-q1")
        #expect(speech.spoken == [Self.clarifyNotice])
        await controller.teardown()
    }

    // MARK: Answering

    @Test("answering an srq approval sends request.answer and closes on the reply")
    func answeringAnSrqApprovalSendsRequestAnswer() async throws {
        let service = ScriptedSessionService()
        let controller = try await openedController(service: service)
        controller.handle(event: Fixtures.serverRequestEvent(srqApproval()))
        try #require(controller.approval != nil)

        let gate = CallGate()
        service.promptResponseGate = gate
        controller.respondApproval(choice: "once")
        await gate.waitUntilEntered()
        // The backend is still blocked until the reply lands.
        #expect(controller.approval != nil)
        await gate.release()
        await controller.awaitPromptResponse()

        #expect(
            service.promptResponses == [
                .requestAnswer(params: answerParams(id: "srq-a1", ["choice": .string("once")]))
            ])
        #expect(controller.approval == nil)
        #expect(controller.promptSendError == nil)
        await controller.teardown()
    }

    @Test("an expired request.answer reply still closes the sheet")
    func expiredReplyClosesTheSheet() async throws {
        let service = ScriptedSessionService()
        let controller = try await openedController(service: service)
        controller.handle(event: Fixtures.serverRequestEvent(srqApproval()))
        try #require(controller.approval != nil)
        service.enqueueAnswerReply(.expired)

        controller.respondApproval(choice: "deny")
        await controller.awaitPromptResponse()

        #expect(controller.approval == nil)
        #expect(controller.promptSendError == nil)
        await controller.teardown()
    }

    @Test("answering an srq clarify sends request.answer with the answer")
    func answeringAnSrqClarifySendsRequestAnswer() async throws {
        let service = ScriptedSessionService()
        let controller = try await openedController(service: service)
        controller.handle(event: Fixtures.serverRequestEvent(srqClarify()))

        controller.respondClarify(answer: "main")
        await controller.awaitPromptResponse()

        #expect(
            service.promptResponses == [
                .requestAnswer(params: answerParams(id: "srq-q1", ["answer": .string("main")]))
            ])
        #expect(controller.clarify == nil)
        await controller.teardown()
    }

    @Test("a failed request.answer keeps the sheet up with the error")
    func failedAnswerKeepsTheSheet() async throws {
        let service = ScriptedSessionService()
        let controller = try await openedController(service: service)
        controller.handle(event: Fixtures.serverRequestEvent(srqApproval()))
        service.enqueueAnswerFailure()

        controller.respondApproval(choice: "once")
        await controller.awaitPromptResponse()

        #expect(controller.approval?.serverRequestID == "srq-a1")
        #expect(controller.promptSendError != nil)
        await controller.teardown()
    }

    // MARK: request.cancel

    @Test("request.cancel clears only the sheet whose srq id it names")
    func requestCancelClearsOnlyTheMatchingSheet() async throws {
        let service = ScriptedSessionService()
        let controller = try await openedController(service: service)
        controller.handle(event: Fixtures.serverRequestEvent(srqApproval()))
        controller.handle(event: Fixtures.serverRequestEvent(srqClarify()))

        controller.handle(
            event: Fixtures.event(
                Fixtures.requestCancel(sessionID: Self.runtimeID, seq: 11, id: "srq-other")))
        #expect(controller.approval?.serverRequestID == "srq-a1")
        #expect(controller.clarify?.serverRequestID == "srq-q1")

        controller.handle(
            event: Fixtures.event(
                Fixtures.requestCancel(
                    sessionID: Self.runtimeID, seq: 12, id: "srq-q1", method: "clarify",
                    reason: "timeout")))
        #expect(controller.clarify == nil)
        #expect(controller.approval?.serverRequestID == "srq-a1")

        controller.handle(
            event: Fixtures.event(
                Fixtures.requestCancel(sessionID: Self.runtimeID, seq: 13, id: "srq-a1")))
        #expect(controller.approval == nil)
        await controller.teardown()
    }

    @Test("a late confirmation for a cancelled approval does not dismiss the next one")
    func cancelInvalidatesTheApprovalEpoch() async throws {
        let service = ScriptedSessionService()
        let controller = try await openedController(service: service)
        controller.handle(event: Fixtures.serverRequestEvent(srqApproval()))
        try #require(controller.approval != nil)

        let gate = CallGate()
        service.promptResponseGate = gate
        service.enqueueAnswerReply(.expired)
        controller.respondApproval(choice: "once")
        await gate.waitUntilEntered()
        controller.handle(
            event: Fixtures.event(
                Fixtures.requestCancel(sessionID: Self.runtimeID, seq: 11, id: "srq-a1")))
        controller.handle(
            event: Fixtures.serverRequestEvent(srqApproval(id: "srq-a2", requestID: "a2")))
        await gate.release()
        await controller.awaitPromptResponse()

        #expect(controller.approval?.serverRequestID == "srq-a2")
        await controller.teardown()
    }

    // MARK: open_requests on reconnect

    @Test("a reconnect restores a clarify from open_requests, and an empty list retires it")
    func openRequestsRestoreAndRetireTheSheet() async throws {
        let service = ScriptedSessionService()
        let controller = try await openedController(service: service)

        await reconnect(controller, service: service, openRequests: [srqClarify()])
        #expect(controller.clarify?.serverRequestID == "srq-q1")
        #expect(controller.clarify?.question == "Which branch?")

        await reconnect(controller, service: service, openRequests: [])
        #expect(controller.clarify == nil)
        await controller.teardown()
    }

    @Test("open_requests outranks pending_approval for the same approval on resume")
    func openRequestsOutrankPendingApprovalOnResume() async throws {
        let service = ScriptedSessionService()
        let speech = RecordingSpeech()
        let controller = try await openedController(
            service: service, speech: speech,
            pendingApproval: Fixtures.approvalPayload(command: "rm -rf /tmp/x", requestID: "a1"),
            openRequests: [srqApproval(id: "srq-X")])
        await controller.awaitPromptAnnouncements()

        #expect(controller.approval?.serverRequestID == "srq-X")
        #expect(speech.spoken == [Self.approvalNotice])

        controller.respondApproval(choice: "once")
        await controller.awaitPromptResponse()
        #expect(
            service.promptResponses == [
                .requestAnswer(params: answerParams(id: "srq-X", ["choice": .string("once")]))
            ])
        await controller.teardown()
    }

    @Test("open_requests outranks pending_approval in the post-batch read")
    func openRequestsOutrankPendingApprovalOnActivate() async throws {
        let service = ScriptedSessionService()
        let controller = try await openedController(service: service)

        await reconnect(
            controller, service: service,
            pendingApproval: Fixtures.approvalPayload(command: "rm -rf /tmp/x", requestID: "a1"),
            openRequests: [srqApproval(id: "srq-X")])

        #expect(controller.approval?.serverRequestID == "srq-X")
        await controller.teardown()
    }

    /// Starts a usable-replay reconnect and parks it inside
    /// `session.events.since`, so frames handled before `release()` land in
    /// the reconnect hold.
    private func reconnectHeldAtReplay(
        _ controller: ConversationController,
        service: ScriptedSessionService,
        batch: [JSONValue],
        openRequests: [JSONValue]
    ) async -> (gate: CallGate, done: Task<Void, Never>) {
        let gate = CallGate()
        service.eventsSinceGate = gate
        service.enqueueResume(
            Fixtures.resumeResult(runtimeID: Self.runtimeID, storedID: Self.storedID))
        service.enqueueBatch(
            Fixtures.replayBatch(batch, latestSeq: Self.watermark + batch.count))
        service.enqueueActivation(
            Fixtures.activateResult(
                runtimeID: Self.runtimeID, sessionKey: Self.storedID,
                openRequests: openRequests))
        let done = Task { await controller.connectionBecameReady(isReconnect: true) }
        await gate.waitUntilEntered()
        return (gate, done)
    }

    @Test("a held srq whose request.cancel is in the replay batch is not presented on drain")
    func heldServerRequestCancelledInReplayStaysDown() async throws {
        let service = ScriptedSessionService()
        let speech = RecordingSpeech()
        let controller = try await openedController(service: service, speech: speech)
        let cancel = Fixtures.requestCancel(
            sessionID: Self.runtimeID, seq: Self.watermark + 1, id: "srq-a1")
        let (gate, done) = await reconnectHeldAtReplay(
            controller, service: service, batch: [cancel], openRequests: [])

        // The srq (never seq-stamped) and the live copy of its cancel both
        // arrive on the new socket while the replay is in flight.
        controller.handle(event: Fixtures.serverRequestEvent(srqApproval()))
        controller.handle(event: Fixtures.event(cancel))
        await gate.release()
        await done.value
        await controller.awaitPromptAnnouncements()

        #expect(controller.approval == nil)
        #expect(speech.spoken.isEmpty)
        await controller.teardown()
    }

    @Test("a held srq still open in the post-batch read is presented and announced once")
    func heldServerRequestStillOpenPresentsOnce() async throws {
        let service = ScriptedSessionService()
        let speech = RecordingSpeech()
        let controller = try await openedController(service: service, speech: speech)
        let (gate, done) = await reconnectHeldAtReplay(
            controller, service: service, batch: [], openRequests: [srqClarify()])

        controller.handle(event: Fixtures.serverRequestEvent(srqClarify()))
        await gate.release()
        await done.value
        await controller.awaitPromptAnnouncements()

        #expect(controller.clarify?.serverRequestID == "srq-q1")
        #expect(speech.spoken == [Self.clarifyNotice])
        await controller.teardown()
    }

    @Test("a legacy sheet is upgraded in place when its srq arrives, without re-announcing")
    func legacySheetIsUpgradedInPlace() async throws {
        let service = ScriptedSessionService()
        let speech = RecordingSpeech()
        let controller = try await openedController(
            service: service, speech: speech,
            pendingApproval: Fixtures.approvalPayload(command: "rm -rf /tmp/x", requestID: "a1"))
        #expect(controller.approval?.serverRequestID == nil)

        controller.handle(event: Fixtures.serverRequestEvent(srqApproval(id: "srq-X")))
        await controller.awaitPromptAnnouncements()
        #expect(controller.approval?.serverRequestID == "srq-X")
        #expect(speech.spoken == [Self.approvalNotice])

        controller.respondApproval(choice: "once")
        await controller.awaitPromptResponse()
        #expect(
            service.promptResponses == [
                .requestAnswer(params: answerParams(id: "srq-X", ["choice": .string("once")]))
            ])
        #expect(controller.approval == nil)
        await controller.teardown()
    }

    // MARK: Contract 6 still works

    @Test("a contract-6 approval.request is answered through approval.respond")
    func legacyApprovalUsesApprovalRespond() async throws {
        let service = ScriptedSessionService()
        let controller = try await openedController(service: service)
        controller.handle(
            event: Fixtures.event(
                Fixtures.approvalRequest(
                    sessionID: Self.runtimeID, seq: 11, command: "rm -rf /tmp/x",
                    requestID: "a1")))
        #expect(controller.approval?.serverRequestID == nil)

        controller.respondApproval(choice: "session")
        await controller.awaitPromptResponse()

        #expect(
            service.promptResponses == [
                .approvalRespond(sessionID: Self.runtimeID, choice: "session")
            ])
        #expect(controller.approval == nil)
        await controller.teardown()
    }

    // MARK: Batch clarify (issue #125 Task 5)

    private func srqClarifyBatch(
        id: String = "srq-b1",
        questions: [(qid: String, question: String, choices: [String], multiSelect: Bool)] = [
            (qid: "q1", question: "Which branch?", choices: [], multiSelect: false),
            (qid: "q2", question: "Which env?", choices: [], multiSelect: false),
        ],
        lockedAnswers: [String: String] = [:]
    ) -> JSONValue {
        Fixtures.clarifyBatchServerRequest(
            id: id, sessionID: Self.runtimeID, questions: questions, lockedAnswers: lockedAnswers)
    }

    @Test("an srq batch clarify presents with its questions and no locked answers pre-asked")
    func srqBatchClarifyPresents() async throws {
        let service = ScriptedSessionService()
        let controller = try await openedController(service: service)

        controller.handle(event: Fixtures.serverRequestEvent(srqClarifyBatch()))

        #expect(controller.clarify?.serverRequestID == "srq-b1")
        #expect(controller.clarify?.questions.map(\.qid) == ["q1", "q2"])
        await controller.teardown()
    }

    @Test("a batch's spoken notice counts the unlocked questions")
    func batchNoticeCountsUnlockedQuestions() async throws {
        let service = ScriptedSessionService()
        let speech = RecordingSpeech()
        let controller = try await openedController(service: service, speech: speech)

        controller.handle(
            event: Fixtures.serverRequestEvent(
                srqClarifyBatch(lockedAnswers: ["q1": "main"])))
        await controller.awaitPromptAnnouncements()

        #expect(speech.spoken == ["Hermes has 1 questions for you."])
        await controller.teardown()
    }

    /// Upstream resolves a batch the moment its last question locks, so one
    /// that arrives fully locked is already settled: there is nothing to
    /// show, say or send (a `request.answer` could only come back `expired`).
    @Test("a batch that arrives fully locked shows no sheet, says nothing and sends nothing")
    func fullyLockedBatchIsIgnored() async throws {
        let service = ScriptedSessionService()
        let speech = RecordingSpeech()
        let controller = try await openedController(service: service, speech: speech)

        controller.handle(
            event: Fixtures.serverRequestEvent(
                srqClarifyBatch(lockedAnswers: ["q1": "main", "q2": "prod"])))
        await controller.awaitPromptResponse()
        await controller.awaitPromptAnnouncements()

        #expect(controller.clarify == nil)
        #expect(speech.spoken.isEmpty)
        #expect(service.promptResponses.isEmpty)
        await controller.teardown()
    }

    @Test("answering a 2-question batch sends one answers object with both qids")
    func answeringABatchSendsOneAnswersObject() async throws {
        let service = ScriptedSessionService()
        let controller = try await openedController(service: service)
        controller.handle(event: Fixtures.serverRequestEvent(srqClarifyBatch()))
        try #require(controller.clarify != nil)

        controller.respondClarify(answers: ["q1": "main", "q2": "prod"])
        await controller.awaitPromptResponse()

        #expect(
            service.promptResponses == [
                .requestAnswer(
                    params: answerParams(
                        id: "srq-b1",
                        [
                            "answers": .object([
                                "q1": .string("main"), "q2": .string("prod"),
                            ])
                        ]))
            ])
        #expect(controller.clarify == nil)
        await controller.teardown()
    }

    @Test("pre-locked answers are included in the final submission without being re-asked")
    func lockedAnswersAreIncludedInFinalSubmission() async throws {
        let service = ScriptedSessionService()
        let controller = try await openedController(service: service)
        controller.handle(
            event: Fixtures.serverRequestEvent(
                srqClarifyBatch(lockedAnswers: ["q1": "main"])))
        try #require(controller.clarify != nil)

        // Only q2 is still open; the final submission must still carry q1.
        controller.respondClarify(answers: ["q1": "main", "q2": "prod"])
        await controller.awaitPromptResponse()

        #expect(
            service.promptResponses == [
                .requestAnswer(
                    params: answerParams(
                        id: "srq-b1",
                        [
                            "answers": .object([
                                "q1": .string("main"), "q2": .string("prod"),
                            ])
                        ]))
            ])
        await controller.teardown()
    }

    @Test("Skip all sends an empty result, not an empty answers object")
    func skipAllSendsEmptyResult() async throws {
        let service = ScriptedSessionService()
        let controller = try await openedController(service: service)
        controller.handle(event: Fixtures.serverRequestEvent(srqClarifyBatch()))
        try #require(controller.clarify != nil)

        controller.respondClarify(answers: [:])
        await controller.awaitPromptResponse()

        #expect(
            service.promptResponses == [
                .requestAnswer(params: answerParams(id: "srq-b1", [:]))
            ])
        #expect(controller.clarify == nil)
        await controller.teardown()
    }

    @Test("respondClarify(answers:) is a no-op on a request without a serverRequestID")
    func batchAnswersNoOpsOnLegacyClarify() async throws {
        let service = ScriptedSessionService()
        let controller = try await openedController(service: service)
        controller.handle(
            event: Fixtures.event(
                Fixtures.clarifyRequest(
                    sessionID: Self.runtimeID, seq: 11, requestID: "q1",
                    question: "Which branch?")))
        try #require(controller.clarify != nil)

        controller.respondClarify(answers: ["q1": "main"])

        #expect(service.promptResponses.isEmpty)
        #expect(controller.clarify != nil)
        await controller.teardown()
    }

    @Test("a contract-6 clarify.request is answered through clarify.respond")
    func legacyClarifyUsesClarifyRespond() async throws {
        let service = ScriptedSessionService()
        let controller = try await openedController(service: service)
        controller.handle(
            event: Fixtures.event(
                Fixtures.clarifyRequest(
                    sessionID: Self.runtimeID, seq: 11, requestID: "q1",
                    question: "Which branch?")))

        controller.respondClarify(answer: "main")
        await controller.awaitPromptResponse()

        #expect(service.promptResponses == [.clarifyRespond(requestID: "q1", answer: "main")])
        #expect(controller.clarify == nil)
        await controller.teardown()
    }
}
