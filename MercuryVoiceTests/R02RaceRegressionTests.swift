import Foundation
import HermesKit
import Testing

@testable import MercuryVoice

/// R02 (issue #55): login and auth-expiry awaits bypass the connect-generation
/// checks, so a flow that has already been superseded can still publish state
/// or tear down a newer connection.
///
/// These are written against the seam-only tree, before any fence, so each one
/// reproduces the real defect rather than asserting the fix back to itself.
@MainActor
@Suite("R02 generation races")
struct R02RaceRegressionTests {
    private static let serverA = "http://127.0.0.1:8080"
    private static let serverB = "http://10.0.0.9:9090"

    // MARK: Race 1 — password sign-in

    /// A password login that completes after the user has moved to another
    /// server must not connect to the old one.
    @Test func stalePasswordLoginMustNotReplaceANewerConnection() async {
        let (defaults, suiteName) = makeTestDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let gate = CallGate()
        let auth = ScriptedAuthenticator(logInGate: gate)
        let probes = ProbeRecorder()
        let model = AppModel(
            dependencies: .scripted(authenticator: auth, probes: probes, defaults: defaults))

        await model.connect(input: Self.serverA, token: nil)
        #expect(model.pendingLogin?.endpoint.key == Self.serverA)

        let signIn = Task { await model.signIn(username: "alice", password: "hunter2") }
        await gate.waitUntilEntered()

        await model.connect(input: Self.serverB, token: nil)
        #expect(model.endpoint?.key == Self.serverB)

        await gate.release()
        await signIn.value

        #expect(probes.endpoints == [Self.serverA, Self.serverB])
        #expect(model.endpoint?.key == Self.serverB)
    }

    /// Tapping Back abandons the sign-in; a login that lands afterwards must
    /// not connect or write an error onto the screen the user returned to.
    @Test func passwordLoginAbandonedByBackMustNotConnect() async {
        let (defaults, suiteName) = makeTestDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let gate = CallGate()
        let auth = ScriptedAuthenticator(logInGate: gate)
        let probes = ProbeRecorder()
        let model = AppModel(
            dependencies: .scripted(authenticator: auth, probes: probes, defaults: defaults))

        await model.connect(input: Self.serverA, token: nil)
        let signIn = Task { await model.signIn(username: "alice", password: "hunter2") }
        await gate.waitUntilEntered()

        model.cancelPasswordLogin()
        #expect(model.pendingLogin == nil)

        await gate.release()
        await signIn.value

        // One probe only: the abandoned login must not have driven a connect.
        #expect(probes.endpoints == [Self.serverA])
        #expect(model.pendingLogin == nil)
    }

    // MARK: Race 2 — OAuth sign-in

    /// Same shape as race 1, over a browser sheet the user can leave open for
    /// as long as they like.
    @Test func staleOAuthLoginMustNotReplaceANewerConnection() async {
        let (defaults, suiteName) = makeTestDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let gate = CallGate()
        let oauth = ScriptedOAuthSignIn(gate: gate)
        let probes = ProbeRecorder()
        let model = AppModel(
            dependencies: .scripted(probes: probes, oauthSignIn: oauth, defaults: defaults))

        await model.connect(input: Self.serverA, token: nil)
        guard let provider = model.pendingLogin?.oauthProviders.first
            ?? model.pendingLogin?.passwordProvider
        else {
            Issue.record("no sign-in provider offered")
            return
        }

        let signIn = Task { await model.signIn(oauthProvider: provider) }
        await gate.waitUntilEntered()

        await model.connect(input: Self.serverB, token: nil)
        #expect(model.endpoint?.key == Self.serverB)

        await gate.release()
        await signIn.value

        #expect(probes.endpoints == [Self.serverA, Self.serverB])
        #expect(model.endpoint?.key == Self.serverB)
    }

    // MARK: Race 3 — auth-expiry recovery

    /// The one the audit comment got wrong: recovery for a dead endpoint runs
    /// with `generation: nil`, so a recovery that suspends while the user
    /// connects elsewhere both publishes a sign-in form for the dead server
    /// and disconnects the live one.
    @Test func staleAuthRecoveryMustNotDisconnectANewerConnection() async {
        let (defaults, suiteName) = makeTestDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let providersGate = CallGate()
        let auth = ScriptedAuthenticator(providersGate: providersGate)
        let gateway = GatewayRecorder()
        defer { gateway.finishAll() }
        let model = AppModel(
            dependencies: .scripted(
                authenticator: auth,
                probes: ProbeRecorder { _ in .accepting },
                gateway: gateway,
                defaults: defaults))

        // A is live.
        await model.connect(input: Self.serverA, token: nil)
        #expect(gateway.connections.count == 1)
        let pumpA = model.updatePump

        // A's credentials die; recovery suspends looking up sign-in options.
        gateway.send(.phase(.authExpired), toConnection: 0)
        await providersGate.waitUntilEntered()

        // The user connects to B in the meantime.
        await model.connect(input: Self.serverB, token: nil)
        #expect(gateway.connections.count == 2)
        let connectionB = gateway.connections[1]
        #expect(model.connection === connectionB)

        // A's recovery now completes. Two barriers, in order:
        //
        //  1. `pumpA.value` — recovery ran to the end, so any `disconnect()` it
        //     triggered has been *scheduled*. This terminates on the fixed path
        //     too: `connect(B)` already cancelled A's pump, independently of
        //     the bug, so the pump ends whether or not the stale recovery
        //     reaches `disconnect()`.
        //  2. `pendingTeardown.value` — that teardown has *run*, so any stop it
        //     performs has already happened. Without it, "B was not stopped"
        //     could pass merely because the teardown had not run yet.
        //
        // `pendingTeardown` holds only the latest teardown, so this argument is
        // scenario-specific rather than a general drain: the earlier teardown
        // here is the one `connect(B)` scheduled, and it can only stop **A**.
        // Any teardown capable of stopping B must be scheduled by A's recovery,
        // which happens before `pumpA` completes — so it is the latest one, and
        // barrier 2 covers it.
        await providersGate.release()
        await pumpA?.value
        await model.pendingTeardown?.value

        // It must neither publish a sign-in form for the dead server…
        #expect(model.pendingLogin == nil)
        // …nor tear down B.
        #expect(model.connection === connectionB)
        #expect(gateway.wasStopped(connectionB) == false)
    }

