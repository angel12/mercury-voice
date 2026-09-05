import Foundation
import HermesKit

@testable import MercuryVoice

// Controllable stand-ins for the seams in `AppDependencies` (issue #81).
// These exist so tests can drive the *real* `AppModel` methods — `connect`,
// `signIn`, `cancelPasswordLogin`, the auth-expiry recovery — without a
// network, a keychain, or the user's defaults.

/// In-memory credential store.
final class FakeCredentialStore: CredentialStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [String: ServerCredentials] = [:]
    /// Set to make writes fail, exercising the `credentialStoreError` path.
    var writeError: (any Error)?

    init(seed: [String: ServerCredentials] = [:]) { stored = seed }

    func credentials(for endpoint: ServerEndpoint) -> ServerCredentials? {
        lock.withLock { stored[endpoint.key] }
    }

    func setCredentials(_ credentials: ServerCredentials?, for endpoint: ServerEndpoint) throws {
        if let writeError { throw writeError }
        lock.withLock { stored[endpoint.key] = credentials }
    }

    func deleteToken(for endpoint: ServerEndpoint) throws {
        if let writeError { throw writeError }
        _ = lock.withLock { stored.removeValue(forKey: endpoint.key) }
    }
}

/// Authenticator whose two round-trips a test can hold open and release.
final class ScriptedAuthenticator: AuthenticatingService, @unchecked Sendable {
    private let lock = NSLock()
    private var _logInEndpoints: [String] = []
    private var _providerEndpoints: [String] = []

    var providers: [AuthProviderInfo]
    var logInResult: Result<PasswordSession, any Error>
    /// When set, `logIn` suspends here until the test releases it.
    var logInGate: CallGate?
    /// When set, `authProviders` suspends here until the test releases it.
    var providersGate: CallGate?

    init(
        providers: [AuthProviderInfo] = [.passwordProvider],
        logInResult: Result<PasswordSession, any Error> = .success(.stub)
    ) {
        self.providers = providers
        self.logInResult = logInResult
    }

    /// Endpoints `logIn` was called for, in order.
    var logInEndpoints: [String] { lock.withLock { _logInEndpoints } }
    var providerEndpoints: [String] { lock.withLock { _providerEndpoints } }

    func authProviders(endpoint: ServerEndpoint) async throws -> [AuthProviderInfo] {
        lock.withLock { _providerEndpoints.append(endpoint.key) }
        if let providersGate { await providersGate.arrive() }
        return providers
    }

    func logIn(
        endpoint: ServerEndpoint, provider: String, username: String, password: String
    ) async throws -> PasswordSession {
        lock.withLock { _logInEndpoints.append(endpoint.key) }
        if let logInGate { await logInGate.arrive() }
        return try logInResult.get()
    }
}

/// Probe that answers `connect()`'s two questions from a script.
struct ScriptedProbe: ServerProbing {
    var statusResult: Result<ServerStatus, any Error> = .success(.gated)
    /// Defaults to failing, so `connect()` returns before it would build a
    /// real `HermesConnection` and dial a socket.
    var validateResult: Result<Void, any Error> = .failure(
        HermesError.malformedResponse("probe stopped by test"))

    func status() async throws -> ServerStatus { try statusResult.get() }
    func validateToken() async throws { try validateResult.get() }
}

/// Records which endpoints `connect()` probed, in order. This is how a test
/// observes connection attempts and replacement ordering without abstracting
/// `HermesConnection` itself.
final class ProbeRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var _endpoints: [String] = []
    /// Probe returned for each call; defaults to the gated script.
    let probe: @Sendable (ServerEndpoint) -> ScriptedProbe

    init(probe: @escaping @Sendable (ServerEndpoint) -> ScriptedProbe = { _ in ScriptedProbe() }) {
        self.probe = probe
    }

    var endpoints: [String] { lock.withLock { _endpoints } }

    func make(_ endpoint: ServerEndpoint) -> ScriptedProbe {
        lock.withLock { _endpoints.append(endpoint.key) }
        return probe(endpoint)
    }
}

@MainActor
final class ScriptedOAuthSignIn: OAuthSigningIn {
    var result: Result<PasswordSession, any Error> = .success(.stub)
    var gate: CallGate?
    private(set) var endpoints: [String] = []

    func signIn(endpoint: ServerEndpoint, provider: AuthProviderInfo) async throws
        -> PasswordSession
    {
        endpoints.append(endpoint.key)
        if let gate { await gate.arrive() }
        return try result.get()
    }
}

// MARK: Fixtures

extension ServerStatus {
    /// A gated server: sign-in required, native-PKCE advertised.
    static var gated: ServerStatus {
        ServerStatus(
            raw: .object([
                "auth_required": .bool(true),
                "auth_flows": .array([.string("cookie"), .string("native_pkce")]),
            ]))
    }

    /// A loopback token server: no sign-in required.
    static var open: ServerStatus {
        ServerStatus(raw: .object(["auth_required": .bool(false)]))
    }
}

extension AuthProviderInfo {
    static var passwordProvider: AuthProviderInfo {
        AuthProviderInfo(
            json: .object([
                "name": .string("basic"),
                "display_name": .string("Basic"),
                "supports_password": .bool(true),
            ]))!
    }
}

extension PasswordSession {
    static var stub: PasswordSession {
        PasswordSession(
            provider: "basic", username: "alice", accessToken: "at", refreshToken: "rt")
    }
}

// MARK: Harness

/// Isolated `UserDefaults` so tests never read or write the real
/// `lastServer` / `savedServers`.
func makeTestDefaults(
    _ name: String = UUID().uuidString
) -> (defaults: UserDefaults, suiteName: String) {
    let suiteName = "MercuryVoiceTests.\(name)"
    guard let defaults = UserDefaults(suiteName: suiteName) else {
        fatalError("could not open test defaults suite")
    }
    defaults.removePersistentDomain(forName: suiteName)
    return (defaults, suiteName)
}

@MainActor
extension AppDependencies {
    /// Fully controllable dependencies. Every seam defaults to something inert
    /// so a test only has to name the one it cares about.
    static func scripted(
        credentialStore: FakeCredentialStore = FakeCredentialStore(),
        authenticator: ScriptedAuthenticator = ScriptedAuthenticator(),
        probes: ProbeRecorder = ProbeRecorder(),
        oauthSignIn: ScriptedOAuthSignIn = ScriptedOAuthSignIn(),
        defaults: UserDefaults
    ) -> AppDependencies {
        AppDependencies(
            credentialStore: credentialStore,
            authenticator: authenticator,
            makeProbe: { endpoint, _ in probes.make(endpoint) },
            oauthSignIn: oauthSignIn,
            defaults: defaults)
    }
}
