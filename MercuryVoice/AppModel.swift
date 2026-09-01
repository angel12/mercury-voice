import Foundation
import HermesKit
import Observation
import SwiftUI

/// Root app state: server credentials, the live connection, and the
/// browse-screen data (profiles, projects, recent sessions).
@MainActor
@Observable
final class AppModel {
    /// One instance for the whole process: the scenes render it, and the
    /// App Intents (Siri Shortcuts, issue #23) reach it here.
    static let shared = AppModel()

    init() {
        #if os(iOS)
            ConversationActivityHooks.install(model: self)
        #endif
    }

    // MARK: Connection

    private(set) var connection: HermesConnection?
    private(set) var phase: HermesConnection.Phase = .stopped
    private(set) var serverStatus: ServerStatus?
    private(set) var endpoint: ServerEndpoint?
    var connectError: String?
    /// A keychain save or delete failed: the session may still work, but the
    /// credentials will not survive relaunch. Kept separate from
    /// `connectError` so it never reads as a connection failure.
    var credentialStoreError: String?

    var isConnected: Bool {
        if case .ready = phase { return true }
        // Stay on the browse screen through transient reconnects.
        if case .connecting = phase, connection != nil { return true }
        if case .disconnected = phase, connection != nil { return true }
        return false
    }

    // MARK: Browse data

    private(set) var profiles: [ProfileInfo] = []
    private(set) var profilesLoading = false
    var selectedProfile: String?
    private(set) var projectTree: ProjectTree?
    private(set) var recentSessions: [SessionSummary] = []
    private(set) var browseLoading = false
    var browseError: String?

    // MARK: Conversation

    var conversation: ConversationController?

    private let tokenStore = KeychainTokenStore()
    private var updatePump: Task<Void, Never>?

    /// Monotonic guard for the connect flow: `connect()` suspends across the
    /// status/validation probes, so an overlapping connect (second saved-server
    /// tap) or a disconnect can land mid-flight. Only the newest generation may
    /// publish state; stale tasks bail at each resume point instead of
    /// overwriting `connection` and orphaning a live gateway.
    private var connectGeneration = 0

    /// Same pattern for browse loads (issue #42): every refresh (and
    /// disconnect) bumps it, and in-flight loads re-check after each
    /// suspension so a stale response — an old server's, an old profile's, or
    /// just a superseded pull-to-refresh — can't overwrite newer browse state.
    private var browseGeneration = 0
    /// The profiles fetch is slow and unscoped-by-profile, so it lives in its
    /// own task guarded by `connectGeneration` and cancelled on disconnect.
    private var profilesTask: Task<Void, Never>?

    // MARK: Saved servers

    struct SavedServer: Codable, Identifiable {
        var urlString: String
        var id: String { urlString }
    }

    private(set) var savedServers: [SavedServer] =
        (try? JSONDecoder().decode(
            [SavedServer].self,
            from: UserDefaults.standard.data(forKey: "savedServers") ?? Data())) ?? []

    private func persistServers() {
        if let data = try? JSONEncoder().encode(savedServers) {
            UserDefaults.standard.set(data, forKey: "savedServers")
        }
    }

    func savedCredentials(for endpoint: ServerEndpoint) -> ServerCredentials? {
        tokenStore.credentials(for: endpoint)
    }

    func forgetServer(_ server: SavedServer) {
        savedServers.removeAll { $0.urlString == server.urlString }
        persistServers()
        if let parsed = try? ServerEndpoint.parse(server.urlString) {
            do {
                try tokenStore.deleteToken(for: parsed.endpoint)
            } catch {
                credentialStoreError = error.localizedDescription
            }
        }
    }

    // MARK: Connect flow

    /// Set when a gated server requires sign-in before the gateway can
    /// open. Carries whichever options the server advertises: a password
    /// provider, native-OAuth providers (issue #51), or both.
    struct PendingLogin: Equatable {
        var endpoint: ServerEndpoint
        var passwordProvider: AuthProviderInfo?
        var oauthProviders: [AuthProviderInfo] = []
        var prefillUsername: String = ""
    }
    private(set) var pendingLogin: PendingLogin?

