import Foundation
import HermesKit

// Injection seams for `AppModel` (issue #81, audit finding R31).
//
// The app has no way to exercise `AppModel`'s connect / sign-in / recovery
// paths: the keychain, the two auth round-trips, the status probe, the OAuth
// browser sheet, and `UserDefaults` are all reached directly. Those are also
// exactly the points those paths *suspend* on, which is where the audit's
// generation races live (R02 and friends), so they are the seams tests need.
//
// `AppDependencies.live` is what production uses and it resolves to the same
// keychain, the same static `HermesAuthenticator` entry points, the same
// `HermesRESTClient`, the same `NativeOAuthSignIn`, and `UserDefaults.standard`
// the app has always used. `AppModel.shared` takes it by default, so no
// production call site changes.

/// Credential storage. `KeychainTokenStore` is the production implementation.
protocol CredentialStoring: Sendable {
    func credentials(for endpoint: ServerEndpoint) -> ServerCredentials?
    func setCredentials(_ credentials: ServerCredentials?, for endpoint: ServerEndpoint) throws
    func deleteToken(for endpoint: ServerEndpoint) throws
}

/// The two auth round-trips the sign-in and gated-login flows suspend on.
protocol AuthenticatingService: Sendable {
    func authProviders(endpoint: ServerEndpoint) async throws -> [AuthProviderInfo]
    func logIn(
        endpoint: ServerEndpoint, provider: String, username: String, password: String
    ) async throws -> PasswordSession
}

/// The status/validation probe `connect()` suspends on before it opens a
/// gateway. Deliberately only the two calls `connect()` makes.
protocol ServerProbing: Sendable {
    func status() async throws -> ServerStatus
    func validateToken() async throws
}

/// The RFC 8252 browser sign-in (issue #51).
@MainActor
protocol OAuthSigningIn {
    func signIn(endpoint: ServerEndpoint, provider: AuthProviderInfo) async throws
        -> PasswordSession
}

extension KeychainTokenStore: CredentialStoring {}
extension HermesRESTClient: ServerProbing {}

/// Production authenticator: a thin pass-through to the statics, so the
/// sequencing stays in `AppModel` rather than moving into HermesKit.
struct LiveAuthenticatingService: AuthenticatingService {
    func authProviders(endpoint: ServerEndpoint) async throws -> [AuthProviderInfo] {
        try await HermesAuthenticator.authProviders(endpoint: endpoint)
    }

    func logIn(
        endpoint: ServerEndpoint, provider: String, username: String, password: String
    ) async throws -> PasswordSession {
        try await HermesAuthenticator.logIn(
            endpoint: endpoint, provider: provider, username: username, password: password)
    }
}

@MainActor
struct LiveOAuthSignIn: OAuthSigningIn {
    func signIn(endpoint: ServerEndpoint, provider: AuthProviderInfo) async throws
        -> PasswordSession
    {
        // Named binding, not an inline temporary: NativeOAuthSignIn hands
        // itself to ASWebAuthenticationSession as a *weak* presentation
        // context provider, and newer compilers warn that an inline
        // `NativeOAuthSignIn().signIn(...)` receiver is released before the
        // weak slot is ever read.
        let oauth = NativeOAuthSignIn()
        return try await oauth.signIn(endpoint: endpoint, provider: provider)
    }
}

/// Everything `AppModel` reaches outside itself.
@MainActor
struct AppDependencies {
    var credentialStore: any CredentialStoring
    var authenticator: any AuthenticatingService
    var makeProbe: @Sendable (ServerEndpoint, HermesAuthenticator) -> any ServerProbing
    var oauthSignIn: any OAuthSigningIn
    var defaults: UserDefaults

    // Gateway lifecycle, as three closures over the concrete `HermesConnection`
    // rather than a protocol (issue #55). `AppModel` needs exactly these three
    // moments observable — when a gateway is started, when its updates are
    // consumed, and when it is stopped — and `HermesConnection`'s initialiser
    // is inert, so a test can let `AppModel` build the real actor and simply
    // never start it. Abstracting the whole gateway would mean a 14-member
    // protocol rippling into `ConversationController` for no added coverage.
    var startGateway: @Sendable (HermesConnection) async -> Void
    var stopGateway: @Sendable (HermesConnection) async -> Void
    var gatewayUpdates: @Sendable (HermesConnection) async -> AsyncStream<HermesConnection.Update>

    /// Builds the controller for one conversation launch (issue #77). The
    /// live value is the construction `startConversation`/`continueSession`
    /// did inline; the seam exists so the ownership tests can script
    /// `session.*` and swap the audio stack while `AppModel` runs its real
    /// launch path.
    var makeConversation: (HermesConnection, String?) -> ConversationController

    static var live: AppDependencies {
        AppDependencies(
            credentialStore: KeychainTokenStore(),
            authenticator: LiveAuthenticatingService(),
            makeProbe: { HermesRESTClient(endpoint: $0, authenticator: $1) },
            oauthSignIn: LiveOAuthSignIn(),
            defaults: .standard,
            startGateway: { await $0.start() },
            stopGateway: { await $0.stop() },
            gatewayUpdates: { await $0.updates() },
            makeConversation: { ConversationController(connection: $0, profile: $1) })
    }
}
