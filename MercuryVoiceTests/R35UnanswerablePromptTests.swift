import Foundation
import HermesKit
import Testing

@testable import MercuryVoice

/// Issue #130 — a server request the app cannot answer (sudo, secret, vault
/// prompts, or an approval/clarify it cannot decode) is shown with what was
/// asked. Decline sends the backend's "skipped" answer; Not now closes the
/// sheet and leaves the request for another client or its deadline.
@MainActor
@Suite("R35 unanswerable server-request prompts", .timeLimit(.minutes(1)))
struct R35UnanswerablePromptTests {

    static let runtimeID = "rt1"
    static let storedID = "st1"
    static let watermark = 10
    static let sudoNotice =
        "Hermes needs a sudo password. Answer it on another device, or decline."

    private func openedController(
        service: ScriptedSessionService,
        speech: RecordingSpeech = RecordingSpeech(),
        openRequests: [JSONValue]? = nil
    ) async throws -> ConversationController {
        service.enqueueResume(
            Fixtures.resumeResult(
                runtimeID: Self.runtimeID, storedID: Self.storedID, openRequests: openRequests))
        let controller = makeController(service: service, speech: speech)
        try await controller.openSession(mode: .resume(storedID: Self.storedID))
        controller.handle(
            event: Fixtures.event(
                Fixtures.messageComplete(sessionID: Self.runtimeID, seq: Self.watermark)))
        return controller
    }

    private func reconnect(
        _ controller: ConversationController,
        service: ScriptedSessionService,
        openRequests: [JSONValue]?
    ) async {
        service.enqueueResume(
            Fixtures.resumeResult(runtimeID: Self.runtimeID, storedID: Self.storedID))
        service.enqueueBatch(Fixtures.replayBatch([], latestSeq: Self.watermark))
        service.enqueueActivation(
            Fixtures.activateResult(
                runtimeID: Self.runtimeID, sessionKey: Self.storedID,
                openRequests: openRequests))
        await controller.connectionBecameReady(isReconnect: true)
    }

    private func srq(
        id: String = "srq-s1", method: String = "sudo",
        params: [String: JSONValue] = ["command": "apt install jq"]
    ) -> JSONValue {
        var params = params
        params["session_id"] = .string(Self.runtimeID)
        return .object(["id": .string(id), "method": .string(method), "params": .object(params)])
    }

    private func cancel(_ id: String, seq: Int) -> GatewayEvent {
        Fixtures.event(
            Fixtures.requestCancel(sessionID: Self.runtimeID, seq: seq, id: id, method: "sudo"))
    }

    // MARK: Presenting

    @Test("a sudo request presents with its command and is announced once")
    func sudoPresentsAndAnnounces() async throws {
        let service = ScriptedSessionService()
        let speech = RecordingSpeech()
        let controller = try await openedController(service: service, speech: speech)

        controller.handle(event: Fixtures.serverRequestEvent(srq()))
        controller.handle(event: Fixtures.serverRequestEvent(srq()))  // same id: not queued twice
        await controller.awaitPromptAnnouncements()

        let shown = try #require(controller.currentUnanswerable)
        #expect(shown.id == "srq-s1")
        #expect(shown.details.first?.value == "apt install jq")
        #expect(controller.unanswerable.count == 1)
        #expect(controller.approval == nil && controller.clarify == nil)
        #expect(speech.spoken == [Self.sudoNotice])
        #expect(service.promptResponses.isEmpty)
        await controller.teardown()
    }

    @Test("an approval the app cannot decode is shown as unanswerable, not as an approval")
    func undecodableApprovalIsUnanswerable() async throws {
        let service = ScriptedSessionService()
        let controller = try await openedController(service: service)

        // No session_id: `ApprovalRequest(serverRequest:)` cannot decode it.
        let raw: JSONValue = .object([
            "id": "srq-a1", "method": "approval", "params": ["command": "rm -rf build"],
        ])
        controller.handle(event: Fixtures.serverRequestEvent(raw))

        #expect(controller.approval == nil)
        #expect(controller.currentUnanswerable?.id == "srq-a1")
        #expect(controller.currentUnanswerable?.declineResult == .object(["choice": "deny"]))
        await controller.teardown()
    }

    @Test("a desktop bridge request shows nothing")
    func bridgeShowsNothing() async throws {
        let service = ScriptedSessionService()
        let controller = try await openedController(service: service)
        controller.handle(
            event: Fixtures.serverRequestEvent(srq(method: "tour", params: ["action": "start"])))
        #expect(controller.currentUnanswerable == nil)
        await controller.teardown()
    }

