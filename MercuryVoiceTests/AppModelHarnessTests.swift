import Foundation
import HermesKit
import Testing

@testable import MercuryVoice

/// Smoke coverage for the app/controller test harness added by issue #81
/// (audit finding R31).
///
/// These prove the harness itself: that production defaults are untouched,
/// that tests are isolated from the user's real storage, that the real
/// `AppModel` methods run under test, and that a suspended auth call can be
/// held open and released deterministically. The behaviour fixes those
/// capabilities unblock (R02 and the other controller races) land on their
/// own branches.
@MainActor
@Suite("AppModel test harness")
struct AppModelHarnessTests {

    // MARK: Production defaults are unchanged

    @Test func liveDependenciesResolveToTheRealImplementations() {
        let live = AppDependencies.live
        #expect(live.credentialStore is KeychainTokenStore)
        #expect(live.authenticator is LiveAuthenticatingService)
        #expect(live.oauthSignIn is LiveOAuthSignIn)
        #expect(live.defaults === UserDefaults.standard)

        let endpoint = try! ServerEndpoint.parse("http://127.0.0.1:8080").endpoint
        let probe = live.makeProbe(
            endpoint, HermesAuthenticator(endpoint: endpoint, credentials: nil))
        #expect(probe is HermesRESTClient)
    }

    /// The default initializer — the one `AppModel.shared` uses — must still
    /// resolve to `.live`, not to anything test-shaped.
    @Test func defaultInitializerUsesLiveDependencies() {
        let model = AppModel()
        #expect(model.deps.defaults === UserDefaults.standard)
        #expect(model.deps.credentialStore is KeychainTokenStore)
    }

    // MARK: Storage isolation

    @Test func testDefaultsAreIsolatedFromStandard() {
        let (defaults, suiteName) = makeTestDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        #expect(defaults !== UserDefaults.standard)

        let servers = [AppModel.SavedServer(urlString: "http://10.0.0.9:8080")]
        defaults.set(try! JSONEncoder().encode(servers), forKey: "savedServers")

        let model = AppModel(dependencies: .scripted(defaults: defaults))
        #expect(model.savedServers.map(\.urlString) == ["http://10.0.0.9:8080"])
        // The real defaults were never consulted for this model.
        #expect(UserDefaults.standard.data(forKey: "savedServers") != defaults.data(forKey: "savedServers"))
    }

    // MARK: The real AppModel runs under test

    /// Drives the actual `connect(input:token:)` against a gated server and
    /// asserts it reaches the real `presentGatedLogin`, publishing the sign-in
    /// form. Nothing here is a reimplementation of the flow.
    @Test func connectAgainstGatedServerPresentsTheRealSignInForm() async {
        let (defaults, suiteName) = makeTestDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let auth = ScriptedAuthenticator()
        let model = AppModel(
            dependencies: .scripted(authenticator: auth, defaults: defaults))

        await model.connect(input: "http://127.0.0.1:8080", token: nil)

        #expect(model.pendingLogin?.endpoint.key == "http://127.0.0.1:8080")
        #expect(model.pendingLogin?.passwordProvider?.name == "basic")
        #expect(auth.providerEndpoints == ["http://127.0.0.1:8080"])
    }

    /// Item the whole harness exists for: hold a sign-in open, act while it is
    /// genuinely in flight, then release it — with no sleeping or polling.
    @Test func signInCanBeHeldOpenAndReleased() async {
        let (defaults, suiteName) = makeTestDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let gate = CallGate()
        let auth = ScriptedAuthenticator()
        auth.logInGate = gate
        let probes = ProbeRecorder()
        let model = AppModel(
            dependencies: .scripted(authenticator: auth, probes: probes, defaults: defaults))

        await model.connect(input: "http://127.0.0.1:8080", token: nil)
        #expect(model.pendingLogin != nil)

        let signIn = Task { await model.signIn(username: "alice", password: "hunter2") }
        await gate.waitUntilEntered()

        // The login is suspended inside AppModel right now: it has called the
        // authenticator and has not yet reached connect().
        #expect(auth.logInEndpoints == ["http://127.0.0.1:8080"])
        #expect(probes.endpoints == ["http://127.0.0.1:8080"])

        await gate.release()
        await signIn.value

        // Released: the login completed and drove a second connect attempt.
        #expect(probes.endpoints.count == 2)
    }

    /// Connection attempts are observable in order, which is the shape the
    /// R02 races are about (a stale flow replacing a newer connection).
    @Test func connectAttemptsAreRecordedInOrder() async {
        let (defaults, suiteName) = makeTestDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let probes = ProbeRecorder { _ in
            ScriptedProbe(statusResult: .failure(HermesError.malformedResponse("down")))
        }
        let model = AppModel(dependencies: .scripted(probes: probes, defaults: defaults))

        await model.connect(input: "http://127.0.0.1:8080", token: nil)
        await model.connect(input: "http://10.0.0.9:9090", token: nil)

        #expect(probes.endpoints == ["http://127.0.0.1:8080", "http://10.0.0.9:9090"])
        #expect(model.connectError != nil)
    }

    /// `cancelPasswordLogin` is the real "Back" button path.
    @Test func backDismissesTheSignInForm() async {
        let (defaults, suiteName) = makeTestDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let model = AppModel(dependencies: .scripted(defaults: defaults))
        await model.connect(input: "http://127.0.0.1:8080", token: nil)
        #expect(model.pendingLogin != nil)

        model.cancelPasswordLogin()
        #expect(model.pendingLogin == nil)
        #expect(model.connectError == nil)
    }
}