    func autoConnectOnLaunch() async {
        guard connection == nil,
            let last = UserDefaults.standard.string(forKey: "lastServer"),
            let parsed = try? ServerEndpoint.parse(last),
            let credentials = tokenStore.credentials(for: parsed.endpoint)
        else { return }
        await connect(endpoint: parsed.endpoint, credentials: credentials)
    }

    /// Parse input (URL, host:port, or dashboard URL with `?token=`),
    /// validate, and open the gateway.
    func connect(input: String, token explicitToken: String?) async {
        connectError = nil
        do {
            let parsed = try ServerEndpoint.parse(input)
            let token = explicitToken?.isEmpty == false ? explicitToken : parsed.embeddedToken
            await connect(
                endpoint: parsed.endpoint,
                credentials: token.map { .sessionToken($0) })
        } catch {
            connectError = error.localizedDescription
        }
    }

    func connect(endpoint: ServerEndpoint, credentials: ServerCredentials?) async {
        disconnect()
        connectGeneration += 1
        let generation = connectGeneration
        connectError = nil
        credentialStoreError = nil
        pendingLogin = nil
        self.endpoint = endpoint

        // One authenticator shared by the probe and the connection, so a
        // token refresh done during validation carries into the gateway.
        // Rotations land back in the keychain.
        let store = tokenStore
        let authenticator = HermesAuthenticator(
            endpoint: endpoint, credentials: credentials
        ) { [weak self] rotated in
            do {
                try store.setCredentials(rotated, for: endpoint)
            } catch {
                // Runs off the main actor: hop back to publish the warning.
                // A rotation that outlives this connect attempt can leave a
                // stale warning behind, which is acceptable.
                Task { @MainActor in
                    self?.credentialStoreError = error.localizedDescription
                }
            }
        }
        let probe = HermesRESTClient(endpoint: endpoint, authenticator: authenticator)
        do {
            let status = try await probe.status()
            guard generation == connectGeneration else { return }
            serverStatus = status

            var isPasswordMode = false
            if case .password = credentials { isPasswordMode = true }
            if status.authRequired, !isPasswordMode {
                // Gated bind — a loopback session token can't authenticate.
                // Offer username/password sign-in when the server supports it.
                await presentGatedLogin(endpoint: endpoint, generation: generation)
                return
            }
            try await probe.validateToken()
            guard generation == connectGeneration else { return }
        } catch HermesError.sessionExpired {
            guard generation == connectGeneration else { return }
            await presentGatedLogin(
                endpoint: endpoint,
                note: HermesError.sessionExpired.errorDescription,
                generation: generation)
            return
        } catch let error as HermesError {
            guard generation == connectGeneration else { return }
            connectError = error.errorDescription
            return
        } catch {
            guard generation == connectGeneration else { return }
            connectError = "Could not reach \(endpoint.displayName): \(error.localizedDescription)"
            return
        }

        // Credentials are good — persist and open the gateway. A failed save
        // only costs the next launch's auto-connect, so warn and carry on.
        do {
            try tokenStore.setCredentials(credentials, for: endpoint)
        } catch {
            credentialStoreError = error.localizedDescription
        }
        UserDefaults.standard.set(endpoint.key, forKey: "lastServer")
        if !savedServers.contains(where: { $0.urlString == endpoint.key }) {
            savedServers.append(SavedServer(urlString: endpoint.key))
            persistServers()
        }

        let connection = HermesConnection(endpoint: endpoint, authenticator: authenticator)
        self.connection = connection
        startUpdatePump(connection)
        await connection.start()
    }

    /// Sign in to a gated server with the pending password provider, then
    /// connect with the minted tokens.
    func signIn(username: String, password: String) async {
        guard let pending = pendingLogin, let provider = pending.passwordProvider
        else { return }
        connectError = nil
        do {
            let session = try await HermesAuthenticator.logIn(
                endpoint: pending.endpoint,
                provider: provider.name,
                username: username,
                password: password)
            await connect(endpoint: pending.endpoint, credentials: .password(session))
        } catch let error as HermesError {
            connectError = error.errorDescription
        } catch {
            connectError = error.localizedDescription
        }
    }

