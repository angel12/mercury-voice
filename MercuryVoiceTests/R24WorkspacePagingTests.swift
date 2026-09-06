import Foundation
import HermesKit
import Testing

@testable import MercuryVoice

/// R24 (issue #76): the workspace page only rendered `projects.tree` preview
/// rows (default 3), `projectSessions` had no caller, and the flat fallback
/// built groups with no session rows while swallowing REST failures.
///
/// These drive the real `AppModel.refreshProjects` / `selectProfile` /
/// `loadMore*` path through the browse seam — not a helper reimplementation.
@MainActor
@Suite("Workspace session paging (R24)")
struct R24WorkspacePagingTests {
    private static let server = "http://127.0.0.1:8080"
    private static let workspaceID = "p_mercury"
    private static var methodNotFound: HermesError {
        .rpcError(code: HermesError.RPCCode.methodNotFound, message: "Method not found", data: nil)
    }

    // MARK: Harness

    private func connectedModel(
        browse: ScriptedBrowseService,
        gateway: GatewayRecorder = GatewayRecorder(),
        defaults: UserDefaults
    ) async -> AppModel {
        let model = AppModel(
            dependencies: .scripted(
                probes: ProbeRecorder { _ in .accepting },
                gateway: gateway,
                browse: browse,
                defaults: defaults))
        await model.connect(input: Self.server, token: "session-token")
        #expect(model.connection != nil)
        return model
    }

    // MARK: Preview cap + project_sessions expansion

    /// A workspace with more sessions than the preview must keep the extra
    /// rows unreachable until "show more" calls `project_sessions`.
    @Test func showMoreLoadsSessionsPastThePreviewCap() async throws {
        let (defaults, suiteName) = makeTestDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let previews = (1...3).map { session("preview-\($0)") }
        let full = previews + (4...7).map { session("older-\($0)") }
        let browse = ScriptedBrowseService()
        browse.enqueueTree(tree(previews: previews, sessionCount: 7))
        browse.enqueueRecents(previews)
        browse.enqueueProjectSessions(full)

        let gateway = GatewayRecorder()
        defer { gateway.finishAll() }
        let model = await connectedModel(browse: browse, gateway: gateway, defaults: defaults)
        await model.refreshProjects()

        let project = try #require(model.projectTree?.projects.first { $0.id == Self.workspaceID })
        #expect(model.sessions(for: project).map(\.storedID) == previews.map(\.storedID))
        #expect(model.hasMoreSessions(in: project))
        #expect(browse.treeCalls.map(\.previewLimit) == [AppModel.workspacePreviewLimit])

        await model.loadMoreProjectSessions(Self.workspaceID)

        #expect(model.sessions(for: project).map(\.storedID) == full.map(\.storedID))
        #expect(!model.hasMoreSessions(in: project))
        #expect(browse.projectCalls.map(\.projectID) == [Self.workspaceID])
        #expect(browse.projectCalls.map(\.sessionLimit) == [AppModel.workspaceSessionPageSize])
        #expect(model.projectSessionErrors[Self.workspaceID] == nil)
    }

    /// `projects.project_sessions` has no offset — only `session_limit`, a
    /// newest-first scan. A page that fills that limit must keep Show more
    /// and the next call must raise the limit rather than treat the first
    /// page as complete.
    @Test func workspaceSessionsPastTheFirstServerLimitKeepShowMore() async throws {
        let (defaults, suiteName) = makeTestDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let pageSize = AppModel.workspaceSessionPageSize
        let firstPage = (1...pageSize).map { session("ws-\($0)") }
        let full = firstPage + [session("ws-\(pageSize + 1)")]
        let browse = ScriptedBrowseService()
        browse.enqueueTree(tree(previews: Array(firstPage.prefix(3)), sessionCount: full.count))
        browse.enqueueRecents(Array(firstPage.prefix(3)))
        browse.enqueueProjectSessions(firstPage)
        browse.enqueueProjectSessions(full)

        let gateway = GatewayRecorder()
        defer { gateway.finishAll() }
        let model = await connectedModel(browse: browse, gateway: gateway, defaults: defaults)
        await model.refreshProjects()

        let project = try #require(model.projectTree?.projects.first { $0.id == Self.workspaceID })
        #expect(model.hasMoreSessions(in: project))

        await model.loadMoreProjectSessions(Self.workspaceID)

        #expect(model.sessions(for: project).map(\.storedID) == firstPage.map(\.storedID))
        #expect(model.hasMoreSessions(in: project))
        #expect(browse.projectCalls.map(\.sessionLimit) == [pageSize])

        await model.loadMoreProjectSessions(Self.workspaceID)

        #expect(model.sessions(for: project).map(\.storedID) == full.map(\.storedID))
        #expect(!model.hasMoreSessions(in: project))
        #expect(browse.projectCalls.map(\.sessionLimit) == [pageSize, pageSize * 2])
        #expect(browse.projectCalls.map(\.projectID) == [Self.workspaceID, Self.workspaceID])
    }

