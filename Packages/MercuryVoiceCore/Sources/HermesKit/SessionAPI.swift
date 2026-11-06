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
    ///
    /// A cwd is always a project the user picked, so it goes out with
    /// `cwd_explicit: true`; without it a named profile's `terminal.cwd`
    /// wins (upstream a9972dc3f9). Backends that predate the key (66bc259712)
    /// reject it with 4000 and get one retry without it.
    public func createSession(
        cwd: String? = nil, profile: String? = nil, title: String? = nil
    ) async throws -> SessionHandle {
        var params: [String: JSONValue] = [
            "cols": .number(Double(Self.cols)),
            "source": .string(Self.source),
        ]
        if let cwd, !cwd.isEmpty {
            params["cwd"] = .string(cwd)
            params["cwd_explicit"] = .bool(true)
        }
        if let profile, !profile.isEmpty { params["profile"] = .string(profile) }
        if let title, !title.isEmpty { params["title"] = .string(title) }

        if speaksSessionAuthority {
            let result = try await request(
                "session.create", params: .object(AuthorityWire.createParams(params)))
            return try adoptAuthoritySnapshot(result, method: "session.create")
        }

        let result: JSONValue
        do {
            result = try await request("session.create", params: .object(params))
        } catch HermesError.rpcError(4000, let message, _)
            where params["cwd_explicit"] != nil && message.contains("cwd_explicit")
        {
            params["cwd_explicit"] = nil
            result = try await request("session.create", params: .object(params))
        }
        guard let handle = SessionHandle(result: result) else {
            throw HermesError.malformedResponse("session.create returned no session_id")
        }
        return handle
    }

    /// A canonical create/resume snapshot: remember this socket's
    /// subscription and the session's generation, then hand the rest of the
    /// app the legacy payload shape it decodes.
    private func adoptAuthoritySnapshot(
        _ result: JSONValue, method: String
    ) throws -> SessionHandle {
        let normalized = AuthorityWire.legacySnapshot(result)
        guard let handle = SessionHandle(result: normalized) else {
            throw HermesError.malformedResponse("\(method) returned no session_id")
        }
        if let subscription = result["subscription_id"]?.stringValue, !subscription.isEmpty {
            authoritySubscriptions[handle.runtimeID] = subscription
        }
        if let generation = result["execution_generation"]?.intValue {
            noteExecutionGeneration(generation, for: handle.runtimeID)
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

        let raw = try await request("session.resume", params: .object(params), timeout: 120)
        let result: JSONValue
        if speaksSessionAuthority {
            // The canonical resume tolerates every flag above as sent.
            result = AuthorityWire.legacySnapshot(raw)
            _ = try adoptAuthoritySnapshot(raw, method: "session.resume")
        } else {
            result = raw
        }
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

    /// `session.activate` — re-read the live session's payload, including
    /// its pending-prompt registry state, without closing or re-resuming
    /// anything.
    ///
    /// Used on reconnect to take prompt state *after* the replay batch has
    /// been fetched, so the sheets are decided by the newest read rather than
    /// by a snapshot the batch is newer than (issue #75). `omit_messages`
    /// skips the transcript DB read, and the handler resolves a **live
    /// runtime id only** — a session the gateway no longer holds answers
    /// 4001 rather than falling back to the stored id, which is what makes a
    /// success meaningful as an identity check.
    ///
    /// Its side effects (transport rebind to the socket this call is already
    /// on, a viewers timestamp, `last_active` touch, cancelling a pending
    /// ws-orphan reap) are re-applications of what the preceding
    /// `session.resume` just did.
    ///
    /// Throws on a backend without the method, and on any malformed payload.
    ///
    /// A session authority serves no `session.activate`; there the same
    /// re-read is a `session.resume` on this socket (`AuthorityWire`), whose
    /// snapshot is mapped onto the live-session payload shape.
    public func activateSession(sessionID: String) async throws -> LiveSessionSnapshot {
        if speaksSessionAuthority {
            let raw = try await request(
                "session.resume", params: AuthorityWire.activateParams(sessionID: sessionID),
                timeout: 120)
            let handle = try adoptAuthoritySnapshot(raw, method: "session.resume")
            guard handle.runtimeID == sessionID,
                let snapshot = LiveSessionSnapshot(result: AuthorityWire.legacySnapshot(raw))
            else {
                throw HermesError.malformedResponse(
                    "session.resume did not return a live-session payload")
            }
            return snapshot
        }
        let result = try await request(
            "session.activate",
            params: [
                "session_id": .string(sessionID),
                "omit_messages": .bool(true),
            ])
        guard let snapshot = LiveSessionSnapshot(result: result) else {
            throw HermesError.malformedResponse(
                "session.activate did not return a live-session payload")
        }
        return snapshot
    }

    /// `prompt.submit` returns `{"status":"streaming"}` immediately — the
    /// reply arrives only via events; never await this for completion. Set
    /// `interrupted` on the first submit after a barge-in so the backend
    /// prepends a "your spoken reply was cut off" note for the model.
    ///
    /// Every app turn is spoken, so it goes out with `voice_turn: true`: the
    /// backend runs it on the `auxiliary.voice_chat` model with reasoning off
    /// by default (upstream 6cc1efd8f9). Backends that predate the key reject
    /// it with 4000 before the handler runs; the turn is retried once without
    /// it and the key stays off for the rest of this gateway connection.
    public func submitPrompt(
        sessionID: String, text: String, interrupted: Bool = false
    ) async throws {
        var params: [String: JSONValue] = [
            "session_id": .string(sessionID),
            "text": .string(text),
        ]
        if interrupted { params["interrupted"] = .bool(true) }
        if speaksSessionAuthority {
            // The authority knows voice_turn, so there is no retry to make;
            // the submission id is what makes the admission idempotent.
            params["voice_turn"] = .bool(true)
            let receipt = try await request(
                "prompt.submit",
                params: .object(
                    AuthorityWire.submitParams(params, submissionID: UUID().uuidString)),
                timeout: 1800)
            if let generation = receipt["execution_generation"]?.intValue {
                noteExecutionGeneration(generation, for: sessionID)
            }
            return
        }
        if sendsVoiceTurn { params["voice_turn"] = .bool(true) }
        // Desktop uses a 30-minute timeout here.
        do {
            _ = try await request("prompt.submit", params: .object(params), timeout: 1800)
        } catch HermesError.rpcError(4000, let message, _)
            where params["voice_turn"] != nil && message.contains("voice_turn")
        {
            sendsVoiceTurn = false
            params["voice_turn"] = nil
            _ = try await request("prompt.submit", params: .object(params), timeout: 1800)
        }
    }

    /// Cancel the in-flight turn (used on barge-in while still generating).
    ///
    /// A session authority fences it by `execution_generation`: the newest
    /// one this connection has seen for the session goes with it.
    public func interruptSession(sessionID: String) async throws {
        if speaksSessionAuthority {
            guard let generation = executionGenerations[sessionID] else {
                throw HermesError.malformedResponse(
                    "no execution_generation known for \(sessionID); cannot interrupt")
            }
            let handle = try await request(
                "session.interrupt",
                params: AuthorityWire.interruptParams(sessionID: sessionID, generation: generation))
            if let next = handle["execution_generation"]?.intValue {
                noteExecutionGeneration(next, for: sessionID)
            }
            return
        }
        _ = try await request("session.interrupt", params: ["session_id": .string(sessionID)])
    }

    /// Detach politely when leaving a session, verifying the server's answer:
    /// an unconfirmed or failed close means the backend may still hold the
    /// session's sockets and profile DB handles. Every outcome is logged so
    /// leak investigations don't have to guess whether End reached the server.
    ///
    /// A session authority serves no `session.close`: leaving is
    /// `session.detach` of this socket's subscription, confirmed by
    /// `detached: true`. The session itself stays the owner's to keep.
    @discardableResult
    public func closeSession(sessionID: String) async -> SessionCloseOutcome {
        if speaksSessionAuthority {
            return await detachSession(sessionID: sessionID)
        }
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

    private func detachSession(sessionID: String) async -> SessionCloseOutcome {
        guard let subscription = authoritySubscriptions[sessionID] else {
            Self.logger.error(
                "session.detach skipped for \(sessionID, privacy: .public): no subscription on this socket")
            return .failed("no subscription on this socket")
        }
        do {
            let result = try await request(
                "session.detach",
                params: AuthorityWire.detachParams(sessionID: sessionID, subscriptionID: subscription))
            authoritySubscriptions[sessionID] = nil
            if result["detached"]?.truthy == true {
                Self.logger.info("session.detach confirmed for \(sessionID, privacy: .public)")
                return .closed
            }
            Self.logger.error(
                "session.detach NOT confirmed for \(sessionID, privacy: .public): \("\(result)", privacy: .public)"
            )
            return .unconfirmed
        } catch {
            let reason = (error as? HermesError)?.errorDescription ?? "\(error)"
            Self.logger.error(
                "session.detach failed for \(sessionID, privacy: .public): \(reason, privacy: .public)"
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
    ///
    /// `sessionLimit` maps to the handler's `session_limit` (server default
    /// 5000). There is no offset: the backend scans the newest N sessions
    /// across the profile, then returns this project's share. Omit to leave
    /// the default in place.
    public func projectSessions(
        projectID: String, profile: String? = nil, sessionLimit: Int? = nil
    ) async throws -> [SessionSummary] {
        var params: [String: JSONValue] = ["project_id": .string(projectID)]
        if let profile, !profile.isEmpty { params["profile"] = .string(profile) }
        if let sessionLimit {
            params["session_limit"] = .number(Double(sessionLimit))
        }
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
    /// Contract-6 backends only — an `ApprovalRequest` with a
    /// `serverRequestID` came from a contract ≥ 7 server request and must be
    /// answered with `answerServerRequest` instead.
    ///
    /// On a session authority the response names the prompt instead:
    /// `{session_id, execution_generation, prompt_id, choice}`, with the
    /// prompt's own id and generation.
    public func respondApproval(_ approval: ApprovalRequest, choice: String) async throws {
        if speaksSessionAuthority {
            guard let promptID = approval.requestID,
                let generation = approval.executionGeneration
                    ?? executionGenerations[approval.sessionID]
            else {
                throw HermesError.malformedResponse(
                    "approval has no prompt_id/execution_generation to answer")
            }
            _ = try await request(
                "approval.respond",
                params: AuthorityWire.approvalParams(
                    sessionID: approval.sessionID, generation: generation,
                    promptID: promptID, choice: choice))
            return
        }
        _ = try await request(
            "approval.respond",
            params: ["session_id": .string(approval.sessionID), "choice": .string(choice)])
    }

    /// `clarify.respond` — empty answer = skip. A late respond after expiry
    /// returns `{"status":"expired"}`, never an error. Contract-6 backends
    /// only — a `ClarifyRequest` with a `serverRequestID` came from a
    /// contract ≥ 7 server request and must be answered with
    /// `answerServerRequest` instead.
    ///
    /// On a session authority: `{session_id, execution_generation,
    /// prompt_id, answer}`, the prompt id being `requestID`.
    public func respondClarify(_ clarify: ClarifyRequest, answer: String) async throws {
        if speaksSessionAuthority {
            guard let sessionID = clarify.sessionID,
                let generation = clarify.executionGeneration ?? executionGenerations[sessionID]
            else {
                throw HermesError.malformedResponse(
                    "clarify has no session_id/execution_generation to answer")
            }
            _ = try await request(
                "clarify.respond",
                params: AuthorityWire.clarifyParams(
                    sessionID: sessionID, generation: generation,
                    promptID: clarify.requestID, answer: answer))
            return
        }
        _ = try await request(
            "clarify.respond",
            params: ["request_id": .string(clarify.requestID), "answer": .string(answer)])
    }

    /// `request.answer {id, result}` — answers an open server→client request
    /// (contract ≥ 7). Used instead of a bare response frame because it is
    /// acknowledged (`status: ok|expired`) and works from a socket that did
    /// not receive the request (a reconnect restoring `open_requests`).
    public func answerServerRequest(id: String, result: JSONValue) async throws
        -> ServerRequestAnswer
    {
        let reply = try await request(
            ServerRequestAnswer.method,
            params: ServerRequestAnswer.answerParams(id: id, result: result))
        return ServerRequestAnswer(reply: reply)
    }

    // MARK: TTS lease

    /// `POST /api/audio/tts-lease` — plain REST, not a gateway RPC, so this
    /// just forwards to `rest`.
    public func ttsLease(_ lease: String, active: Bool, profile: String?) async {
        await rest.ttsLease(lease, active: active, profile: profile)
    }

    /// `POST /api/audio/stt-lease` — see `HermesRESTClient.sttLease`.
    public func sttLease(_ lease: String, active: Bool, profile: String?) async {
        await rest.sttLease(lease, active: active, profile: profile)
    }
}
