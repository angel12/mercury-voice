import Foundation
import HermesKit
import Testing

@testable import MercuryVoice

/// Issue #88 — the Connect screen's *call site*, not the rule behind it.
///
/// `ConnectFormStateTests` already pins what `ConnectFormState` decides. These
/// tests pin that the shipping controls still ask it: they type into the
/// binding `ConnectView` handed its `TextField` and `SecureField`, and press
/// the closure it handed its Connect button. A field re-bound to a stray
/// `@State` string, a binding whose `set` writes a raw stored property again,
/// or a Connect button reading something other than what the fields wrote all
/// reintroduce R01's cross-server credential disclosure while every
/// `ConnectFormState` test stays green — so each of those is what fails here.
///
/// What these tests observe is the value each binding holds and the closure
/// each button was handed, not a rendered control: no keystroke is synthesised
/// and no repaint is awaited. Serialized so the hosted windows take the main
/// run loop one at a time; ownership does not depend on it, since each host
/// has its own recorder (`hostedViewsDoNotShareControls`).
@MainActor
@Suite("ConnectView field and Connect-button wiring", .serialized)
struct ConnectViewBindingTests {

    private static let serverA = "http://127.0.0.1:8080"
    private static let serverB = "http://127.0.0.1:9090"
    private static let dashboardA = "http://127.0.0.1:8080/?token=tokenA"

    /// A model whose `connect` runs for real up to the probe, which records
    /// the endpoint and credentials and then stops it.
    private func makeModel(
        defaults: UserDefaults, recorder: ConnectAttemptRecorder
    ) -> AppModel {
        var deps = AppDependencies.scripted(defaults: defaults)
        deps.makeProbe = { recorder.makeProbe($0, $1) }
        return AppModel(dependencies: deps)
    }

    /// The server field routes into `ConnectFormState`, and the token field
    /// reads back out of it: a pasted dashboard URL fills the token field.
    @Test func pastingADashboardURLFillsTheTokenField() async {
        let (defaults, suiteName) = makeTestDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let model = makeModel(defaults: defaults, recorder: ConnectAttemptRecorder())
        let host = await ConnectViewHost(model: model)
        defer { host.tearDown() }

        await host.type(Self.dashboardA, into: .server)

        #expect(host.text(of: .server) == Self.dashboardA)
        #expect(host.text(of: .token) == "tokenA")
    }

    /// R01 at the controls: pointing the server field somewhere else empties
    /// the token field, so the token cannot be carried across servers behind
    /// a secure-entry field.
    @Test func retargetingTheServerFieldEmptiesTheTokenField() async {
        let (defaults, suiteName) = makeTestDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let model = makeModel(defaults: defaults, recorder: ConnectAttemptRecorder())
        let host = await ConnectViewHost(model: model)
        defer { host.tearDown() }

        await host.type(Self.dashboardA, into: .server)
        #expect(host.text(of: .token) == "tokenA")

        await host.type(Self.serverB, into: .server)

        #expect(host.text(of: .server) == Self.serverB)
        #expect(host.text(of: .token) == "")
    }

    /// The Connect button sends exactly what the two fields hold — the
    /// endpoint the server field names, and the token the token field was
    /// typed into.
    @Test func connectSendsWhatTheFieldsHold() async throws {
        let (defaults, suiteName) = makeTestDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let recorder = ConnectAttemptRecorder()
        let model = makeModel(defaults: defaults, recorder: recorder)
        let host = await ConnectViewHost(model: model)
        defer { host.tearDown() }

        await host.type(Self.serverA, into: .server)
        await host.type("typed-token", into: .token)

        host.press(.connect)
        // The scripted probe fails validation, so a `connectError` is the
        // attempt's terminal state: waiting for it means the assertions below
        // — and the teardown after them — do not race the Connect task.
        #expect(await host.wait(for: { model.connectError != nil }))

        #expect(recorder.endpointKeys == [Self.serverA])
        let authenticator = try #require(recorder.authenticators.first)
        #expect(await authenticator.credentials == .sessionToken("typed-token"))
    }

    /// The disclosure the whole rule exists to stop, driven end to end through
    /// the shipping controls: a token auto-filled for one server is not sent
    /// to the next one the field names.
    @Test func connectDoesNotSendTheFirstServersTokenToTheSecond() async throws {
        let (defaults, suiteName) = makeTestDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let recorder = ConnectAttemptRecorder()
        let model = makeModel(defaults: defaults, recorder: recorder)
        let host = await ConnectViewHost(model: model)
        defer { host.tearDown() }

        await host.type(Self.dashboardA, into: .server)
        await host.type(Self.serverB, into: .server)

        host.press(.connect)
        #expect(await host.wait(for: { model.connectError != nil }))

        #expect(recorder.endpointKeys == [Self.serverB])
        let authenticator = try #require(recorder.authenticators.first)
        #expect(await authenticator.credentials == nil)
    }