    /// Exact preview-count match with a known total must not offer "show more".
    @Test func exactPreviewBoundaryDoesNotOfferMore() async throws {
        let (defaults, suiteName) = makeTestDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let previews = (1...3).map { session("exact-\($0)") }
        let browse = ScriptedBrowseService()
        browse.enqueueTree(tree(previews: previews, sessionCount: 3))
        browse.enqueueRecents(previews)

        let gateway = GatewayRecorder()
        defer { gateway.finishAll() }
        let model = await connectedModel(browse: browse, gateway: gateway, defaults: defaults)
        await model.refreshProjects()

        let project = try #require(model.projectTree?.projects.first { $0.id == Self.workspaceID })
        #expect(model.sessions(for: project).count == 3)
        #expect(!model.hasMoreSessions(in: project))
    }

    // MARK: Recents paging

    @Test func recentsPagePastTheRecentLimit() async {
        let (defaults, suiteName) = makeTestDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let page1 = (1...AppModel.recentsPageSize).map { session("recent-\($0)") }
        let page2 = (1...5).map { session("older-recent-\($0)") }
        let browse = ScriptedBrowseService()
        browse.enqueueTree(tree(previews: Array(page1.prefix(3)), sessionCount: 35))
        browse.enqueueRecents(page1)
        browse.enqueueRecents(page2)

        let gateway = GatewayRecorder()
        defer { gateway.finishAll() }
        let model = await connectedModel(browse: browse, gateway: gateway, defaults: defaults)
        await model.refreshProjects()

        #expect(model.recentSessions.count == AppModel.recentsPageSize)
        #expect(model.recentsHasMore)
        #expect(browse.recentsCalls.map(\.offset) == [0])

        await model.loadMoreRecentSessions()

        #expect(model.recentSessions.map(\.storedID) == (page1 + page2).map(\.storedID))
        #expect(!model.recentsHasMore)
        #expect(browse.recentsCalls.map(\.offset) == [0, AppModel.recentsPageSize])
        #expect(browse.recentsCalls.map(\.limit) == [
            AppModel.recentsPageSize, AppModel.recentsPageSize,
        ])
    }

    /// Overlapping pages must advance the server offset by the raw page
    /// length, not by unique displayed rows. Offsets stay `[0, 30, 60]`.
    @Test func recentsOverlappingPagesAdvanceTheServerOffset() async {
        let (defaults, suiteName) = makeTestDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let pageSize = AppModel.recentsPageSize
        let page1 = (1...pageSize).map { session("recent-\($0)") }
        let overlap = page1[pageSize - 1]
        let page2New = (pageSize + 1...pageSize * 2 - 1).map { session("recent-\($0)") }
        let page2 = [overlap] + page2New
        let page3 = (pageSize * 2 + 1...pageSize * 2 + 5).map { session("recent-\($0)") }
        let browse = ScriptedBrowseService()
        browse.enqueueTree(tree(previews: Array(page1.prefix(3)), sessionCount: 65))
        browse.enqueueRecents(page1)
        browse.enqueueRecents(page2)
        browse.enqueueRecents(page3)

        let gateway = GatewayRecorder()
        defer { gateway.finishAll() }
        let model = await connectedModel(browse: browse, gateway: gateway, defaults: defaults)
        await model.refreshProjects()
        #expect(browse.recentsCalls.map(\.offset) == [0])

        await model.loadMoreRecentSessions()
        #expect(model.recentSessions.count == pageSize + page2New.count)
        #expect(model.recentsHasMore)
        #expect(browse.recentsCalls.map(\.offset) == [0, pageSize])

        await model.loadMoreRecentSessions()
        #expect(model.recentSessions.map(\.storedID) == (page1 + page2New + page3).map(\.storedID))
        #expect(!model.recentsHasMore)
        #expect(browse.recentsCalls.map(\.offset) == [0, pageSize, pageSize * 2])
    }

    /// Duplicates inside one fetched page are dropped, but the consumed
    /// offset still advances by that page's raw length.
    @Test func recentsDedupWithinAPageAndStillAdvanceRawOffset() async {
        let (defaults, suiteName) = makeTestDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let pageSize = AppModel.recentsPageSize
        let page1 = (1...pageSize).map { session("recent-\($0)") }
        let uniqueTail = (pageSize + 2...pageSize * 2 - 1).map { session("recent-\($0)") }
        let withinPage = session("recent-\(pageSize + 1)")
        let page2 = [withinPage, withinPage] + uniqueTail
        #expect(page2.count == pageSize)
        let page3 = [session("recent-\(pageSize * 2 + 1)")]
        let browse = ScriptedBrowseService()
        browse.enqueueTree(tree(previews: Array(page1.prefix(3)), sessionCount: 62))
        browse.enqueueRecents(page1)
        browse.enqueueRecents(page2)
        browse.enqueueRecents(page3)

        let gateway = GatewayRecorder()
        defer { gateway.finishAll() }
        let model = await connectedModel(browse: browse, gateway: gateway, defaults: defaults)
        await model.refreshProjects()

        await model.loadMoreRecentSessions()
        #expect(model.recentSessions.map(\.storedID) == (page1 + [withinPage] + uniqueTail).map(\.storedID))
        #expect(model.recentsHasMore)
        #expect(browse.recentsCalls.map(\.offset) == [0, pageSize])

        await model.loadMoreRecentSessions()
        #expect(browse.recentsCalls.map(\.offset) == [0, pageSize, pageSize * 2])
        #expect(model.recentSessions.last?.storedID == "recent-\(pageSize * 2 + 1)")
    }

    /// A failed recents page must retry at the same offset, not skip ahead.
    @Test func recentsFailedPageRetriesTheSameOffset() async {
        let (defaults, suiteName) = makeTestDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let pageSize = AppModel.recentsPageSize
        let page1 = (1...pageSize).map { session("recent-\($0)") }
        let page2 = (1...5).map { session("older-recent-\($0)") }
        let browse = ScriptedBrowseService()
        browse.enqueueTree(tree(previews: Array(page1.prefix(3)), sessionCount: 35))
        browse.enqueueRecents(page1)
        browse.enqueueRecentsFailure(HermesError.httpError(status: 503, detail: "down"))
        browse.enqueueRecents(page2)

        let gateway = GatewayRecorder()
        defer { gateway.finishAll() }
        let model = await connectedModel(browse: browse, gateway: gateway, defaults: defaults)
        await model.refreshProjects()
        #expect(model.recentsHasMore)

        await model.loadMoreRecentSessions()
        #expect(model.browseError != nil)
        #expect(model.recentSessions.count == pageSize)
        #expect(model.recentsHasMore)
        #expect(browse.recentsCalls.map(\.offset) == [0, pageSize])

        await model.loadMoreRecentSessions()
        #expect(model.browseError == nil)
        #expect(model.recentSessions.map(\.storedID) == (page1 + page2).map(\.storedID))
        #expect(!model.recentsHasMore)
        #expect(browse.recentsCalls.map(\.offset) == [0, pageSize, pageSize])
    }

    // MARK: Flat fallback

    @Test func fallbackPopulatesWorkspaceRowsAndPages() async throws {
        let (defaults, suiteName) = makeTestDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let page1 = (1...AppModel.recentsPageSize).map {
            session("flat-\($0)", cwd: "/Users/dev/mercury-voice")
        }
        let page2 = [session("flat-older", cwd: "/Users/dev/other")]
        let browse = ScriptedBrowseService()
        browse.enqueueTreeFailure(Self.methodNotFound)
        browse.enqueueRecents(page1)
        browse.enqueueRecents(page2)

        let gateway = GatewayRecorder()
        defer { gateway.finishAll() }
        let model = await connectedModel(browse: browse, gateway: gateway, defaults: defaults)
        await model.refreshProjects()

        #expect(model.usesFlatFallback)
        #expect(model.browseError == nil)
        let grouped = try #require(model.projectTree?.projects)
        #expect(grouped.contains { $0.previewSessions.count == AppModel.recentsPageSize })
        #expect(model.recentSessions.count == AppModel.recentsPageSize)
        #expect(model.recentsHasMore)

        await model.loadMoreRecentSessions()

        #expect(model.recentSessions.count == AppModel.recentsPageSize + 1)
        #expect(model.projectTree?.projects.contains { $0.id == "/Users/dev/other" } == true)
        #expect(!model.recentsHasMore)
    }

    @Test func failedFallbackSurfacesAnErrorAndRetryRecovers() async throws {
        let (defaults, suiteName) = makeTestDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let rows = [session("recovered", cwd: "/Users/dev/mercury-voice")]
        let browse = ScriptedBrowseService()
        browse.enqueueTreeFailure(Self.methodNotFound)
        browse.enqueueRecentsFailure(HermesError.httpError(status: 503, detail: "down"))
        browse.enqueueTreeFailure(Self.methodNotFound)
        browse.enqueueRecents(rows)

        let gateway = GatewayRecorder()
        defer { gateway.finishAll() }
        let model = await connectedModel(browse: browse, gateway: gateway, defaults: defaults)
        await model.refreshProjects()

        #expect(model.browseError != nil)
        #expect(model.projectTree == nil)
        #expect(model.recentSessions.isEmpty)

        await model.refreshProjects()

        #expect(model.browseError == nil)
        let recovered = try #require(model.projectTree?.projects.first)
        #expect(model.sessions(for: recovered).count == 1)
    }

    // MARK: Request ownership

    /// A `project_sessions` response that finishes after the user switched
    /// profile must not populate the new workspace.
    @Test func staleProjectSessionsAfterProfileSwitchAreDropped() async throws {
        let (defaults, suiteName) = makeTestDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let firstPreviews = (1...3).map { session("a-\($0)") }
        let staleFull = firstPreviews + [session("stale-older")]
        let secondPreviews = (1...3).map { session("b-\($0)") }

        let gate = CallGate()
        let browse = ScriptedBrowseService()
        browse.projectSessionsGate = gate
        browse.enqueueTree(tree(previews: firstPreviews, sessionCount: 4))
        browse.enqueueRecents(firstPreviews)
        browse.enqueueProjectSessions(staleFull)
        browse.enqueueTree(tree(previews: secondPreviews, sessionCount: 3, id: "p_other"))
        browse.enqueueRecents(secondPreviews)

        let gateway = GatewayRecorder()
        defer { gateway.finishAll() }
        let model = await connectedModel(browse: browse, gateway: gateway, defaults: defaults)
        model.selectedProfile = "alpha"
        await model.refreshProjects()

        let load = Task { await model.loadMoreProjectSessions(Self.workspaceID) }
        await gate.waitUntilEntered()

        await model.selectProfile("beta")
        await gate.release()
        await load.value

        #expect(model.expandedProjectSessions[Self.workspaceID] == nil)
        let shown = try #require(model.projectTree?.projects.first)
        #expect(model.sessions(for: shown).map(\.storedID) == secondPreviews.map(\.storedID))
        #expect(model.selectedProfile == "beta")
        #expect(browse.treeCalls.map(\.profile) == ["alpha", "beta"])
    }

    /// A recents page that finishes after a workspace/profile switch must not
    /// append onto the new list.
    @Test func staleRecentsPageAfterProfileSwitchIsDropped() async {
        let (defaults, suiteName) = makeTestDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let page1 = (1...AppModel.recentsPageSize).map { session("keep-\($0)") }
        let stalePage = [session("stale-tail")]
        let otherPage = [session("other-1"), session("other-2")]

        let gate = CallGate()
        let browse = ScriptedBrowseService()
        browse.enqueueTree(tree(previews: Array(page1.prefix(3)), sessionCount: 31))
        browse.enqueueRecents(page1)
        browse.enqueueRecents(stalePage)
        browse.enqueueTree(tree(previews: otherPage, sessionCount: 2, id: "p_other"))
        browse.enqueueRecents(otherPage)

        let gateway = GatewayRecorder()
        defer { gateway.finishAll() }
        let model = await connectedModel(browse: browse, gateway: gateway, defaults: defaults)
        model.selectedProfile = "alpha"
        await model.refreshProjects()
        #expect(model.recentsHasMore)

        browse.profileSessionsGate = gate
        let load = Task { await model.loadMoreRecentSessions() }
        await gate.waitUntilEntered()
        browse.profileSessionsGate = nil

        await model.selectProfile("beta")
        await gate.release()
        await load.value

        #expect(model.recentSessions.map(\.storedID) == otherPage.map(\.storedID))
        #expect(!model.recentSessions.map(\.storedID).contains("stale-tail"))
    }
}

// MARK: Fixtures

private func session(
    _ id: String, cwd: String = "/Users/dev/mercury-voice", profile: String? = nil
) -> SessionSummary {
    var json: [String: JSONValue] = [
        "id": .string(id),
        "title": .string(id),
        "cwd": .string(cwd),
        "git_repo_root": .string(cwd),
    ]
    if let profile { json["profile"] = .string(profile) }
    return SessionSummary(json: .object(json))!
}

private func tree(
    previews: [SessionSummary],
    sessionCount: Int,
    id: String = "p_mercury"
) -> ProjectTree {
    var project = ProjectInfo(
        json: [
            "id": .string(id),
            "label": .string("mercury-voice"),
            "path": .string("/Users/dev/mercury-voice"),
            "sessionCount": .number(Double(sessionCount)),
        ])!
    project.previewSessions = previews
    var tree = ProjectTree(json: .object([:]))
    tree.projects = [project]
    return tree
}