    /// Sign in via the system browser against a native-OAuth provider
    /// (issue #51), then connect with the minted tokens.
    func signIn(oauthProvider provider: AuthProviderInfo) async {
        guard let pending = pendingLogin else { return }
        connectError = nil
        do {
            let session = try await NativeOAuthSignIn().signIn(
                endpoint: pending.endpoint, provider: provider)
            await connect(endpoint: pending.endpoint, credentials: .password(session))
        } catch LoopbackRedirectListener.RedirectError.cancelled {
            // User closed the browser sheet — stay on the sign-in form.
        } catch let error as HermesError {
            connectError = error.errorDescription
        } catch {
            connectError = error.localizedDescription
        }
    }

    func cancelPasswordLogin() {
        pendingLogin = nil
        connectError = nil
    }

    /// Look up the gated server's sign-in options and surface whichever the
    /// server advertises: the password form, native-OAuth browser sign-in
    /// (issue #51), or both. `generation` ties the mutation to the connect
    /// attempt that asked for it; pass nil when there is no competing
    /// connect flow (auth-expiry pump).
    private func presentGatedLogin(
        endpoint: ServerEndpoint, note: String? = nil, generation: Int? = nil
    ) async {
        let providers =
            (try? await HermesAuthenticator.authProviders(endpoint: endpoint)) ?? []
        if let generation, generation != connectGeneration { return }
        let passwordProvider = providers.first(where: \.supportsPassword)
        // OAuth buttons need the RFC 8252 broker: an older gateway can
        // register OAuth providers it only serves via browser cookies,
        // which this app can't use — require the native_pkce advertisement.
        let nativePKCE = serverStatus?.authFlows.contains("native_pkce") ?? false
        let oauthProviders = nativePKCE ? providers.filter { !$0.supportsPassword } : []
        guard passwordProvider != nil || !oauthProviders.isEmpty else {
            connectError =
                "This server's sign-in methods aren't supported by this app. Configure dashboard.basic_auth or an OAuth provider on a current Hermes gateway, or run it on loopback."
            return
        }
        var prefill = ""
        if case .password(let saved)? = tokenStore.credentials(for: endpoint) {
            prefill = saved.username
        }
        pendingLogin = PendingLogin(
            endpoint: endpoint,
            passwordProvider: passwordProvider,
            oauthProviders: oauthProviders,
            prefillUsername: prefill)
        connectError = note
    }

    /// Recovery UI for a dead credential. Which affordance helps depends on
    /// how this server authenticates: a gated server has a sign-in form to
    /// re-present, but a loopback token server has none — its token rotates
    /// with every backend restart, and the only fix is a fresh dashboard URL.
    /// Presenting the sign-in sheet there would offer a password the server
    /// doesn't accept.
    private func presentAuthRecovery(endpoint: ServerEndpoint) async {
        if case .sessionToken? = tokenStore.credentials(for: endpoint) {
            connectError =
                "\(endpoint.displayName) rejected the session token. It changes each time the "
                + "backend restarts — open the Hermes dashboard and paste its current URL "
                + "(or token) to reconnect."
            return
        }
        await presentGatedLogin(
            endpoint: endpoint, note: HermesError.sessionExpired.errorDescription)
    }

    func disconnect() {
        connectGeneration += 1  // invalidate any in-flight connect()
        browseGeneration += 1  // …and any in-flight browse load
        updatePump?.cancel()
        updatePump = nil
        profilesTask?.cancel()
        profilesTask = nil
        profilesLoading = false
        browseLoading = false
        browseError = nil
        let connection = connection
        let conversation = conversation
        self.connection = nil
        self.conversation = nil
        if connection != nil || conversation != nil {
            // Teardown closes the backend session over the gateway, so it
            // must complete before the connection stops.
            Task {
                await conversation?.teardown()
                await connection?.stop()
            }
        }
        phase = .stopped
        profiles = []
        projectTree = nil
        recentSessions = []
        selectedProfile = nil
    }

