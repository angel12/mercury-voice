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
            tokenStore.deleteToken(for: parsed.endpoint)
        }
    }

    // MARK: Connect flow

    /// Set when a gated server advertises a username/password provider and
    /// the user must sign in before the gateway can open.
    struct PendingPasswordLogin: Equatable {
        var endpoint: ServerEndpoint
        var providerName: String
        var providerDisplayName: String
        var prefillUsername: String = ""
    }
    private(set) var pendingPasswordLogin: PendingPasswordLogin?

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
        pendingPasswordLogin = nil
        self.endpoint = endpoint

        // One authenticator shared by the probe and the connection, so a
        // token refresh done during validation carries into the gateway.
        // Rotations land back in the keychain.
        let store = tokenStore
        let authenticator = HermesAuthenticator(
            endpoint: endpoint, credentials: credentials
        ) { rotated in
            store.setCredentials(rotated, for: endpoint)
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

        // Credentials are good — persist and open the gateway.
        tokenStore.setCredentials(credentials, for: endpoint)
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
        guard let pending = pendingPasswordLogin else { return }
        connectError = nil
        do {
            let session = try await HermesAuthenticator.logIn(
                endpoint: pending.endpoint,
                provider: pending.providerName,
                username: username,
                password: password)
            await connect(endpoint: pending.endpoint, credentials: .password(session))
        } catch let error as HermesError {
            connectError = error.errorDescription
        } catch {
            connectError = error.localizedDescription
        }
    }

    func cancelPasswordLogin() {
        pendingPasswordLogin = nil
        connectError = nil
    }

    /// Look up the gated server's sign-in options; surface the password form
    /// when available, else explain that OAuth-only servers aren't supported.
    /// `generation` ties the mutation to the connect attempt that asked for it;
    /// pass nil when there is no competing connect flow (auth-expiry pump).
    private func presentGatedLogin(
        endpoint: ServerEndpoint, note: String? = nil, generation: Int? = nil
    ) async {
        let providers =
            (try? await HermesAuthenticator.authProviders(endpoint: endpoint)) ?? []
        if let generation, generation != connectGeneration { return }
        guard let passwordProvider = providers.first(where: \.supportsPassword) else {
            connectError =
                "This server only offers browser (OAuth) sign-in, which this app doesn't support. Configure dashboard.basic_auth on the server for username/password access, or run it on loopback."
            return
        }
        var prefill = ""
        if case .password(let saved)? = tokenStore.credentials(for: endpoint) {
            prefill = saved.username
        }
        pendingPasswordLogin = PendingPasswordLogin(
            endpoint: endpoint,
            providerName: passwordProvider.name,
            providerDisplayName: passwordProvider.displayName,
            prefillUsername: prefill)
        connectError = note
    }

    func disconnect() {
        connectGeneration += 1  // invalidate any in-flight connect()
        updatePump?.cancel()
        updatePump = nil
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

    /// Immediate re-dial on foreground (backoff skip), and a mic re-arm for
    /// an engine parked by a background start refusal (issue #31).
    func appBecameActive() {
        conversation?.appBecameActive()
        guard let connection else { return }
        Task { await connection.pokeReconnect() }
    }

    private func startUpdatePump(_ connection: HermesConnection) {
        updatePump = Task { [weak self] in
            for await update in await connection.updates() {
                guard let self, !Task.isCancelled else { return }
                switch update {
                case .phase(let phase):
                    self.phase = phase
                    if case .ready(let isReconnect) = phase {
                        if !isReconnect {
                            await self.loadBrowseData()
                        }
                        await self.conversation?.connectionBecameReady(
                            isReconnect: isReconnect)
                    }
                    if case .authExpired = phase {
                        // Dead refresh token: back to the connect screen with
                        // the sign-in form up. Present BEFORE disconnect —
                        // disconnect cancels this pump task, and a cancelled
                        // task can't await the provider lookup.
                        if let endpoint = self.endpoint {
                            await self.presentGatedLogin(
                                endpoint: endpoint,
                                note: HermesError.sessionExpired.errorDescription)
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

        // Profiles are slow (walks skill trees) — load independently.
        if profiles.isEmpty {
            profilesLoading = true
            Task {
                defer { profilesLoading = false }
                if let loaded = try? await connection.rest.profiles() {
                    profiles = loaded
                    if selectedProfile == nil {
                        selectedProfile =
                            loaded.first(where: \.isDefault)?.name ?? loaded.first?.name
                    }
                    Self.cacheProfileNames(loaded.map(\.name))
                }
            }
        }
        await refreshProjects()
    }

    func refreshProjects() async {
        guard let connection else { return }
        browseLoading = true
        defer { browseLoading = false }
        do {
            projectTree = try await connection.projectsTree()
            let profile = selectedProfile ?? "all"
            // The full recent list for the profile; the workspace page shows
            // the project-scoped grouping, so no de-duplication needed here.
            recentSessions = try await connection.rest.profileSessions(profile: profile, limit: 30)
            browseError = nil
        } catch let error as HermesError {
            if case .rpcError(HermesError.RPCCode.methodNotFound, _) = error {
                // Older backend without projects.* — degrade to grouping the
                // flat list by repo root / cwd.
                await degradeToFlatSessions()
            } else {
                browseError = error.errorDescription
            }
        } catch {
            browseError = error.localizedDescription
        }
    }

    private func degradeToFlatSessions() async {
        guard let connection else { return }
        guard
            let sessions = try? await connection.rest.profileSessions(
                profile: selectedProfile ?? "all", limit: 50)
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
