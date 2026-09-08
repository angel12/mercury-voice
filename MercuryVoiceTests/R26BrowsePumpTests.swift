import Foundation
import HermesKit
import Testing

@testable import MercuryVoice

@MainActor
@Suite("Nonblocking browse refresh (R26)", .serialized)
struct R26BrowsePumpTests {
    private func profile(_ name: String = "default") -> ProfileInfo {
        ProfileInfo(json: .object(["name": .string(name), "is_default": .bool(true)]))!
    }

    fileprivate func script(_ browse: ScriptedBrowseService, name: String = "default") {
        browse.enqueueProfiles([profile(name)])
        browse.enqueueTree(ProjectTree(json: .object([:])))
        browse.enqueueRecents([])
    }

    fileprivate func model(
        _ browse: ScriptedBrowseService, _ gateway: GatewayRecorder,
        defaults: UserDefaults, auth: ScriptedAuthenticator = ScriptedAuthenticator(),
        conversations: ConversationRecorder = ConversationRecorder()
    ) async -> AppModel {
        gateway.allowsReady = true
        let model = AppModel(
            dependencies: .scripted(
                authenticator: auth, probes: ProbeRecorder { _ in .accepting },
                gateway: gateway, conversations: conversations, browse: browse, defaults: defaults))
        await model.connect(input: "http://127.0.0.1:8080", token: nil)
        return model
    }

    @Test func retrySupersedesInitialProfilesWithoutAnExtraTreeRefresh() async {
        let (defaults, suite) = makeTestDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let browse = ScriptedBrowseService()
        let first = CallGate()
        let second = CallGate()
        browse.profilesGate = first
        script(browse, name: "old")
        script(browse, name: "new")
        let gateway = GatewayRecorder()
        let model = await model(browse, gateway, defaults: defaults)
        gateway.send(.phase(.ready(isReconnect: false)), toConnection: 0)
        #expect(await eventuallyOnMain { browse.profileCallCount == 1 })
        let initial = model.browseTask
        browse.profilesGate = second
        let retry = Task { await model.refreshBrowseData() }
        #expect(await eventuallyOnMain { browse.profileCallCount == 2 })
        await first.release()
        await initial?.value
        #expect(model.profiles.isEmpty)
        #expect(model.profilesLoading)
        #expect(browse.treeCalls.isEmpty)
        await second.release()
        await retry.value
        #expect(model.profiles.map(\.name) == ["new"])
        #expect(browse.treeCalls.count == 1)
        #expect(browse.treeCalls.last?.profile == "new")
        let pump = model.updatePump
        model.disconnect()
        gateway.finishAll()
        await pump?.value
        await model.pendingTeardown?.value
    }

