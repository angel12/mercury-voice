import Foundation
import Testing

@testable import HermesKit

/// Fixtures shaped exactly like the contract v5 gateway responses
/// (tui_gateway/methods_config.py + project_tree.py `_project_node`):
/// snake_case at the top level, camelCase per project node, session rows
/// nested repo → lane → sessions.
@Suite("Project payload decoding (contract v5)")
struct ProjectDecodingTests {
    private func json(_ string: String) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: Data(string.utf8))
    }

    // MARK: projects.tree

    private static let treeFixture = """
        {
          "projects": [
            {
              "id": "__no_project__",
              "label": "Home",
              "path": null,
              "color": null,
              "icon": null,
              "isAuto": false,
              "isNoProject": true,
              "sessionCount": 2,
              "lastActive": 1755100000.0,
              "repos": [],
              "previewSessions": [
                {"id": "20250810_101500_aa11", "title": "Homeless one",
                 "cwd": "/tmp/x", "last_active": 1755100000.0},
                {"id": "20250809_090000_bb22", "title": "Homeless two",
                 "cwd": "/tmp/y", "last_active": 1755000000.0}
              ]
            },
            {
              "id": "p_4fe81a",
              "label": "mercury-voice",
              "path": "/Users/dev/mercury-voice",
              "color": "blue",
              "icon": null,
              "isAuto": true,
              "isNoProject": false,
              "sessionCount": 7,
              "lastActive": 1755090000.0,
              "repos": [
                {"id": "/Users/dev/mercury-voice", "label": "mercury-voice",
                 "path": "/Users/dev/mercury-voice", "groups": [], "sessionCount": 7}
              ],
              "previewSessions": [
                {"id": "20250811_120000_cc33", "title": "Fix issue 38",
                 "cwd": "/Users/dev/mercury-voice", "git_branch": "main",
                 "git_repo_root": "/Users/dev/mercury-voice", "last_active": 1755090000.0}
              ]
            }
          ],
          "active_id": "p_4fe81a",
          "scoped_session_ids": ["20250811_120000_cc33", "20250810_101500_aa11"]
        }
        """

    @Test func decodesContractTree() throws {
        let tree = ProjectTree(json: try json(Self.treeFixture))

        #expect(tree.activeID == "p_4fe81a")
        #expect(tree.scopedSessionIDs == ["20250811_120000_cc33", "20250810_101500_aa11"])
        #expect(tree.projects.count == 2)

        let home = try #require(tree.projects.first)
        #expect(home.isHomeBucket)
        #expect(home.name == "Home")
        #expect(home.sessionCount == 2)
        #expect(home.previewSessions.map(\.storedID) == [
            "20250810_101500_aa11", "20250809_090000_bb22",
        ])

        let project = try #require(tree.projects.last)
        #expect(project.name == "mercury-voice")  // label, not the p_… id
        #expect(project.primaryPath == "/Users/dev/mercury-voice")
        #expect(project.sessionCount == 7)
        #expect(project.previewSessions.map(\.title) == ["Fix issue 38"])
    }

    /// Older/other surfaces used snake_case; the aliases must keep working.
    @Test func decodesLegacySnakeCaseProject() throws {
        let info = try #require(ProjectInfo(json: try json("""
            {"id": "p_1", "name": "Legacy", "primary_path": "/srv/app",
             "session_count": 3,
             "preview_sessions": [{"id": "20250801_000000_dd44"}]}
            """)))
        #expect(info.name == "Legacy")
        #expect(info.primaryPath == "/srv/app")
        #expect(info.sessionCount == 3)
        #expect(info.previewSessions.map(\.storedID) == ["20250801_000000_dd44"])
    }

    // MARK: projects.project_sessions

    private static let projectSessionsFixture = """
        {
          "project": {
            "id": "p_4fe81a",
            "label": "mercury-voice",
            "path": "/Users/dev/mercury-voice",
            "isAuto": true,
            "isNoProject": false,
            "sessionCount": 3,
            "lastActive": 1755090000.0,
            "previewSessions": [],
            "repos": [
              {
                "id": "/Users/dev/mercury-voice",
                "label": "mercury-voice",
                "path": "/Users/dev/mercury-voice",
                "sessionCount": 3,
                "groups": [
                  {
                    "id": "/Users/dev/mercury-voice",
                    "label": "main",
                    "path": "/Users/dev/mercury-voice",
                    "isMain": true,
                    "isKanban": false,
                    "sessions": [
                      {"id": "20250811_120000_cc33", "title": "Newest",
                       "git_branch": "main", "last_active": 1755090000.0},
                      {"id": "20250810_110000_ee55", "title": "Older",
                       "git_branch": "main", "last_active": 1755000000.0}
                    ]
                  },
                  {
                    "id": "/Users/dev/mercury-voice-wt",
                    "label": "feature-lane",
                    "path": "/Users/dev/mercury-voice-wt",
                    "isMain": false,
                    "isKanban": false,
                    "sessions": [
                      {"id": "20250809_080000_ff66", "title": "Worktree row",
                       "git_branch": "feature", "last_active": 1754900000.0}
                    ]
                  }
                ]
              }
            ]
          }
        }
        """

    @Test func flattensHydratedProjectSessions() throws {
        let payload = try json(Self.projectSessionsFixture)
        let project = try #require(payload["project"])
        let rows = ProjectInfo.hydratedSessions(in: project)

        #expect(rows.map(\.storedID) == [
            "20250811_120000_cc33", "20250810_110000_ee55", "20250809_080000_ff66",
        ])
        #expect(rows.first?.gitBranch == "main")
        #expect(rows.last?.title == "Worktree row")
    }

    @Test func hydratedSessionsOfNullProjectIsEmpty() throws {
        // Unknown project_id → server returns {"project": null}.
        let payload = try json(#"{"project": null}"#)
        #expect(ProjectInfo.hydratedSessions(in: payload["project"] ?? .null).isEmpty)
    }
}
