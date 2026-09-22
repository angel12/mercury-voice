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

    // MARK: Turn-visibility events (issue #125, contract v7)

    /// Opens a fresh session so `handle(event:)` clears the seq gate; every
    /// turn-visibility test drives events against this runtime id.
    private func makeOpenController(_ service: ScriptedSessionService) async throws
        -> ConversationController
    {
        service.enqueueCreate(Fixtures.resumeResult(runtimeID: "rt", storedID: "stored"))
        let controller = makeController(service: service)
        try await controller.openSession(mode: .create(cwd: nil, title: nil))
        return controller
    }

    @Test
    func statusUpdateCompactingSetsToolTicker() async throws {
        let service = ScriptedSessionService()
        let controller = try await makeOpenController(service)
        defer { Task { await controller.teardown() } }
        controller.handle(
            event: Fixtures.event(
                Fixtures.statusUpdate(sessionID: "rt", seq: 1, kind: "compacting")))
        #expect(controller.toolTicker == "Compacting context…")
    }

    @Test
    func statusUpdateOtherKindsAreIgnored() async throws {
        let service = ScriptedSessionService()
        let controller = try await makeOpenController(service)
        defer { Task { await controller.teardown() } }
        controller.handle(
            event: Fixtures.event(
                Fixtures.statusUpdate(sessionID: "rt", seq: 1, kind: "heartbeat")))
        #expect(controller.toolTicker == nil)
    }

    @Test
    func compactingTickerClearsOnMessageComplete() async throws {
        let service = ScriptedSessionService()
        let controller = try await makeOpenController(service)
        defer { Task { await controller.teardown() } }
        controller.handle(
            event: Fixtures.event(
                Fixtures.statusUpdate(sessionID: "rt", seq: 1, kind: "compacting")))
        #expect(controller.toolTicker == "Compacting context…")
        controller.handle(
            event: Fixtures.event(Fixtures.messageComplete(sessionID: "rt", seq: 2, text: "ok")))
        #expect(controller.toolTicker == nil)
    }

    @Test
    func subagentStartSetsDelegatingTickerAndCompleteClearsIt() async throws {
        let service = ScriptedSessionService()
        let controller = try await makeOpenController(service)
        defer { Task { await controller.teardown() } }
        controller.handle(
            event: Fixtures.event(
                Fixtures.subagentStart(
                    sessionID: "rt", seq: 1, goal: "Refactor the parser", subagentID: "a")))
        #expect(controller.toolTicker == "Delegating: Refactor the parser…")
        controller.handle(
            event: Fixtures.event(
                Fixtures.subagentComplete(
                    sessionID: "rt", seq: 2, goal: "Refactor the parser", subagentID: "a")))
        #expect(controller.toolTicker == nil)
    }

    @Test
    func parallelSubagentsKeepTickerUntilLastCompletes() async throws {
        let service = ScriptedSessionService()
        let controller = try await makeOpenController(service)
        defer { Task { await controller.teardown() } }
        controller.handle(
            event: Fixtures.event(
                Fixtures.subagentStart(
                    sessionID: "rt", seq: 1, goal: "task one", taskCount: 2, taskIndex: 0,
                    subagentID: "a")))
        controller.handle(
            event: Fixtures.event(
                Fixtures.subagentStart(
                    sessionID: "rt", seq: 2, goal: "task two", taskCount: 2, taskIndex: 1,
                    subagentID: "b")))
        #expect(controller.toolTicker != nil)
        controller.handle(
            event: Fixtures.event(
                Fixtures.subagentComplete(
                    sessionID: "rt", seq: 3, goal: "task one", taskCount: 2, taskIndex: 0,
                    subagentID: "a")))
        // One of two still running: ticker must survive.
        #expect(controller.toolTicker != nil)
        controller.handle(
            event: Fixtures.event(
                Fixtures.subagentComplete(
                    sessionID: "rt", seq: 4, goal: "task two", taskCount: 2, taskIndex: 1,
                    subagentID: "b")))
        #expect(controller.toolTicker == nil)
    }

    @Test
    func toolTickerSetAfterSubagentStartIsNotClobberedBySubagentComplete() async throws {
        let service = ScriptedSessionService()
        let controller = try await makeOpenController(service)
        defer { Task { await controller.teardown() } }
        controller.handle(
            event: Fixtures.event(
                Fixtures.subagentStart(sessionID: "rt", seq: 1, goal: "delegated work")))
        #expect(controller.toolTicker == "Delegating: delegated work…")
        controller.handle(
            event: Fixtures.event(Fixtures.toolStart(sessionID: "rt", seq: 2, name: "grep")))
        #expect(controller.toolTicker == "Running: grep…")
        controller.handle(
            event: Fixtures.event(
                Fixtures.subagentComplete(sessionID: "rt", seq: 3, goal: "delegated work")))
        // The subagent set is now empty, but the ticker belongs to the tool
        // that started since — must not be clobbered.
        #expect(controller.toolTicker == "Running: grep…")
    }

    @Test
    func subagentIDFallsBackToTaskIndexWhenAbsent() async throws {
        let service = ScriptedSessionService()
        let controller = try await makeOpenController(service)
        defer { Task { await controller.teardown() } }
        controller.handle(
            event: Fixtures.event(
                Fixtures.subagentStart(
                    sessionID: "rt", seq: 1, goal: "task zero", taskCount: 2, taskIndex: 0)))
        controller.handle(
            event: Fixtures.event(
                Fixtures.subagentStart(
                    sessionID: "rt", seq: 2, goal: "task one", taskCount: 2, taskIndex: 1)))
        controller.handle(
            event: Fixtures.event(
                Fixtures.subagentComplete(
                    sessionID: "rt", seq: 3, goal: "task zero", taskCount: 2, taskIndex: 0)))
        #expect(controller.toolTicker != nil)
        controller.handle(
            event: Fixtures.event(
                Fixtures.subagentComplete(
                    sessionID: "rt", seq: 4, goal: "task one", taskCount: 2, taskIndex: 1)))
        #expect(controller.toolTicker == nil)
    }

    @Test
    func notificationClearWithMatchingKeyClearsNotice() async throws {
        let service = ScriptedSessionService()
        let controller = try await makeOpenController(service)
        defer { Task { await controller.teardown() } }
        controller.handle(
            event: Fixtures.event(
                Fixtures.notificationShow(sessionID: "rt", seq: 1, text: "hi", key: "k1")))
        #expect(controller.notice == "hi")
        controller.handle(
            event: Fixtures.event(Fixtures.notificationClear(sessionID: "rt", seq: 2, key: "k1")))
        #expect(controller.notice == nil)
    }

    @Test
    func notificationClearWithNonMatchingKeyLeavesNoticeAlone() async throws {
        let service = ScriptedSessionService()
        let controller = try await makeOpenController(service)
        defer { Task { await controller.teardown() } }
        controller.handle(
            event: Fixtures.event(
                Fixtures.notificationShow(sessionID: "rt", seq: 1, text: "hi", key: "k1")))
        #expect(controller.notice == "hi")
        controller.handle(
            event: Fixtures.event(
                Fixtures.notificationClear(sessionID: "rt", seq: 2, key: "other")))
        #expect(controller.notice == "hi")
    }

    @Test
    func notificationShowWithoutKeyCannotBeWithdrawnByClear() async throws {
        let service = ScriptedSessionService()
        let controller = try await makeOpenController(service)
        defer { Task { await controller.teardown() } }
        controller.handle(
            event: Fixtures.event(
                Fixtures.notificationShow(sessionID: "rt", seq: 1, text: "hi", key: nil)))
        #expect(controller.notice == "hi")
        controller.handle(
            event: Fixtures.event(
                Fixtures.notificationClear(sessionID: "rt", seq: 2, key: "anything")))
        #expect(controller.notice == "hi")
    }

    @Test
    func reconnectNoticeResetsStoredKeySoStaleClearCannotWithdrawIt() async throws {
        let service = ScriptedSessionService()
        let controller = try await makeOpenController(service)
        defer { Task { await controller.teardown() } }
        controller.handle(
            event: Fixtures.event(
                Fixtures.notificationShow(sessionID: "rt", seq: 1, text: "hi", key: "k1")))
        #expect(controller.notice == "hi")
        // A different notice write (e.g. the reconnect banner) must reset the
        // stored key — a later clear for the old key must not touch it.
        controller.showNotice("Reconnected.")
        #expect(controller.notice == "Reconnected.")
        controller.handle(
            event: Fixtures.event(Fixtures.notificationClear(sessionID: "rt", seq: 2, key: "k1")))
        #expect(controller.notice == "Reconnected.")
    }
}
