import Foundation

/// Typed wrappers over the gateway RPC methods the app uses.
extension HermesConnection {
    /// Column count reported to the backend; matches the desktop client.
    private static let cols = 96
    private static let source = "desktop"

    // MARK: Sessions

    /// `session.create` — `cwd` binds the session to a project directory;
    /// omit for "no workspace". The DB row appears lazily on first prompt.
    public func createSession(
        cwd: String? = nil, profile: String? = nil, title: String? = nil
    ) async throws -> SessionHandle {
        var params: [String: JSONValue] = [
            "cols": .number(Double(Self.cols)),
            "source": .string(Self.source),
        ]
        if let cwd, !cwd.isEmpty { params["cwd"] = .string(cwd) }
        if let profile, !profile.isEmpty { params["profile"] = .string(profile) }
        if let title, !title.isEmpty { params["title"] = .string(title) }

        let result = try await request("session.create", params: .object(params))
        guard let handle = SessionHandle(result: result) else {
            throw HermesError.malformedResponse("session.create returned no session_id")
        }
        return handle
    }

    /// `session.resume` by **stored** id. Pass the session's owning profile —
    /// cross-profile resume opens that profile's state DB. The result's
    /// `resumed` field may differ from the requested id (compression
    /// continuation chains are followed to the live tip); the returned
    /// handle's `storedID` is re-anchored to it.
    public func resumeSession(
        storedID: String, profile: String? = nil
    ) async throws -> SessionHandle {
        var params: [String: JSONValue] = [
            "session_id": .string(storedID),
            "cols": .number(Double(Self.cols)),
            "source": .string(Self.source),
            "omit_messages": .bool(true),
        ]
        if let profile, !profile.isEmpty { params["profile"] = .string(profile) }

        let result = try await request("session.resume", params: .object(params), timeout: 120)
        guard var handle = SessionHandle(result: result) else {
            throw HermesError.malformedResponse("session.resume returned no session_id")
        }
        // resume names the durable id `session_key`/`resumed`, not
        // `stored_session_id`.
        handle.storedID =
            result["resumed"]?.stringValue
            ?? result["session_key"]?.stringValue
            ?? handle.storedID
            ?? storedID
        return handle
    }

    /// `prompt.submit` returns `{"status":"streaming"}` immediately — the
    /// reply arrives only via events; never await this for completion. Set
    /// `interrupted` on the first submit after a barge-in so the backend
    /// prepends a "your spoken reply was cut off" note for the model.
    public func submitPrompt(
        sessionID: String, text: String, interrupted: Bool = false
    ) async throws {
        var params: [String: JSONValue] = [
            "session_id": .string(sessionID),
            "text": .string(text),
        ]
        if interrupted { params["interrupted"] = .bool(true) }
        // Desktop uses a 30-minute timeout here.
        _ = try await request("prompt.submit", params: .object(params), timeout: 1800)
    }

    /// Cancel the in-flight turn (used on barge-in while still generating).
    public func interruptSession(sessionID: String) async throws {
        _ = try await request("session.interrupt", params: ["session_id": .string(sessionID)])
    }

    /// Detach politely when leaving a session.
    public func closeSession(sessionID: String) async {
        _ = try? await request("session.close", params: ["session_id": .string(sessionID)])
    }

    // MARK: Projects

    /// `projects.tree` — the authoritative sidebar grouping (explicit
    /// projects, auto repo projects, `__no_project__` Home bucket).
    public func projectsTree(previewLimit: Int = 3) async throws -> ProjectTree {
        let result = try await request(
            "projects.tree", params: ["preview_limit": .number(Double(previewLimit))])
        return ProjectTree(json: result)
    }

    public func projectSessions(projectID: String) async throws -> [SessionSummary] {
        let result = try await request(
            "projects.project_sessions", params: ["project_id": .string(projectID)])
        return result["sessions"]?.arrayValue?.compactMap(SessionSummary.init(json:)) ?? []
    }

    // MARK: Prompt-family responses

    /// `approval.respond` — session-keyed (no request id); absent choice
    /// means deny server-side, so always pass one of the event's choices.
    public func respondApproval(sessionID: String, choice: String) async throws {
        _ = try await request(
            "approval.respond",
            params: ["session_id": .string(sessionID), "choice": .string(choice)])
    }

    /// `clarify.respond` — empty answer = skip. A late respond after expiry
    /// returns `{"status":"expired"}`, never an error.
    public func respondClarify(requestID: String, answer: String) async throws {
        _ = try await request(
            "clarify.respond",
            params: ["request_id": .string(requestID), "answer": .string(answer)])
    }
}