    @Test(arguments: ["profiles", "tree", "recents"], [false, true])
    func reconnectDropsLateBrowseResults(stage: String, failure: Bool) async {
        let (defaults, suite) = makeTestDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let browse = ScriptedBrowseService()
        let oldGate = CallGate()
        if stage == "profiles" { browse.profilesGate = oldGate }
        if stage == "tree" { browse.treeGate = oldGate }
        if stage == "recents" { browse.profileSessionsGate = oldGate }
        let error = HermesError.connectionClosed("old browse failure")
        if failure && stage == "profiles" {
            browse.enqueueProfilesFailure(error)
        } else {
            browse.enqueueProfiles([profile("old")])
        }
        if stage != "profiles" {
            if failure && stage == "tree" {
                browse.enqueueTreeFailure(error)
            } else {
                browse.enqueueTree(ProjectTree(json: .object([:])))
            }
        }
        if stage == "recents" {
            if failure { browse.enqueueRecentsFailure(error) } else { browse.enqueueRecents([]) }
        }
        let gateway = GatewayRecorder()
        let model = await model(browse, gateway, defaults: defaults)
        gateway.send(.phase(.ready(isReconnect: false)), toConnection: 0)
        #expect(
            await eventuallyOnMain {
                switch stage {
                case "profiles": browse.profileCallCount == 1
                case "tree": browse.treeCalls.count == 1
                default: browse.recentsCalls.count == 1
                }
            })
        // Capture handles BEFORE disconnect clears them. Releasing a gate is
        // not a completion barrier, and awaiting a now-nil property proves nothing.
        let oldTask = model.browseTask
        let oldPump = model.updatePump
        await model.connect(input: "http://127.0.0.1:8081", token: nil)
        let teardown = model.pendingTeardown
        #expect(oldTask?.isCancelled == true)
        #expect(model.browseTask == nil)
        browse.profilesGate = nil
        browse.treeGate = nil
        browse.profileSessionsGate = nil
        let newGate = CallGate()
        browse.profilesGate = newGate
        script(browse, name: "new")
        gateway.send(.phase(.ready(isReconnect: false)), toConnection: 1)
        #expect(await eventuallyOnMain { browse.profileCallCount == 2 })
        await oldGate.release()
        await oldTask?.value
        await oldPump?.value
        await teardown?.value
        #expect(model.profiles.isEmpty)
        #expect(model.projectTree == nil)
        #expect(model.recentSessions.isEmpty)
        #expect(model.profilesLoading)
        #expect(model.browseError == nil)
        #expect(gateway.stoppedCount == 1)
        await newGate.release()
        await model.browseTask?.value
        #expect(model.profiles.map(\.name) == ["new"])
        #expect(model.selectedProfile == "new")
        #expect(model.projectTree != nil)
        let count = browse.profileCallCount
        gateway.send(.phase(.ready(isReconnect: true)), toConnection: 1)
        gateway.finishAll()
        await model.updatePump?.value
        #expect(browse.profileCallCount == count)
        model.disconnect()
        await model.pendingTeardown?.value
    }

    @Test func profileSelectionSupersedesWaitingInitialRefresh() async {
        let (defaults, suite) = makeTestDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let browse = ScriptedBrowseService()
        let gate = CallGate()
        browse.profilesGate = gate
        script(browse)
        let gateway = GatewayRecorder()
        let model = await model(browse, gateway, defaults: defaults)
        gateway.send(.phase(.ready(isReconnect: false)), toConnection: 0)
        #expect(await eventuallyOnMain { browse.profileCallCount == 1 })
        let initial = model.browseTask
        await model.selectProfile("selected")
        await gate.release()
        await initial?.value
        #expect(model.selectedProfile == "selected")
        #expect(browse.treeCalls.count == 1)
        #expect(browse.treeCalls.first?.profile == "selected")
        let pump = model.updatePump
        model.disconnect()
        gateway.finishAll()
        await pump?.value
        await model.pendingTeardown?.value
    }

    @Test func cancelledOwnerCannotStartDependentRefresh() async {
        let (defaults, suite) = makeTestDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let browse = ScriptedBrowseService()
        let gate = CallGate()
        browse.profilesGate = gate
        script(browse)
        let gateway = GatewayRecorder()
        let model = await model(browse, gateway, defaults: defaults)
        gateway.send(.phase(.ready(isReconnect: false)), toConnection: 0)
        #expect(await eventuallyOnMain { browse.profileCallCount == 1 })
        let initial = model.browseTask
        initial?.cancel()
        await gate.release()
        await initial?.value
        #expect(model.profiles.isEmpty)
        #expect(browse.treeCalls.isEmpty)
        let pump = model.updatePump
        model.disconnect()
        #expect(model.browseTask == nil)
        gateway.finishAll()
        await pump?.value
        await model.pendingTeardown?.value
    }

    @Test(arguments: ["tree", "recents"])
    func reviewerCancellationAfterProfiles(stage: String) async {
        let (defaults, suite) = makeTestDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let browse = ScriptedBrowseService()
        let gate = CallGate()
        if stage == "tree" { browse.treeGate = gate } else { browse.profileSessionsGate = gate }
        script(browse)
        let gateway = GatewayRecorder()
        let model = await model(browse, gateway, defaults: defaults)
        gateway.send(.phase(.ready(isReconnect: false)), toConnection: 0)
        #expect(
            await eventuallyOnMain {
                stage == "tree" ? browse.treeCalls.count == 1 : browse.recentsCalls.count == 1
            })
        let owner = model.browseTask
        model.browseError = "reviewer sentinel"
        owner?.cancel()
        await gate.release()
        await owner?.value
        if stage == "tree" {
            #expect(model.projectTree == nil)
            #expect(browse.recentsCalls.isEmpty)
        } else {
            // Successful completion writes browseError=nil. Cancellation must not.
            #expect(model.browseError == "reviewer sentinel")
        }
        let pump = model.updatePump
        model.disconnect()
        gateway.finishAll()
        await pump?.value
        await model.pendingTeardown?.value
    }

    // Exercise typed/untyped catches and both routes into the flat fallback.
    // Gate snapshots are taken before call entry; drain the exact owner before
    // checking absence of publication or a further dependent request.
    @Test(
        arguments: ["tree", "recents", "fallback-tree", "fallback-recents"],
        ["success", "hermes", "cancellation", "unsupported"])
    func cancelledDependentCompletion(stage: String, outcome: String) async {
        let (defaults, suite) = makeTestDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let browse = ScriptedBrowseService()
        let gate = CallGate()
        let unsupported = HermesError.rpcError(
            code: HermesError.RPCCode.methodNotFound, message: "unsupported", data: nil)
        let failure: (any Error)? =
            switch outcome {
            case "hermes": HermesError.connectionClosed("late failure")
            case "cancellation": CancellationError()
            case "unsupported": unsupported
            default: nil
            }
        browse.enqueueProfiles([profile()])
        if stage == "tree" {
            browse.treeGate = gate
            if let failure {
                browse.enqueueTreeFailure(failure)
            } else {
                browse.enqueueTree(ProjectTree(json: .object([:])))
            }
        } else {
            browse.profileSessionsGate = gate
            if stage == "fallback-tree" {
                browse.enqueueTreeFailure(unsupported)
            } else {
                browse.enqueueTree(ProjectTree(json: .object([:])))
            }
            if stage == "fallback-recents" { browse.enqueueRecentsFailure(unsupported) }
            if let failure {
                browse.enqueueRecentsFailure(failure)
            } else {
                browse.enqueueRecents([])
            }
        }
        let gateway = GatewayRecorder()
        let model = await model(browse, gateway, defaults: defaults)
        gateway.send(.phase(.ready(isReconnect: false)), toConnection: 0)
        #expect(
            await eventuallyOnMain {
                stage == "tree" ? browse.treeCalls.count == 1 : browse.recentsCalls.count == 1
            })
        let completionGate: CallGate
        if stage == "fallback-recents" {
            completionGate = CallGate()
            browse.profileSessionsGate = completionGate
            await gate.release()
            #expect(await eventuallyOnMain { browse.recentsCalls.count == 2 })
        } else {
            completionGate = gate
        }
        let owner = model.browseTask
        model.browseError = "preserve error"
        owner?.cancel()
        await completionGate.release()
        await owner?.value
        #expect(model.browseError == "preserve error")
        #expect(!model.usesFlatFallback)
        #expect(!model.browseLoading)
        #expect(model.recentSessions.isEmpty)
        if stage == "tree" || stage == "fallback-tree" {
            #expect(model.projectTree == nil)
        }
        let expectedCalls = stage == "tree" ? 0 : (stage == "fallback-recents" ? 2 : 1)
        #expect(browse.recentsCalls.count == expectedCalls)
        let pump = model.updatePump
        model.disconnect()
        gateway.finishAll()
        await pump?.value
        await model.pendingTeardown?.value
    }

    @Test(arguments: ["tree", "recents", "fallback"], [false, true])
    func cancelledDependentCannotClearNewerLoading(stage: String, failure: Bool) async {
        let (defaults, suite) = makeTestDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let browse = ScriptedBrowseService()
        let oldGate = CallGate()
        browse.enqueueProfiles([profile()])
        let error = HermesError.connectionClosed("old failure")
        if stage == "tree" {
            browse.treeGate = oldGate
            if failure {
                browse.enqueueTreeFailure(error)
            } else {
                browse.enqueueTree(ProjectTree(json: .object([:])))
            }
        } else {
            browse.profileSessionsGate = oldGate
            if stage == "fallback" {
                browse.enqueueTreeFailure(
                    HermesError.rpcError(
                        code: HermesError.RPCCode.methodNotFound, message: "unsupported", data: nil)
                )
            } else {
                browse.enqueueTree(ProjectTree(json: .object([:])))
            }
            if failure { browse.enqueueRecentsFailure(error) } else { browse.enqueueRecents([]) }
        }
        let gateway = GatewayRecorder()
        let model = await model(browse, gateway, defaults: defaults)
        gateway.send(.phase(.ready(isReconnect: false)), toConnection: 0)
        #expect(
            await eventuallyOnMain {
                stage == "tree" ? browse.treeCalls.count == 1 : browse.recentsCalls.count == 1
            })
        let owner = model.browseTask
        owner?.cancel()
        let newGate = CallGate()
        browse.treeGate = newGate
        browse.profileSessionsGate = nil
        browse.enqueueTree(ProjectTree(json: .object([:])))
        browse.enqueueRecents([])
        let replacement = Task { await model.selectProfile("replacement") }
        #expect(await eventuallyOnMain { browse.treeCalls.count == 2 })
        model.browseError = "new generation"
        await oldGate.release()
        await owner?.value
        #expect(model.browseLoading)
        #expect(model.browseError == "new generation")
        #expect(model.selectedProfile == "replacement")
        #expect(!model.usesFlatFallback)
        await newGate.release()
        await replacement.value
        #expect(!model.browseLoading)
        #expect(model.browseError == nil)
        #expect(browse.treeCalls.last?.profile == "replacement")
        let pump = model.updatePump
        model.disconnect()
        gateway.finishAll()
        await pump?.value
        await model.pendingTeardown?.value
    }

    @Test func reviewerOldOwnerCannotCancelNewProfiles() async {
        let (defaults, suite) = makeTestDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let browse = ScriptedBrowseService()
        let first = CallGate()
        let second = CallGate()
        browse.profilesGate = first
        script(browse, name: "old")
        script(browse, name: "new")
        let gateway = GatewayRecorder()
        let model = await model(browse, gateway, defaults: defaults)
        gateway.send(.phase(.ready(isReconnect: false)), toConnection: 0)
        #expect(await eventuallyOnMain { browse.profileCallCount == 1 })
        let initial = model.browseTask
        browse.profilesGate = second
        let retry = Task { await model.refreshBrowseData() }
        #expect(await eventuallyOnMain { browse.profileCallCount == 2 })
        initial?.cancel()
        await first.release()
        await initial?.value
        #expect(model.profilesLoading)
        await second.release()
        await retry.value
        #expect(model.profiles.map(\.name) == ["new"])
        #expect(browse.treeCalls.count == 1)
        let pump = model.updatePump
        model.disconnect()
        gateway.finishAll()
        await pump?.value
        await model.pendingTeardown?.value
    }
}