    /// Foreground recovery: probe a seemingly-ready socket with
    /// `gateway.ping` (a device wake / network switch can leave it half-open
    /// and indistinguishable from a long quiet turn — a failed probe closes
    /// it so the supervisor redials), skip any pending backoff, and re-arm a
    /// mic parked by a background start refusal (issue #31).
    func appBecameActive() {
        conversation?.appBecameActive()
        guard let connection else { return }
        Task {
            await connection.verifyConnection()
            await connection.pokeReconnect()
        }
    }

    private func startUpdatePump(_ connection: HermesConnection) {
        updatePump = Task { [weak self] in
            for await update in await connection.updates() {
                guard let self, !Task.isCancelled else { return }
                switch update {
                case .phase(let phase):
                    self.phase = phase
                    // The gateway's redial loop surfaces as disconnected →
                    // connecting → ready; the conversation UI shows its
                    // reconnecting indicator off this flag (issue #44).
                    if case .disconnected = phase {
                        self.conversation?.connectionLost()
                    }
                    if case .connecting = phase {
                        self.conversation?.connectionLost()
                    }
                    if case .ready(let isReconnect) = phase {
                        if !isReconnect {
                            await self.loadBrowseData()
                        }
                        await self.conversation?.connectionBecameReady(
                            isReconnect: isReconnect)
                    }
                    if case .authExpired = phase {
                        // Credentials are dead (dead refresh token, or the
                        // gateway closed the socket with 4401): back to the
                        // connect screen. Present BEFORE disconnect —
                        // disconnect cancels this pump task, and a cancelled
                        // task can't await the provider lookup.
                        if let endpoint = self.endpoint {
                            await self.presentAuthRecovery(endpoint: endpoint)
                        }
                        self.disconnect()
                        return
                    }
                case .event(let event):
                    self.conversation?.handle(event: event)
                }
            }
        }
    }

    // MARK: Browse data

    func loadBrowseData() async {
        guard let connection else { return }
        browseError = nil

        // Profiles are slow (walks skill trees) — load independently. REST
        // calls outlive connection.stop(), so a response from a previous
        // server could land here mid-connect; the generation check drops it
        // (it would otherwise satisfy the isEmpty gate above and block the
        // new server's profiles for the whole session).
        if profiles.isEmpty {
            profilesLoading = true
            profilesTask?.cancel()
            let generation = connectGeneration
            profilesTask = Task {
                defer {
                    if generation == connectGeneration { profilesLoading = false }
                }
                guard let loaded = try? await connection.rest.profiles(),
                    generation == connectGeneration
                else { return }
                profiles = loaded
                if selectedProfile == nil {
                    selectedProfile =
                        loaded.first(where: \.isDefault)?.name ?? loaded.first?.name
                }
                Self.cacheProfileNames(loaded.map(\.name))
            }
        }
        await refreshProjects()
    }

    func refreshProjects() async {
        guard let connection else { return }
        browseGeneration += 1  // supersede any in-flight load
        let generation = browseGeneration
        browseLoading = true
        defer {
            // A superseding refresh owns the flag now; only the newest
            // generation may clear it (or publish anything below).
            if generation == browseGeneration { browseLoading = false }
        }
        do {
            // Server-side profile scoping (current gateways bind the profile's
            // HERMES_HOME; older ones ignore the param and the client-side
            // preview filter in BrowseView still applies).
            let tree = try await connection.projectsTree(profile: selectedProfile)
            guard generation == browseGeneration else { return }
            projectTree = tree
            let profile = selectedProfile ?? "all"
            // The full recent list for the profile; the workspace page shows
            // the project-scoped grouping, so no de-duplication needed here.
            let sessions = try await connection.rest.profileSessions(profile: profile, limit: 30)
            guard generation == browseGeneration else { return }
            recentSessions = sessions
            browseError = nil
        } catch let error as HermesError {
            guard generation == browseGeneration else { return }
            if case .rpcError(HermesError.RPCCode.methodNotFound, _, _) = error {
                // Older backend without projects.* — degrade to grouping the
                // flat list by repo root / cwd.
                await degradeToFlatSessions(generation: generation)
            } else {
                browseError = error.errorDescription
            }
        } catch {
            guard generation == browseGeneration else { return }
            browseError = error.localizedDescription
        }
    }

