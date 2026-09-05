import Foundation
import HermesKit
import Testing

@testable import MercuryVoice

/// Regression coverage for audit finding R25 / issue #77: concurrent
/// conversation launches overwrote `AppModel.conversation` without rejecting
/// or tearing down the one they replaced.
///
/// `ConversationController.begin()` suspends on `session.create` /
/// `session.resume`. `AppModel.shared` is one instance behind a `WindowGroup`,
/// so a second Browse tap, another window, or the start-session Shortcut can
/// land inside that window. The superseded launch then resumed against a
/// controller nothing routed events to, opened its engine, armed the
/// microphone and held a backend session open.
///
/// Every wait here is a `CallGate` or a task value — no sleeping, no polling.
@MainActor
@Suite("Conversation ownership (R25)")
struct R25ConversationOwnershipTests {

    // MARK: Harness

    private static let server = "http://127.0.0.1:8080"

    /// A connected `AppModel`: the probe accepts, so `connect()` runs all the
    /// way through to building the real (never-dialled) `HermesConnection` and
    /// handing it to `GatewayRecorder`. Conversations come from
    /// `ConversationRecorder`, so every launch gets a scripted session service
    /// and a silent audio stack.
    private func connectedModel(
        conversations: ConversationRecorder,
        gateway: GatewayRecorder,
        defaults: UserDefaults
    ) async -> AppModel {
        let model = AppModel(
            dependencies: .scripted(
                probes: ProbeRecorder { _ in .accepting },
                gateway: gateway,
                conversations: conversations,
                defaults: defaults))
        await model.connect(input: Self.server, token: "session-token")
        #expect(model.connection != nil)
        return model
    }

    /// Scripts every launch to answer its open with `rt-<n>` / `st-<n>`, and
    /// holds the launches named in `gates` open inside that call.
    private func recorder(gates: [Int: CallGate]) -> ConversationRecorder {
        let conversations = ConversationRecorder()
        conversations.script = { index, service in
            let answer = Fixtures.resumeResult(runtimeID: "rt-\(index)", storedID: "st-\(index)")
            service.enqueueCreate(answer)
            service.enqueueResume(answer)
            if let gate = gates[index] {
                service.createGate = gate
                service.resumeGate = gate
            }
        }
        return conversations
    }

    // MARK: create → create

    /// Two "New session" taps overlapping inside `session.create`. The second
    /// owns the conversation; the first must not come back to life when its
    /// open finally answers.
    @Test func aSecondCreateSupersedesTheFirstInFlightLaunch() async {
        let (defaults, suiteName) = makeTestDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let gateway = GatewayRecorder()
        defer { gateway.finishAll() }

        let firstOpen = CallGate()
        let secondOpen = CallGate()
        let conversations = recorder(gates: [0: firstOpen, 1: secondOpen])
        let model = await connectedModel(
            conversations: conversations, gateway: gateway, defaults: defaults)

        let first = Task { await model.startConversation(cwd: "/one") }
        await firstOpen.waitUntilEntered()
        #expect(conversations.launches.count == 1)
        #expect(model.conversation === conversations.launches[0].controller)

        // Second launch, while the first is still inside session.create.
        let second = Task { await model.startConversation(cwd: "/two") }
        await secondOpen.waitUntilEntered()

        // Ownership moved before the replacement even opened its session.
        #expect(conversations.launches.count == 2)
        #expect(model.conversation === conversations.launches[1].controller)
        #expect(conversations.launches[0].service.createdCWDs == ["/one"])
        #expect(conversations.launches[1].service.createdCWDs == ["/two"])

        // The replacement takes ownership first; only then is the superseded
        // launch released.
        await secondOpen.release()
        await second.value
        #expect(model.conversation === conversations.launches[1].controller)

        await firstOpen.release()
        await first.value

        // The superseded launch never armed the microphone or opened an
        // engine, closed the session it had just been handed, and did not
        // take ownership back.
        #expect(conversations.launches[0].recorder.startCalls == 0)
        #expect(conversations.launches[0].bargeMonitor.startCalls == 0)
        #expect(conversations.launches[0].service.closedIDs == ["rt-0"])
        #expect(model.conversation === conversations.launches[1].controller)

        // The survivor is a working conversation: its voice loop started and
        // its session is still open.
        #expect(conversations.launches[1].recorder.startCalls == 1)
        #expect(conversations.launches[1].service.closedIDs.isEmpty)
    }

    // MARK: create → resume

    /// Same overlap, but the replacement is "continue this session" from the
    /// recents list — the other launch entry point.
    @Test func aResumeSupersedesAnInFlightCreate() async {
        let (defaults, suiteName) = makeTestDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let gateway = GatewayRecorder()
        defer { gateway.finishAll() }

        let createOpen = CallGate()
        let resumeOpen = CallGate()
        let conversations = recorder(gates: [0: createOpen, 1: resumeOpen])
        let model = await connectedModel(
            conversations: conversations, gateway: gateway, defaults: defaults)

        let create = Task { await model.startConversation(cwd: "/one") }
        await createOpen.waitUntilEntered()

        let summary = SessionSummary(
            json: .object([
                "session_id": .string("stored-abc"),
                "profile": .string("work"),
            ]))!
        let resume = Task { await model.continueSession(summary) }
        await resumeOpen.waitUntilEntered()

        #expect(model.conversation === conversations.launches[1].controller)
        #expect(conversations.launches[1].profile == "work")
        #expect(conversations.launches[1].service.resumedIDs == ["stored-abc"])

        await resumeOpen.release()
        await resume.value
        await createOpen.release()
        await create.value

        #expect(conversations.launches[0].recorder.startCalls == 0)
        #expect(conversations.launches[0].service.closedIDs == ["rt-0"])
        #expect(model.conversation === conversations.launches[1].controller)
        #expect(conversations.launches[1].recorder.startCalls == 1)
    }

