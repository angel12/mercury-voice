import HermesKit

/// The browse RPCs and REST list `AppModel` uses to populate sessions and
/// workspaces.
///
/// Seamed for the same reason `SessionServicing` is: `refreshProjects` and
/// older-session search suspend on `projects.tree`, `projects.project_sessions`, and
/// `/api/profiles/sessions`. The initial profiles list is on the same surface
/// so a test can hold `loadBrowseData` open without a live REST client.
/// `HermesConnection` stays concrete; this is only the listing surface.
protocol BrowseServicing: Sendable {
    func profiles() async throws -> [ProfileInfo]
    func projectsTree(previewLimit: Int, profile: String?) async throws -> ProjectTree
    func projectSessions(projectID: String, profile: String?, sessionLimit: Int?) async throws
        -> [SessionSummary]
    func profileSessions(profile: String, limit: Int, offset: Int) async throws -> [SessionSummary]
}

extension HermesConnection: BrowseServicing {
    func profiles() async throws -> [ProfileInfo] {
        try await rest.profiles()
    }

    func profileSessions(profile: String, limit: Int, offset: Int) async throws -> [SessionSummary] {
        try await rest.profileSessions(profile: profile, limit: limit, offset: offset)
    }
}
