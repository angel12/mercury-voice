import Foundation

// MARK: - Server status

public struct ServerStatus: Sendable, Equatable {
    public var version: String?
    public var authRequired: Bool
    public var activeSessions: Int?
    /// Gated-mode capability advertisement: "cookie" always, "native_pkce"
    /// when a brokerable OAuth provider is registered (RFC 8252 flow).
    /// Empty on older gateways — treat as cookie-only.
    public var authFlows: [String]
    public var raw: JSONValue

    public init(raw: JSONValue) {
        self.raw = raw
        self.version = raw["version"]?.stringValue
        self.authRequired = raw["auth_required"]?.truthy ?? false
        self.activeSessions = raw["active_sessions"]?.intValue
        self.authFlows = raw["auth_flows"]?.arrayValue?.compactMap(\.stringValue) ?? []
    }
}

// MARK: - Profiles

public struct ProfileInfo: Sendable, Equatable, Identifiable {
    public var name: String
    public var path: String?
    public var isDefault: Bool
    public var model: String?
    public var provider: String?
    public var skillCount: Int?
    public var hasEnv: Bool

    public var id: String { name }

    public init?(json: JSONValue) {
        guard let name = json["name"]?.stringValue, !name.isEmpty else { return nil }
        self.name = name
        self.path = json["path"]?.stringValue
        self.isDefault = json["is_default"]?.truthy ?? false
        self.model = json["model"]?.stringValue
        self.provider = json["provider"]?.stringValue
        self.skillCount = json["skill_count"]?.intValue
        self.hasEnv = json["has_env"]?.truthy ?? false
    }
}

// MARK: - Sessions

/// A row from the session lists (`/api/sessions`, `/api/profiles/sessions`,
/// `session.list`, `projects.tree` previews). The id here is always the
/// durable **stored** id (`YYYYMMDD_HHMMSS_<hex>`), never a runtime id.
public struct SessionSummary: Sendable, Equatable, Identifiable {
    public var storedID: String
    public var title: String?
    public var cwd: String?
    public var gitRepoRoot: String?
    public var gitBranch: String?
    public var profile: String?
    public var pinned: Bool
    public var updatedAt: Date?
    public var messageCount: Int?

    public var id: String { storedID }

    public init?(json: JSONValue) {
        // Different surfaces name the id differently.
        guard
            let storedID = json["session_id"]?.stringValue
                ?? json["id"]?.stringValue
                ?? json["stored_session_id"]?.stringValue,
            !storedID.isEmpty
        else { return nil }
        self.storedID = storedID
        self.title = json["title"]?.stringValue
        self.cwd = json["cwd"]?.stringValue
        self.gitRepoRoot = json["git_repo_root"]?.stringValue
        self.gitBranch = json["git_branch"]?.stringValue
        self.profile = json["profile"]?.stringValue
        self.pinned = json["pinned"]?.truthy ?? false
        self.messageCount = json["message_count"]?.intValue
        // Timestamps arrive as epoch seconds or ISO strings depending on
        // surface; accept both.
        if let epoch = (json["updated_at"] ?? json["last_active"] ?? json["created_at"])?
            .doubleValue
        {
            self.updatedAt = Date(timeIntervalSince1970: epoch)
        } else if let iso = (json["updated_at"] ?? json["last_active"] ?? json["created_at"])?
            .stringValue
        {
            self.updatedAt = ISO8601DateFormatter().date(from: iso)
        }
    }
}

// MARK: - Projects

public struct ProjectInfo: Sendable, Equatable, Identifiable {
    /// The Home / no-workspace bucket id used by `projects.tree`.
    public static let noProjectID = "__no_project__"

    public var id: String
    public var name: String
    public var primaryPath: String?
    public var kind: String?
    public var previewSessions: [SessionSummary]
    public var sessionCount: Int?

    public var isHomeBucket: Bool { id == Self.noProjectID }

    public init?(json: JSONValue) {
        guard let id = json["id"]?.stringValue ?? json["project_id"]?.stringValue else {
            return nil
        }
        self.id = id
        // Contract v5 project nodes are camelCase with `label` for the
        // display name (tui_gateway/project_tree.py `_project_node`); the
        // snake_case spellings are kept as fallbacks for older servers.
        self.name =
            json["label"]?.stringValue
            ?? json["name"]?.stringValue
            ?? json["title"]?.stringValue
            ?? id
        self.primaryPath =
            json["path"]?.stringValue
            ?? json["primary_path"]?.stringValue
            ?? json["root"]?.stringValue
        self.kind = json["kind"]?.stringValue ?? json["type"]?.stringValue
        self.previewSessions =
            (json["previewSessions"] ?? json["preview_sessions"] ?? json["sessions"])?
            .arrayValue?
            .compactMap(SessionSummary.init(json:)) ?? []
        self.sessionCount = json["sessionCount"]?.intValue ?? json["session_count"]?.intValue
    }

