import Foundation
import HermesKit
import Testing

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
///
/// Everything the seam reads is `let`: the seam runs off the main actor, so
/// post-construction mutation would be an unsynchronised read even though a
/// test would in practice set it before handing the object over (#81 review).
final class ScriptedAuthenticator: AuthenticatingService, @unchecked Sendable {
    private let lock = NSLock()
    private var _logInEndpoints: [String] = []
    private var _providerEndpoints: [String] = []

    let providers: [AuthProviderInfo]
    let logInResult: Result<PasswordSession, any Error>
    /// When set, `logIn` suspends here until the test releases it.
    let logInGate: CallGate?
    /// When set, `authProviders` suspends here until the test releases it.
    let providersGate: CallGate?

    init(
        providers: [AuthProviderInfo] = [.passwordProvider],
        logInResult: Result<PasswordSession, any Error> = .success(.stub),
        logInGate: CallGate? = nil,
        providersGate: CallGate? = nil
    ) {
        self.providers = providers
        self.logInResult = logInResult
        self.logInGate = logInGate
        self.providersGate = providersGate
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

    /// An open (non-gated) server that validates, so `connect()` runs through
    /// to building a gateway.
    static var accepting: ScriptedProbe {
        ScriptedProbe(statusResult: .success(.open), validateResult: .success(()))
    }
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

/// Drives the gateway lifecycle without dialling anything (issue #55).
///
/// `HermesConnection`'s initialiser is inert — it stores the endpoint and
/// builds a REST client — so tests let `AppModel` construct the real actor and
/// simply never start it. That keeps the seam to three closures instead of a
/// protocol over the whole gateway.
final class GatewayRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var opened: [HermesConnection] = []
    private var stopped: [ObjectIdentifier] = []
    private var channels:
        [ObjectIdentifier: (
            stream: AsyncStream<HermesConnection.Update>,
            continuation: AsyncStream<HermesConnection.Update>.Continuation
        )] = [:]

    /// Connections `AppModel` opened, in order. Recorded in `start`, which
    /// `connect()` awaits directly, so this is settled by the time `connect`
    /// returns — unlike `updates`, which runs inside the pump's own task.
    ///
    /// This array retains every connection *deliberately*: `wasStopped` keys on
    /// `ObjectIdentifier`, which is only sound while the objects stay alive, or
    /// an address could be recycled and a stale identifier would match a new
    /// connection.
    var connections: [HermesConnection] { lock.withLock { opened } }
    var stoppedCount: Int { lock.withLock { stopped.count } }

    func wasStopped(_ connection: HermesConnection) -> Bool {
        lock.withLock { stopped.contains(ObjectIdentifier(connection)) }
    }

    /// Never dials.
    func start(_ connection: HermesConnection) {
        lock.withLock {
            if !opened.contains(where: { $0 === connection }) { opened.append(connection) }
            _ = channelLocked(connection)
        }
    }

    func stop(_ connection: HermesConnection) {
        lock.withLock { stopped.append(ObjectIdentifier(connection)) }
    }

    func updates(_ connection: HermesConnection) -> AsyncStream<HermesConnection.Update> {
        lock.withLock { channelLocked(connection).stream }
    }

    /// Deliver an update to the nth connection `AppModel` opened. `AsyncStream`
    /// buffers, so this is safe to call before the pump starts iterating.
    ///
    /// Fidelity gap worth knowing: the real `HermesConnection.updates()` yields
    /// the current phase on subscription; this does not, so a pump under test
    /// never sees an initial `.stopped`.
    ///
    /// `.phase(.ready)` is refused. `HermesConnection.rest` is a real
    /// `HermesRESTClient` built in the actor's initialiser, `nonisolated`, and
    /// *not* behind this seam — a `.ready(false)` would send `loadBrowseData`
    /// at a live network. This harness does not cover ready/browse behaviour;
    /// that needs a REST seam (#81 review).
    func send(
        _ update: HermesConnection.Update,
        toConnection index: Int,
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        if case .phase(let phase) = update, case .ready = phase {
            Issue.record(
                "GatewayRecorder cannot deliver .ready: HermesConnection.rest is not seamed, so loadBrowseData would hit the network.",
                sourceLocation: sourceLocation)
            return
        }
        sendUnchecked(update, toConnection: index)
    }

    /// Finish every stream. Call from a test's `defer` so a pump whose model
    /// went away does not stay suspended for the life of the process.
    func finishAll() {
        let all = lock.withLock { Array(channels.values.map(\.continuation)) }
        for continuation in all { continuation.finish() }
    }

    private func sendUnchecked(_ update: HermesConnection.Update, toConnection index: Int) {
        let continuation = lock.withLock {
            index < opened.count ? channelLocked(opened[index]).continuation : nil
        }
        continuation?.yield(update)
    }

    /// Caller holds `lock`.
    private func channelLocked(
        _ connection: HermesConnection
    ) -> (
        stream: AsyncStream<HermesConnection.Update>,
        continuation: AsyncStream<HermesConnection.Update>.Continuation
    ) {
        let key = ObjectIdentifier(connection)
        if let existing = channels[key] { return existing }
        let made = AsyncStream<HermesConnection.Update>.makeStream()
        let channel = (stream: made.stream, continuation: made.continuation)
        channels[key] = channel
        return channel
    }
}

@MainActor
final class ScriptedOAuthSignIn: OAuthSigningIn {
    let result: Result<PasswordSession, any Error>
    let gate: CallGate?
    private(set) var endpoints: [String] = []

