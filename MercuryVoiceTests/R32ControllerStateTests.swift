import Testing

@testable import MercuryVoice

/// Characterization for removal of private bookkeeping, not a behavior fix.
/// These must pass both before and after the R32 cleanup.
@MainActor
struct R32ControllerStateTests {
    @Test(arguments: [false, true])
    func sessionIdentitySurvivesOpenReconnectAndRepeatedTeardown(resuming: Bool) async throws {
        let service = ScriptedSessionService()
        let initial = Fixtures.resumeResult(runtimeID: "initial", storedID: "stored")
        if resuming { service.enqueueResume(initial) } else { service.enqueueCreate(initial) }
        let controller = makeController(service: service)
        do {
            try await controller.openSession(
                mode: resuming ? .resume(storedID: "stored") : .create(cwd: "/fixture", title: nil))
            #expect(service.createdCWDs == (resuming ? [] : ["/fixture"]))
            #expect(service.resumedIDs == (resuming ? ["stored"] : []))
            controller.handle(
                event: Fixtures.event(
                    Fixtures.messageComplete(sessionID: "initial", seq: 1, text: "before")))
            controller.connectionLost()
            #expect(!controller.connectionHealthy)
            service.enqueueResume(
                Fixtures.resumeResult(runtimeID: "replacement", storedID: "stored"))
            await controller.connectionBecameReady(isReconnect: true)
            #expect(controller.connectionHealthy)
            #expect(controller.notice == "Reconnected.")
            #expect(service.resumedIDs == (resuming ? ["stored", "stored"] : ["stored"]))
            controller.handle(
                event: Fixtures.event(
                    Fixtures.messageComplete(sessionID: "initial", seq: 2, text: "obsolete")))
            controller.handle(
                event: Fixtures.event(
                    Fixtures.messageComplete(sessionID: "replacement", seq: 1, text: "after")))
            await controller.diagnosticFinishTrackerEvents()
            #expect(controller.devMessages.map(\.text) == ["before", "after"])
            await controller.teardown()
            await controller.teardown()
            #expect(service.closedIDs == ["replacement"])
        } catch {
            await controller.teardown()
            throw error
        }
    }

    @Test
    func failedBeginPublishesErrorAndTeardownHasNoSessionToClose() async {
        let service = ScriptedSessionService()
        let controller = makeController(service: service)
        await controller.begin(mode: .create(cwd: nil, title: nil))
        #expect(controller.setupError != nil)
        #expect(controller.assistantCaption.isEmpty)
        await controller.teardown()
        await controller.teardown()
        #expect(service.closedIDs.isEmpty)
    }
}
