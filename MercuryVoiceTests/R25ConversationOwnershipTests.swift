import Foundation
import HermesKit
import Testing
import VoiceEngine

#if os(iOS)
    import AVFoundation
#endif

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
/// Serialized: `startVoiceLoop` installs a handler on the process-global
/// `AudioCaptureService.shared`, and the meter-ownership assertions below read
/// it back, so these tests must not interleave with each other. No other suite
/// reaches that state — the controller tests elsewhere stop at `openSession`.
@MainActor
@Suite("Conversation ownership (R25)", .serialized)
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

    // MARK: Shared capture state under reversed cleanup ordering

    /// A superseded controller's teardown is asynchronous, so it can land
    /// after the replacement has already installed its own mic-level handler.
    /// This drives that order deliberately — the replacement is fully settled
    /// first, and only then does the old controller's *real* `teardown()` run
    /// — and asserts the shared handler on `AudioCaptureService` survives.
    ///
    /// The assertion is on the capture service itself, not on the ownership
    /// bookkeeping alone: an unconditional `setLevelHandler(nil)` leaves
    /// `hasLevelHandler == false`, which is exactly what this catches.
    @Test func delayedCleanupCannotTakeTheLevelMeterFromTheReplacement() async {
        let (defaults, suiteName) = makeTestDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let gateway = GatewayRecorder()
        defer { gateway.finishAll() }

        let conversations = recorder(gates: [:])
        let model = await connectedModel(
            conversations: conversations, gateway: gateway, defaults: defaults)

        await model.startConversation(cwd: "/one")
        let superseded = conversations.launches[0].controller
        #expect(ConversationController.levelMeterOwner === superseded)

        await model.startConversation(cwd: "/two")
        await model.pendingTeardown?.value
        let replacement = conversations.launches[1].controller

        // The replacement owns the meter and the shared handler is installed.
        #expect(ConversationController.levelMeterOwner === replacement)
        #expect(AudioCaptureService.shared.hasLevelHandler)

        // Reversed order, forced: run the superseded controller's real
        // teardown again, now that the replacement has installed its handler.
        await superseded.teardown()

        #expect(ConversationController.levelMeterOwner === replacement)
        #expect(AudioCaptureService.shared.hasLevelHandler)

        // …and the owner still gives it up when it is the one tearing down.
        await replacement.teardown()
        #expect(ConversationController.levelMeterOwner == nil)
        #expect(!AudioCaptureService.shared.hasLevelHandler)
    }

    #if os(iOS)

        /// Drain `OperationQueue.main` past anything already enqueued — the
        /// queue the interruption observer is registered on. FIFO, so once
        /// this operation runs, a block enqueued before it has already run.
        private func drainMainQueue() async {
            await withCheckedContinuation { continuation in
                OperationQueue.main.addOperation { continuation.resume() }
            }
        }

        private func postInterruption(_ type: AVAudioSession.InterruptionType) {
            NotificationCenter.default.post(
                name: AVAudioSession.interruptionNotification,
                object: nil,
                userInfo: [AVAudioSessionInterruptionTypeKey: type.rawValue])
        }

        /// The live conversation's own observer drives *itself*. This is the
        /// half that fails against the pre-follow-up code, where the callback
        /// went to `AppModel.shared.conversation` — a different instance from
        /// the model under test, so the interruption reached nothing at all.
        @Test func aLiveControllersInterruptionObserverDrivesThatController() async {
            let (defaults, suiteName) = makeTestDefaults()
            defer { defaults.removePersistentDomain(forName: suiteName) }
            let gateway = GatewayRecorder()
            defer { gateway.finishAll() }

            let conversations = recorder(gates: [:])
            let model = await connectedModel(
                conversations: conversations, gateway: gateway, defaults: defaults)

            await model.startConversation(cwd: "/one")
            let live = conversations.launches[0].controller
            #expect(!live.audioInterrupted)

            postInterruption(.began)
            await drainMainQueue()

            #expect(live.audioInterrupted)
        }

        /// An interruption delivered after the replacement has taken over must
        /// change nothing on the superseded controller, and must not reach the
        /// conversation that is current now through it. The replacement has no
        /// observer of its own here — it is still inside `session.create` — so
        /// anything that moved would have come from the old controller.
        ///
        /// Scope, stated exactly: this covers delivery *after* teardown, which
        /// is deterministic. It does **not** cover the narrower window the
        /// `isTornDown` guards exist for — a block already enqueued on
        /// `OperationQueue.main` when `removeObserver` runs. That window is not
        /// reproducible in-process: `NotificationCenter`'s queued delivery
        /// blocks the posting thread until the main-queue block completes, so
        /// pinning the main thread across the enqueue deadlocks the poster
        /// (measured: the post times out at 5s and the block only runs once
        /// main is released). The guards are defended by construction, not by
        /// this test.
        @Test func aSupersededControllersInterruptionIsInert() async {
            let (defaults, suiteName) = makeTestDefaults()
            defer { defaults.removePersistentDomain(forName: suiteName) }
            let gateway = GatewayRecorder()
            defer { gateway.finishAll() }

            let held = CallGate()
            let conversations = recorder(gates: [1: held])
            let model = await connectedModel(
                conversations: conversations, gateway: gateway, defaults: defaults)

            await model.startConversation(cwd: "/one")
            let superseded = conversations.launches[0].controller
            #expect(!superseded.audioInterrupted)

            // Replacement takes ownership and is held inside session.create, so
            // it has not installed an observer of its own yet.
            let second = Task { await model.startConversation(cwd: "/two") }
            await held.waitUntilEntered()
            await model.pendingTeardown?.value
            let replacement = conversations.launches[1].controller
            #expect(model.conversation === replacement)

            postInterruption(.began)
            await drainMainQueue()

            #expect(!superseded.audioInterrupted)
            #expect(!replacement.audioInterrupted)
            #expect(model.conversation === replacement)

            await held.release()
            await second.value
            #expect(ConversationController.levelMeterOwner === replacement)
            #expect(AudioCaptureService.shared.hasLevelHandler)
        }

    #endif
}