    // MARK: Decline

    @Test("Decline sends the skipped answer and closes on the reply")
    func declineSendsSkippedAnswer() async throws {
        let service = ScriptedSessionService()
        let controller = try await openedController(service: service)
        controller.handle(event: Fixtures.serverRequestEvent(srq()))

        let gate = CallGate()
        service.promptResponseGate = gate
        controller.declineUnanswerable()
        await gate.waitUntilEntered()
        #expect(controller.currentUnanswerable != nil)  // kept until the reply lands
        #expect(controller.promptResponseInFlight)
        await gate.release()
        await controller.awaitPromptResponse()

        #expect(
            service.promptResponses == [
                .requestAnswer(
                    params: .object(["id": "srq-s1", "result": .object(["value": ""])]))
            ])
        #expect(controller.currentUnanswerable == nil)
        #expect(controller.promptSendError == nil)
        await controller.teardown()
    }

    @Test("an expired reply to Decline still closes the sheet")
    func expiredDeclineCloses() async throws {
        let service = ScriptedSessionService()
        let controller = try await openedController(service: service)
        controller.handle(event: Fixtures.serverRequestEvent(srq()))
        service.enqueueAnswerReply(.expired)

        controller.declineUnanswerable()
        await controller.awaitPromptResponse()

        #expect(controller.currentUnanswerable == nil)
        await controller.teardown()
    }

    @Test("a failed Decline keeps the sheet up with the error")
    func failedDeclineKeepsTheSheet() async throws {
        let service = ScriptedSessionService()
        let controller = try await openedController(service: service)
        controller.handle(event: Fixtures.serverRequestEvent(srq()))
        service.enqueueAnswerFailure()

        controller.declineUnanswerable()
        await controller.awaitPromptResponse()

        #expect(controller.currentUnanswerable?.id == "srq-s1")
        #expect(controller.promptSendError != nil)
        await controller.teardown()
    }

    // MARK: Not now

    @Test("Not now closes without answering, and a reconnect does not bring it back")
    func notNowLeavesTheRequestOpen() async throws {
        let service = ScriptedSessionService()
        let controller = try await openedController(service: service)
        controller.handle(event: Fixtures.serverRequestEvent(srq()))

        controller.dismissUnanswerable()
        #expect(controller.currentUnanswerable == nil)
        #expect(service.promptResponses.isEmpty)

        await reconnect(controller, service: service, openRequests: [srq()])
        #expect(controller.currentUnanswerable == nil)
        await controller.teardown()
    }

    // MARK: Withdrawal and queueing

    @Test("request.cancel withdraws only the named request, and the next one is announced")
    func cancelAdvancesTheQueue() async throws {
        let service = ScriptedSessionService()
        let speech = RecordingSpeech()
        let controller = try await openedController(service: service, speech: speech)
        controller.handle(event: Fixtures.serverRequestEvent(srq()))
        controller.handle(
            event: Fixtures.serverRequestEvent(
                srq(id: "srq-c1", method: "vault.code", params: ["site": "GitHub"])))
        await controller.awaitPromptAnnouncements()
        #expect(controller.currentUnanswerable?.id == "srq-s1")

        controller.handle(event: cancel("srq-other", seq: 11))
        #expect(controller.unanswerable.count == 2)

        controller.handle(event: cancel("srq-s1", seq: 12))
        await controller.awaitPromptAnnouncements()
        #expect(controller.currentUnanswerable?.id == "srq-c1")
        #expect(
            speech.spoken == [
                Self.sudoNotice,
                "Hermes needs a one-time code. Answer it on another device, or decline.",
            ])
        await controller.teardown()
    }

    @Test("a reconnect restores open unanswerable requests, and an empty list retires them")
    func reconnectRestoresAndRetires() async throws {
        let service = ScriptedSessionService()
        let controller = try await openedController(service: service)

        await reconnect(controller, service: service, openRequests: [srq()])
        #expect(controller.currentUnanswerable?.id == "srq-s1")

        await reconnect(controller, service: service, openRequests: [])
        #expect(controller.currentUnanswerable == nil)
        await controller.teardown()
    }

    @Test("an unanswerable request open at resume is presented")
    func resumeAdoptsOpenRequests() async throws {
        let service = ScriptedSessionService()
        let controller = try await openedController(service: service, openRequests: [srq()])
        #expect(controller.currentUnanswerable?.id == "srq-s1")
        await controller.teardown()
    }
}