    private func degradeToFlatSessions(generation: Int) async {
        guard let connection else { return }
        guard
            let sessions = try? await connection.rest.profileSessions(
                profile: selectedProfile ?? "all", limit: 50),
            generation == browseGeneration
        else { return }
        var groups: [String: [SessionSummary]] = [:]
        for session in sessions {
            let key = session.gitRepoRoot ?? session.cwd ?? ProjectInfo.noProjectID
            groups[key, default: []].append(session)
        }
        let projects = groups.map { key, rows -> ProjectInfo in
            var json: [String: JSONValue] = [
                "id": .string(key),
                "name": .string(
                    key == ProjectInfo.noProjectID
                        ? "Home" : (key as NSString).lastPathComponent),
            ]
            if key != ProjectInfo.noProjectID { json["primary_path"] = .string(key) }
            return ProjectInfo(json: .object(json))!
        }
        projectTree = ProjectTree(json: .object(["projects": .array([])]))
        projectTree?.projects = projects.sorted { $0.name < $1.name }
        recentSessions = sessions
    }

    func selectProfile(_ name: String) async {
        guard selectedProfile != name else { return }
        selectedProfile = name
        // A profile is a whole isolated HERMES_HOME — drop the stale rows so
        // the sessions page shows its loading state, then refresh everything.
        recentSessions = []
        projectTree = nil
        await refreshProjects()
    }

    // MARK: Conversation lifecycle

    func startConversation(cwd: String?, title: String? = nil) async {
        guard let connection else { return }
        let controller = ConversationController(
            connection: connection, profile: selectedProfile)
        conversation = controller
        await controller.begin(mode: .create(cwd: cwd, title: title))
    }

    func continueSession(_ session: SessionSummary) async {
        guard let connection else { return }
        let controller = ConversationController(
            connection: connection,
            profile: session.profile ?? selectedProfile)
        conversation = controller
        await controller.begin(mode: .resume(storedID: session.storedID))
    }

    func endConversation() {
        let conversation = conversation
        self.conversation = nil
        Task {
            await conversation?.teardown()
            await refreshProjects()
        }
    }

    // MARK: Siri Shortcuts (issue #23)

    private nonisolated static let cachedProfileNamesKey = "cachedProfileNames"

    /// Profile names last seen from the server, persisted so the Shortcuts
    /// profile picker has options while the app isn't connected.
    nonisolated static func cachedProfileNames() -> [String] {
        UserDefaults.standard.stringArray(forKey: cachedProfileNamesKey) ?? []
    }

    private static func cacheProfileNames(_ names: [String]) {
        UserDefaults.standard.set(names, forKey: cachedProfileNamesKey)
    }

    enum ShortcutStartError: LocalizedError {
        case notConfigured
        case connectFailed(String)

        var errorDescription: String? {
            switch self {
            case .notConfigured:
                return "Open Mercury Voice and connect to your server once first."
            case .connectFailed(let reason):
                return reason
            }
        }
    }

    /// Entry point for the start-a-session App Intent: connect with the
    /// saved server if needed, wait for the gateway, then open a new
    /// conversation with the requested profile. The launch task's
    /// autoConnect may already be mid-flight — both guard on `connection`,
    /// and `connect()`'s generation counter settles any overlap, so this
    /// just waits for a ready phase either way.
    func startSessionFromShortcut(profileName: String?) async throws {
        if connection == nil {
            await autoConnectOnLaunch()
        }
        guard connection != nil else { throw ShortcutStartError.notConfigured }

        let deadline = ContinuousClock.now.advanced(by: .seconds(20))
        while ContinuousClock.now < deadline {
            if case .ready = phase { break }
            if let error = connectError {
                throw ShortcutStartError.connectFailed(error)
            }
            try? await Task.sleep(for: .milliseconds(100))
        }
        guard case .ready = phase else {
            throw ShortcutStartError.connectFailed(
                "Timed out reaching \(endpoint?.displayName ?? "the server").")
        }

        if let profileName { selectedProfile = profileName }
        if conversation != nil { endConversation() }
        await startConversation(cwd: nil)
    }
}