    // MARK: The fences must not suppress the current login

    /// A login nobody superseded still connects.
    @Test func currentPasswordLoginStillConnects() async {
        let (defaults, suiteName) = makeTestDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let probes = ProbeRecorder()
        let model = AppModel(dependencies: .scripted(probes: probes, defaults: defaults))

        await model.connect(input: Self.serverA, token: nil)
        #expect(model.pendingLogin != nil)

        await model.signIn(username: "alice", password: "hunter2")

        // Two probes: the gated connect, then the one the login drove.
        #expect(probes.endpoints == [Self.serverA, Self.serverA])
        #expect(model.endpoint?.key == Self.serverA)
    }

    /// A login nobody superseded still surfaces its error.
    @Test func currentPasswordLoginStillReportsItsError() async {
        let (defaults, suiteName) = makeTestDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let auth = ScriptedAuthenticator(
            logInResult: .failure(HermesError.malformedResponse("bad password")))
        let model = AppModel(dependencies: .scripted(authenticator: auth, defaults: defaults))

        await model.connect(input: Self.serverA, token: nil)
        model.connectError = nil

        await model.signIn(username: "alice", password: "wrong")

        #expect(model.connectError != nil)
        #expect(model.pendingLogin != nil, "the sign-in form stays up after a failure")
    }

    /// Same for OAuth.
    @Test func currentOAuthLoginStillConnects() async {
        let (defaults, suiteName) = makeTestDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let probes = ProbeRecorder()
        let model = AppModel(dependencies: .scripted(probes: probes, defaults: defaults))

        await model.connect(input: Self.serverA, token: nil)
        guard let provider = model.pendingLogin?.passwordProvider else {
            Issue.record("no provider offered")
            return
        }

        await model.signIn(oauthProvider: provider)

        #expect(probes.endpoints == [Self.serverA, Self.serverA])
        #expect(model.endpoint?.key == Self.serverA)
    }

    /// The OAuth catch arms are separate code from the password ones, so a
    /// current OAuth failure needs its own case (requested by Raoden).
    @Test func currentOAuthLoginStillReportsItsError() async {
        let (defaults, suiteName) = makeTestDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let oauth = ScriptedOAuthSignIn(
            result: .failure(HermesError.malformedResponse("oauth broker refused")))
        let model = AppModel(dependencies: .scripted(oauthSignIn: oauth, defaults: defaults))

        await model.connect(input: Self.serverA, token: nil)
        guard let provider = model.pendingLogin?.passwordProvider else {
            Issue.record("no provider offered")
            return
        }
        model.connectError = nil

        await model.signIn(oauthProvider: provider)

        #expect(model.connectError != nil)
        #expect(model.pendingLogin != nil, "the sign-in form stays up after a failure")
    }

    // MARK: Stale *failures* must not write onto the replacement flow

    /// Suppressing a stale success is not the same as suppressing a stale
    /// error: the catch arms are a separate path and would otherwise stamp an
    /// old server's failure onto the screen the user moved to.
    @Test func stalePasswordLoginFailureMustNotWriteOntoTheNewFlow() async {
        let (defaults, suiteName) = makeTestDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let gate = CallGate()
        let auth = ScriptedAuthenticator(
            logInResult: .failure(HermesError.malformedResponse("A rejected the password")),
            logInGate: gate)
        let model = AppModel(dependencies: .scripted(authenticator: auth, defaults: defaults))

        await model.connect(input: Self.serverA, token: nil)
        let signIn = Task { await model.signIn(username: "alice", password: "hunter2") }
        await gate.waitUntilEntered()

        await model.connect(input: Self.serverB, token: nil)
        #expect(model.connectError == nil)

        await gate.release()
        await signIn.value

        #expect(model.connectError == nil, "A's failure must not surface on B's form")
        #expect(model.pendingLogin?.endpoint.key == Self.serverB)
    }

    @Test func staleOAuthLoginFailureMustNotWriteOntoTheNewFlow() async {
        let (defaults, suiteName) = makeTestDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let gate = CallGate()
        let oauth = ScriptedOAuthSignIn(
            result: .failure(HermesError.malformedResponse("A's broker refused")),
            gate: gate)
        let model = AppModel(dependencies: .scripted(oauthSignIn: oauth, defaults: defaults))

        await model.connect(input: Self.serverA, token: nil)
        guard let provider = model.pendingLogin?.passwordProvider else {
            Issue.record("no provider offered")
            return
        }

        let signIn = Task { await model.signIn(oauthProvider: provider) }
        await gate.waitUntilEntered()

        await model.connect(input: Self.serverB, token: nil)
        #expect(model.connectError == nil)

        await gate.release()
        await signIn.value

        #expect(model.connectError == nil, "A's failure must not surface on B's form")
        #expect(model.pendingLogin?.endpoint.key == Self.serverB)
    }
}
