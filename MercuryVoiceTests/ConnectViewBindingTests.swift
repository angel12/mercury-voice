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
/// Serialized: the probe the controls register with is process-wide, so two
/// hosted views at once would read each other's fields.
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
    /// reads back out of it: a pasted dashboard URL fills the token on screen.
    @Test func pastingADashboardURLFillsTheTokenFieldOnScreen() async {
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
    @Test func retargetingTheServerFieldEmptiesTheTokenFieldOnScreen() async {
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
        #expect(await host.wait(for: { recorder.endpointKeys.count == 1 }))

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
        #expect(await host.wait(for: { recorder.endpointKeys.count == 1 }))

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
        #expect(await host.wait(for: { recorder.endpointKeys.count == 1 }))

        #expect(recorder.endpointKeys == [Self.serverB])
        let authenticator = try #require(recorder.authenticators.first)
        #expect(await authenticator.credentials == .sessionToken("mine"))
    }
}