    /// Session rows of a hydrated `projects.project_sessions` node. Contract
    /// v5 nests them repo → lane → sessions (`repos[].groups[].sessions`);
    /// lanes are already newest-first, so flatten in server order.
    public static func hydratedSessions(in project: JSONValue) -> [SessionSummary] {
        var rows: [SessionSummary] = []
        for repo in project["repos"]?.arrayValue ?? [] {
            for lane in repo["groups"]?.arrayValue ?? [] {
                rows.append(
                    contentsOf: lane["sessions"]?.arrayValue?
                        .compactMap(SessionSummary.init(json:)) ?? [])
            }
        }
        return rows
    }
}

public struct ProjectTree: Sendable, Equatable {
    public var projects: [ProjectInfo]
    public var activeID: String?
    /// Stored session ids already shown inside a project group — exclude
    /// these from the flat Recents list.
    public var scopedSessionIDs: Set<String>

    public init(json: JSONValue) {
        self.projects = json["projects"]?.arrayValue?.compactMap(ProjectInfo.init(json:)) ?? []
        self.activeID = json["active_id"]?.stringValue
        self.scopedSessionIDs = Set(
            json["scoped_session_ids"]?.arrayValue?.compactMap(\.stringValue) ?? [])
    }
}

// MARK: - Live session handle

/// Result of `session.create` / `session.resume`.
///
/// Two-ID model: `runtimeID` is what every subsequent RPC takes but is
/// recycled on backend restart; `storedID` is the durable DB id used to
/// re-resume after any reconnect.
public struct SessionHandle: Sendable, Equatable {
    public var runtimeID: String
    public var storedID: String?
    public var cwd: String?
    public var project: String?
    public var profileName: String?
    public var model: String?
    public var title: String?
    public var desktopContract: Int?
    public var raw: JSONValue

    public init?(result: JSONValue) {
        guard let runtimeID = result["session_id"]?.stringValue, !runtimeID.isEmpty else {
            return nil
        }
        self.runtimeID = runtimeID
        self.storedID = result["stored_session_id"]?.stringValue
        let info = result["info"] ?? .null
        self.cwd = info["cwd"]?.stringValue
        self.project = info["project"]?.stringValue
        self.profileName = info["profile_name"]?.stringValue
        self.model = info["model"]?.stringValue
        self.title = info["title"]?.stringValue ?? result["title"]?.stringValue
        self.desktopContract = info["desktop_contract"]?.intValue
            ?? result["desktop_contract"]?.intValue
        self.raw = result
    }
}

// MARK: - Usage

/// The gateway's usage dict (`_get_usage` in tui_gateway/server.py), carried
/// by `session.usage` ticks (~1/s while a turn runs) and authoritatively by
/// `message.complete.usage`. The `context*` gauge fields are present only
/// when the backend reports real current-window occupancy — absent means
/// unknown, and no gauge should be rendered.
public struct SessionUsage: Sendable, Equatable {
    public var model: String?
    public var totalTokens: Int?
    public var apiCalls: Int?
    public var contextUsed: Int?
    public var contextMax: Int?
    /// 0–100, already clamped server-side.
    public var contextPercent: Int?
    public var activeSubagents: Int?

    public init?(json: JSONValue) {
        guard case .object = json else { return nil }
        self.model = json["model"]?.stringValue
        self.totalTokens = json["total"]?.intValue
        self.apiCalls = json["calls"]?.intValue
        self.contextUsed = json["context_used"]?.intValue
        self.contextMax = json["context_max"]?.intValue
        self.contextPercent = json["context_percent"]?.intValue
        self.activeSubagents = json["active_subagents"]?.intValue
    }
}

// MARK: - Audio

public struct TranscriptionResult: Sendable, Equatable {
    public var transcript: String
    public var provider: String?

    /// Empty transcript = silence; a normal outcome, not an error.
    public var isSilence: Bool {
        transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

public struct SpokenClip: Sendable, Equatable {
    public var dataURL: String
    public var mimeType: String?
}