// Only this browse test starts voice and owns the process-global meter.
// Keep the remaining browse fixtures outside the shared serialization boundary.
extension SharedMeterTests.R26VoiceStartBrowsePumpTests {
    // The gate establishes actual in-flight I/O, not a guessed sleep. Bounded
    // observable waits make RED fail cleanly; cleanup releases every producer.
    @Test func slowProfilesDoNotBlockPromptDisconnectOrAuthExpiry() async {
        let (defaults, suite) = makeTestDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let browse = ScriptedBrowseService()
        let gate = CallGate()
        browse.profilesGate = gate
        let fixture = R26BrowsePumpTests()
        fixture.script(browse)
        let gateway = GatewayRecorder()
        let providers = CallGate()
        let auth = ScriptedAuthenticator(providersGate: providers)
        let conversations = ConversationRecorder()
        conversations.script = { _, service in
            service.enqueueCreate(Fixtures.resumeResult(runtimeID: "rt", storedID: "st"))
        }
        let model = await fixture.model(
            browse, gateway, defaults: defaults, auth: auth,
            conversations: conversations)
        await model.startConversation(cwd: "/tmp")
        let controller = model.conversation
        let pump = model.updatePump
        gateway.send(.phase(.ready(isReconnect: false)), toConnection: 0)
        #expect(await eventuallyOnMain { browse.profileCallCount == 1 })
        let initialBrowse = model.browseTask
        gateway.send(
            .event(
                Fixtures.event(
                    Fixtures.approvalRequest(
                        sessionID: "rt", seq: 1, command: "ls", requestID: "req"))), toConnection: 0
        )
        #expect(await eventuallyOnMain { controller?.approval?.command == "ls" })
        gateway.send(
            .event(
                Fixtures.event(
                    Fixtures.messageComplete(
                        sessionID: "rt", seq: 2, text: "reply while browsing"))), toConnection: 0)
        #expect(
            await eventuallyOnMain {
                controller?.devMessages.contains { $0.text == "reply while browsing" } == true
            })
        gateway.send(.phase(.disconnected(reason: "closed")), toConnection: 0)
        #expect(await eventuallyOnMain { controller?.connectionHealthy == false })
        gateway.send(.phase(.authExpired), toConnection: 0)
        #expect(await eventuallyOnMain { auth.providerEndpoints.count == 1 })
        #expect(browse.treeCalls.isEmpty)
        #expect(model.profiles.isEmpty)
        // Bounded even in RED: release both gates before draining the pump.
        await providers.release()
        #expect(await eventuallyOnMain { model.connection == nil })
        let teardown = model.pendingTeardown
        #expect(initialBrowse?.isCancelled == true)
        await gate.release()
        gateway.finishAll()
        await pump?.value
        await initialBrowse?.value
        await teardown?.value
        #expect(ConversationController.levelMeterOwner == nil)
        #expect(model.connection == nil)
        #expect(model.profiles.isEmpty)
    }
}
