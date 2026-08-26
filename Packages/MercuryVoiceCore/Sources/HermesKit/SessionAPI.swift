import Foundation
import os

/// Outcome of `session.close`. The server replies `{"closed": true}` when the
/// runtime session actually shut down; anything else means it may still be
/// holding resources (sockets, profile DB handles) on the backend.
public enum SessionCloseOutcome: Sendable, Equatable {
    /// Server confirmed `closed: true`.
    case closed
    /// RPC succeeded but the server did not confirm (`closed` missing/false).
    case unconfirmed
    /// The request itself failed (transport error, timeout, not connected).
    case failed(String)
}

/// Typed wrappers over the gateway RPC methods the app uses.
extension HermesConnection {
    /// Column count reported to the backend; matches the desktop client.
    private static let cols = 96
    private static let source = "desktop"
    private static let logger = Logger(subsystem: "MercuryVoice", category: "HermesKit")

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
            // This app never renders the transcript. defer_history makes a
            // cold resume return immediately (`hydrating: true`) and load the
            // history in a background worker (session.resume_progress events);
            // omit_messages stays for older backends that ignore the newer
            // flag but still trim the response.
            "omit_messages": .bool(true),
            "defer_history": .bool(true),
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

    /// Detach politely when leaving a session, verifying the server's answer:
    /// an unconfirmed or failed close means the backend may still hold the
    /// session's sockets and profile DB handles. Every outcome is logged so
    /// leak investigations don't have to guess whether End reached the server.
    @discardableResult
    public func closeSession(sessionID: String) async -> SessionCloseOutcome {
        do {
            let result = try await request(
                "session.close", params: ["session_id": .string(sessionID)])
            if result["closed"]?.truthy == true {
                Self.logger.info(
                    "session.close confirmed for \(sessionID, privacy: .public)")
                return .closed
            }
            Self.logger.error(
                "session.close NOT confirmed for \(sessionID, privacy: .public): \("\(result)", privacy: .public)"
            )
            return .unconfirmed
        } catch {
            let reason = (error as? HermesError)?.errorDescription ?? "\(error)"
            Self.logger.error(
                "session.close failed for \(sessionID, privacy: .public): \(reason, privacy: .public)"
            )
            return .failed(reason)
        }
    }

    // MARK: Projects

    /// `projects.tree` — the authoritative sidebar grouping (explicit
    /// projects, auto repo projects, `__no_project__` Home bucket). Pass the
    /// selected profile for server-side scoping (`_profile_scoped` binds that
    /// profile's HERMES_HOME); omitted, or on older backends that ignore the
    /// param, the launch profile answers as before.
    public func projectsTree(
        previewLimit: Int = 3, profile: String? = nil
    ) async throws -> ProjectTree {
        var params: [String: JSONValue] = ["preview_limit": .number(Double(previewLimit))]
        if let profile, !profile.isEmpty { params["profile"] = .string(profile) }
        let result = try await request("projects.tree", params: .object(params))
        return ProjectTree(json: result)
    }

    /// `projects.project_sessions` — the fully hydrated rows for one
    /// project, nested under `project` as repo → lane → sessions.
    public func projectSessions(
        projectID: String, profile: String? = nil
    ) async throws -> [SessionSummary] {
        var params: [String: JSONValue] = ["project_id": .string(projectID)]
        if let profile, !profile.isEmpty { params["profile"] = .string(profile) }
        let result = try await request("projects.project_sessions", params: .object(params))
        guard let project = result["project"] else { return [] }
        return ProjectInfo.hydratedSessions(in: project)
    }

    // MARK: Reconnect replay

    /// `session.events.since` — replay events newer than `lastSeen` for a
    /// still-live session after a reconnect. Throws rpcError on backends
    /// without the replay contract; callers treat that as `truncated`.
    public func eventsSince(sessionID: String, lastSeen: Int) async throws -> EventReplayBatch {
        let result = try await request(
            "session.events.since",
            params: [
                "session_id": .string(sessionID),
                "last_seen": .number(Double(lastSeen)),
            ])
        return EventReplayBatch(result: result)
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