    init(
        result: Result<PasswordSession, any Error> = .success(.stub),
        gate: CallGate? = nil
    ) {
        self.result = result
        self.gate = gate
    }

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

/// Scripted `projects.tree` / `project_sessions` / recents list (issue #76).
final class ScriptedBrowseService: BrowseServicing, @unchecked Sendable {
    private let lock = NSLock()
    private var trees: [Result<ProjectTree, any Error>] = []
    private var projectPages: [Result<[SessionSummary], any Error>] = []
    private var recentsPages: [Result<[SessionSummary], any Error>] = []
    private var _treeCalls: [(previewLimit: Int, profile: String?)] = []
    private var _projectCalls: [(projectID: String, profile: String?, sessionLimit: Int?)] = []
    private var _recentsCalls: [(profile: String, limit: Int, offset: Int)] = []

    var treeGate: CallGate?
    var projectSessionsGate: CallGate?
    var profileSessionsGate: CallGate?

    func enqueueTree(_ tree: ProjectTree) { lock.withLock { trees.append(.success(tree)) } }
    func enqueueTreeFailure(_ error: any Error) { lock.withLock { trees.append(.failure(error)) } }
    func enqueueProjectSessions(_ rows: [SessionSummary]) {
        lock.withLock { projectPages.append(.success(rows)) }
    }
    func enqueueProjectSessionsFailure(_ error: any Error) {
        lock.withLock { projectPages.append(.failure(error)) }
    }
    func enqueueRecents(_ rows: [SessionSummary]) {
        lock.withLock { recentsPages.append(.success(rows)) }
    }
    func enqueueRecentsFailure(_ error: any Error) {
        lock.withLock { recentsPages.append(.failure(error)) }
    }

    var treeCalls: [(previewLimit: Int, profile: String?)] { lock.withLock { _treeCalls } }
    var projectCalls: [(projectID: String, profile: String?, sessionLimit: Int?)] {
        lock.withLock { _projectCalls }
    }
    var recentsCalls: [(profile: String, limit: Int, offset: Int)] {
        lock.withLock { _recentsCalls }
    }

    func projectsTree(previewLimit: Int, profile: String?) async throws -> ProjectTree {
        lock.withLock { _treeCalls.append((previewLimit, profile)) }
        let next: Result<ProjectTree, any Error>? = lock.withLock {
            trees.isEmpty ? nil : trees.removeFirst()
        }
        if let treeGate { await treeGate.arrive() }
        guard let next else {
            throw HermesError.malformedResponse("no scripted projects.tree answer")
        }
        return try next.get()
    }

    func projectSessions(projectID: String, profile: String?, sessionLimit: Int?) async throws
        -> [SessionSummary]
    {
        lock.withLock { _projectCalls.append((projectID, profile, sessionLimit)) }
        let next: Result<[SessionSummary], any Error>? = lock.withLock {
            projectPages.isEmpty ? nil : projectPages.removeFirst()
        }
        if let projectSessionsGate { await projectSessionsGate.arrive() }
        guard let next else {
            throw HermesError.malformedResponse("no scripted project_sessions answer")
        }
        return try next.get()
    }

    func profileSessions(profile: String, limit: Int, offset: Int) async throws -> [SessionSummary]
    {
        lock.withLock { _recentsCalls.append((profile, limit, offset)) }
        let next: Result<[SessionSummary], any Error>? = lock.withLock {
            recentsPages.isEmpty ? nil : recentsPages.removeFirst()
        }
        if let profileSessionsGate { await profileSessionsGate.arrive() }
        guard let next else {
            throw HermesError.malformedResponse("no scripted profileSessions answer")
        }
        return try next.get()
    }
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
        gateway: GatewayRecorder = GatewayRecorder(),
        conversations: ConversationRecorder = ConversationRecorder(),
        browse: (any BrowseServicing)? = nil,
        defaults: UserDefaults
    ) -> AppDependencies {
        AppDependencies(
            credentialStore: credentialStore,
            authenticator: authenticator,
            makeProbe: { endpoint, _ in probes.make(endpoint) },
            oauthSignIn: oauthSignIn,
            defaults: defaults,
            startGateway: { gateway.start($0) },
            stopGateway: { gateway.stop($0) },
            gatewayUpdates: { gateway.updates($0) },
            makeConversation: { conversations.make(connection: $0, profile: $1) },
            makeBrowse: { connection in browse ?? connection })
    }
}
