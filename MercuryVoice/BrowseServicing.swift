import HermesKit

/// The browse RPCs and REST list `AppModel` uses to populate sessions and
/// workspaces.
///
/// Seamed for the same reason `SessionServicing` is: `refreshProjects` and
/// "show more" suspend on `projects.tree`, `projects.project_sessions`, and
/// `/api/profiles/sessions`. Tests have to script those answers and hold a
/// call open to prove a stale page cannot land after the user switches
/// workspace or profile. `HermesConnection` stays concrete; this is only the
/// listing surface.
protocol BrowseServicing: Sendable {
    func projectsTree(previewLimit: Int, profile: String?) async throws -> ProjectTree
    func projectSessions(projectID: String, profile: String?) async throws -> [SessionSummary]
    func profileSessions(profile: String, limit: Int, offset: Int) async throws -> [SessionSummary]
}

extension HermesConnection: BrowseServicing {
    func profileSessions(profile: String, limit: Int, offset: Int) async throws -> [SessionSummary] {
        try await rest.profileSessions(profile: profile, limit: limit, offset: offset)
    }
}