    /// The token field's writes reach `ConnectFormState` as the user's own:
    /// a hand-typed token survives retargeting and is what Connect sends.
    @Test func connectSendsAHandTypedTokenToTheRetargetedServer() async throws {
        let (defaults, suiteName) = makeTestDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let recorder = ConnectAttemptRecorder()
        let model = makeModel(defaults: defaults, recorder: recorder)
        let host = await ConnectViewHost(model: model)
        defer { host.tearDown() }

        await host.type(Self.serverA, into: .server)
        await host.type("mine", into: .token)
        await host.type(Self.serverB, into: .server)

        #expect(host.text(of: .token) == "mine")

        host.press(.connect)
        #expect(await host.wait(for: { model.connectError != nil }))

        #expect(recorder.endpointKeys == [Self.serverB])
        let authenticator = try #require(recorder.authenticators.first)
        #expect(await authenticator.credentials == .sessionToken("mine"))
    }

    /// Two hosted views are two separate screens: each one's controls stay its
    /// own, and pressing Connect on one reaches only that one's model.
    @Test func hostedViewsDoNotShareControls() async throws {
        let (defaultsA, suiteA) = makeTestDefaults()
        defer { defaultsA.removePersistentDomain(forName: suiteA) }
        let (defaultsB, suiteB) = makeTestDefaults()
        defer { defaultsB.removePersistentDomain(forName: suiteB) }
        let attemptsA = ConnectAttemptRecorder()
        let attemptsB = ConnectAttemptRecorder()
        let modelA = makeModel(defaults: defaultsA, recorder: attemptsA)
        let modelB = makeModel(defaults: defaultsB, recorder: attemptsB)

        let hostA = await ConnectViewHost(model: modelA)
        defer { hostA.tearDown() }
        let hostB = await ConnectViewHost(model: modelB)

        await hostA.type(Self.serverA, into: .server)
        await hostA.type("token-a", into: .token)
        await hostB.type(Self.serverB, into: .server)

        #expect(hostA.text(of: .server) == Self.serverA)
        #expect(hostA.text(of: .token) == "token-a")
        #expect(hostB.text(of: .server) == Self.serverB)
        #expect(hostB.text(of: .token) == "")

        hostA.press(.connect)
        #expect(await hostA.wait(for: { modelA.connectError != nil }))
        #expect(attemptsA.endpointKeys == [Self.serverA])
        #expect(attemptsB.endpointKeys.isEmpty)

        // Tearing one host down drops that host's recordings and no others'.
        hostB.tearDown()
        await hostA.type(Self.serverB, into: .server)
        #expect(hostA.text(of: .server) == Self.serverB)
    }

    /// A `ConnectView` nobody handed a recorder to — the app's own window, in
    /// this same test process — must not take over the controls a test is
    /// driving, nor send that test's Connect to its own model.
    @Test func theAppsOwnConnectViewStaysOutOfATestsControls() async throws {
        let (defaults, suiteName) = makeTestDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let (liveDefaults, liveSuiteName) = makeTestDefaults()
        defer { liveDefaults.removePersistentDomain(forName: liveSuiteName) }
        let attempts = ConnectAttemptRecorder()
        let liveAttempts = ConnectAttemptRecorder()
        let model = makeModel(defaults: defaults, recorder: attempts)
        let liveModel = makeModel(defaults: liveDefaults, recorder: liveAttempts)

        let host = await ConnectViewHost(model: model)
        defer { host.tearDown() }
        await host.type(Self.serverA, into: .server)
        await host.type("typed-token", into: .token)

        // Control: the same view, in the same kind of window, *with* a
        // recorder does register — so the untouched recorders below are about
        // ownership, not about a view that never rendered. Its teardown drops
        // its own recordings only.
        let reference = ConnectControlRecorder()
        let referenceHost = await ConnectViewHost(model: liveModel, controls: reference)
        #expect(reference.field(.server) != nil)
        #expect(reference.action(.connect) != nil)
        referenceHost.tearDown()
        #expect(reference.field(.server) == nil)

        // Now the app's own configuration: no recorder anywhere.
        let live = await ConnectViewHost(ordinaryAppViewFor: liveModel)
        defer { live.tearDown() }

        #expect(reference.field(.server) == nil)
        #expect(reference.action(.connect) == nil)
        #expect(live.controls.field(.server) == nil)
        #expect(live.controls.action(.connect) == nil)
        #expect(host.text(of: .server) == Self.serverA)
        #expect(host.text(of: .token) == "typed-token")

        host.press(.connect)
        #expect(await host.wait(for: { model.connectError != nil }))
        #expect(attempts.endpointKeys == [Self.serverA])
        #expect(liveAttempts.endpointKeys.isEmpty)
        #expect(liveModel.connectError == nil)
    }
}