    // MARK: Superseding a settled conversation

    /// The non-overlapping case: the conversation on screen has finished
    /// opening. A new launch must still tear it down rather than drop it.
    @Test func launchingOverASettledConversationTearsTheOldOneDown() async {
        let (defaults, suiteName) = makeTestDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let gateway = GatewayRecorder()
        defer { gateway.finishAll() }

        let conversations = recorder(gates: [:])
        let model = await connectedModel(
            conversations: conversations, gateway: gateway, defaults: defaults)

        await model.startConversation(cwd: "/one")
        #expect(model.conversation === conversations.launches[0].controller)
        #expect(conversations.launches[0].recorder.startCalls == 1)

        await model.startConversation(cwd: "/two")
        await model.pendingTeardown?.value

        #expect(model.conversation === conversations.launches[1].controller)
        #expect(conversations.launches[0].service.closedIDs == ["rt-0"])
        #expect(conversations.launches[1].service.closedIDs.isEmpty)
        #expect(conversations.launches[1].recorder.startCalls == 1)
    }

    // MARK: Ending / disconnecting mid-launch

    /// Ending the conversation while its session is still opening: the launch
    /// must not publish the controller it was building, and must close the
    /// session the backend handed it (issue #38's guarantee, now also fenced
    /// by the generation).
    ///
    /// Honest scope: this test and the disconnect one below pass against the
    /// pre-fix code too. #38 already tore the controller down here, just from
    /// a task whose `isTornDown` write races the resuming `begin()`; the
    /// scheduling in this harness happens to win that race either way, so
    /// they do not discriminate the fix. `supersede()` makes the ordering a
    /// guarantee rather than luck — these two stand as regression guards, not
    /// as evidence for R25. The three overlap tests above are the ones that
    /// fail without it.
    @Test func endingDuringAnInFlightLaunchLeavesNothingRunning() async {
        let (defaults, suiteName) = makeTestDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let gateway = GatewayRecorder()
        defer { gateway.finishAll() }

        let open = CallGate()
        let conversations = recorder(gates: [0: open])
        let model = await connectedModel(
            conversations: conversations, gateway: gateway, defaults: defaults)

        let launch = Task { await model.startConversation(cwd: "/one") }
        await open.waitUntilEntered()

        model.endConversation()
        #expect(model.conversation == nil)

        await open.release()
        await launch.value

        #expect(model.conversation == nil)
        #expect(conversations.launches[0].recorder.startCalls == 0)
        #expect(conversations.launches[0].service.closedIDs == ["rt-0"])
    }

    /// Disconnecting mid-launch is the same guarantee, and it must not leave
    /// a conversation attached to a connection that is gone.
    @Test func disconnectingDuringAnInFlightLaunchLeavesNothingRunning() async {
        let (defaults, suiteName) = makeTestDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let gateway = GatewayRecorder()
        defer { gateway.finishAll() }

        let open = CallGate()
        let conversations = recorder(gates: [0: open])
        let model = await connectedModel(
            conversations: conversations, gateway: gateway, defaults: defaults)

        let launch = Task { await model.startConversation(cwd: "/one") }
        await open.waitUntilEntered()

        model.disconnect()
        #expect(model.conversation == nil)
        #expect(model.connection == nil)

        await open.release()
        await launch.value
        await model.pendingTeardown?.value

        #expect(model.conversation == nil)
        #expect(conversations.launches[0].recorder.startCalls == 0)
        #expect(conversations.launches[0].service.closedIDs == ["rt-0"])
        #expect(gateway.stoppedCount == 1)
    }

    // MARK: Normal launch and teardown

    /// The happy path still works end to end: one launch owns the
    /// conversation, its voice loop runs, and ending it closes the session and
    /// stops the microphone.
    @Test func aSingleLaunchOwnsTheConversationAndTearsDownCleanly() async {
        let (defaults, suiteName) = makeTestDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let gateway = GatewayRecorder()
        defer { gateway.finishAll() }

        let conversations = recorder(gates: [:])
        let model = await connectedModel(
            conversations: conversations, gateway: gateway, defaults: defaults)

        await model.startConversation(cwd: "/one", title: "Work")
        let launch = conversations.launches[0]
        #expect(conversations.launches.count == 1)
        #expect(model.conversation === launch.controller)
        #expect(launch.controller.setupError == nil)
        #expect(launch.recorder.startCalls == 1)
        #expect(launch.service.closedIDs.isEmpty)

        model.disconnect()
        await model.pendingTeardown?.value

        #expect(model.conversation == nil)
        #expect(launch.service.closedIDs == ["rt-0"])
        #expect(launch.recorder.cancelCalls >= 1)
    }
}
