import AppIntents

/// Siri Shortcuts (issue #23): "start a new session", optionally with a
/// profile. Backed by AppModel.shared; the profile picker uses the names
/// cached from the last connected server so it works while the app is
/// closed.

/// A Hermes profile as Shortcuts sees it: just its name.
struct ProfileEntity: AppEntity {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Profile")
    static let defaultQuery = ProfileQuery()

    var id: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(id)")
    }
}

struct ProfileQuery: EntityQuery {
    func entities(for identifiers: [String]) async throws -> [ProfileEntity] {
        identifiers.map(ProfileEntity.init(id:))
    }

    func suggestedEntities() async throws -> [ProfileEntity] {
        AppModel.cachedProfileNames().map(ProfileEntity.init(id:))
    }
}

struct StartSessionIntent: AppIntent {
    static let title: LocalizedStringResource = "Start New Session"
    static let description = IntentDescription(
        "Connects to your Hermes server and starts a new voice session.")
    /// The conversation needs the UI (mic, captions, playback) — this is a
    /// foreground intent.
    static let openAppWhenRun = true

    @Parameter(title: "Profile")
    var profile: ProfileEntity?

    static var parameterSummary: some ParameterSummary {
        Summary("Start a new session with \(\.$profile)")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        try await AppModel.shared.startSessionFromShortcut(profileName: profile?.id)
        let suffix = profile.map { " with \($0.id)" } ?? ""
        return .result(dialog: "Starting a new session\(suffix).")
    }
}

struct HermesVoiceShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: StartSessionIntent(),
            phrases: [
                "Start a \(.applicationName) session",
                "Start a new \(.applicationName) session",
                "New \(.applicationName) session",
                "Start a \(.applicationName) session with \(\.$profile)",
            ],
            shortTitle: "New Session",
            systemImageName: "waveform")
    }
}
