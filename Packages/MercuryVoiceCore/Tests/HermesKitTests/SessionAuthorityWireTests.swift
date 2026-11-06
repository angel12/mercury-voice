import Foundation
import Testing

@testable import HermesKit

/// A v0.23 gateway listener (Webapp / loopback `api_origin`) attaches a
/// session authority and says so in `gateway.ready`. Only then do the session
/// calls go out in the canonical `hermes-gateway-v1` shapes; a socket without
/// the flag (standalone `hermes serve`) keeps the legacy wire byte for byte.
@Suite("session authority wire")
struct SessionAuthorityWireTests {
    private static let snapshot = #"""
        {"session_id":"local-abc","stored_session_id":"local-abc","messages":[],"message_count":0,
         "running":false,"authority_epoch":7,"replay_epoch":"ep","last_sequence":0,
         "subscription_id":"sub-1","revision":1,"execution_generation":2,"pending":[],
         "prompts":[{"kind":"approval","prompt_id":"p-9","execution_generation":2,
                     "command":"rm -rf x","description":"dangerous","choices":["once","deny"]}],
         "info":{"desktop_protocol":"hermes-gateway-v1","cwd":"/tmp/w"}}
        """#

    private func connect(
        authority: Bool,
        answer: @escaping @Sendable (String) -> String = { _ in "{}" }
    ) async throws -> (LoopbackGatewayServer, HermesConnection) {
        let server = try await LoopbackGatewayServer.start(
            onOpen: { server in
                server.sendEvent(
                    type: "gateway.ready",
                    payload: authority ? #"{"session_authority":true}"# : "{}")
            },
            onRequest: { frame in
                let method = frame["method"]?.stringValue ?? ""
                return #"{"jsonrpc":"2.0","id":\#(frame["id"]?.intValue ?? 0),"result":\#(answer(method))}"#
            })
        let endpoint = ServerEndpoint(baseURL: URL(string: "http://127.0.0.1:\(server.port)")!)
        let connection = HermesConnection(endpoint: endpoint, token: nil)
        await connection.start()
        #expect(await eventually { await connection.phase == .ready(isReconnect: false) })
        return (server, connection)
    }

    private func params(_ server: LoopbackGatewayServer, _ method: String) -> [JSONValue] {
        server.receivedFrames
            .filter { $0["method"]?.stringValue == method }
            .compactMap { $0["params"] }
    }

    private func keys(_ value: JSONValue?) -> Set<String> {
        Set(value?.objectValue?.keys.map { $0 } ?? [])
    }

    private static func authorityAnswers(_ method: String) -> String {
        switch method {
        case "session.create", "session.resume": return snapshot
        case "session.detach":
            return #"{"session_id":"local-abc","subscription_id":"sub-1","detached":true}"#
        case "prompt.submit":
            return #"{"admission_id":"a1","sequence":1,"status":"started","outcome":null,"authority_epoch":7,"execution_generation":3,"ref":{"profile_id":"default","session_id":"local-abc"}}"#
        case "approval.respond", "clarify.respond": return #"{"status":"resolved"}"#
        default: return "{}"
        }
    }

    // MARK: Legacy wire unchanged

    @Test func legacySocketKeepsTheLegacyShapes() async throws {
        let (server, connection) = try await connect(authority: false) { method in
            switch method {
            case "session.create": return #"{"session_id":"rt-1","stored_session_id":"s-1"}"#
            case "session.close": return #"{"closed":true}"#
            default: return #"{"status":"streaming"}"#
            }
        }
        defer { server.stop() }
        #expect(await connection.speaksSessionAuthority == false)

        _ = try await connection.createSession(cwd: "/tmp/w")
        try await connection.submitPrompt(sessionID: "rt-1", text: "hi")
        try await connection.interruptSession(sessionID: "rt-1")
        let approval = try #require(
            ApprovalRequest(payload: ["request_id": "r1", "choices": ["once"]], sessionID: "rt-1"))
        try await connection.respondApproval(approval, choice: "once")
        let clarify = try #require(
            ClarifyRequest(payload: ["request_id": "c1", "question": "q"], sessionID: "rt-1"))
        try await connection.respondClarify(clarify, answer: "a")
        #expect(await connection.closeSession(sessionID: "rt-1") == .closed)

        let create = try #require(params(server, "session.create").first)
        #expect(create["cols"]?.intValue == 96)
        #expect(create["source"]?.stringValue == "desktop")
        #expect(params(server, "prompt.submit").first?["submission_id"] == nil)
        #expect(keys(params(server, "session.interrupt").first) == ["session_id"])
        #expect(keys(params(server, "approval.respond").first) == ["session_id", "choice"])
        #expect(keys(params(server, "clarify.respond").first) == ["request_id", "answer"])
        #expect(params(server, "session.close").count == 1)
        #expect(params(server, "session.detach").isEmpty)
        await connection.stop()
    }

    // MARK: Authority wire

    @Test func createDropsColsAndUsesAValidSource() async throws {
        let (server, connection) = try await connect(authority: true, answer: Self.authorityAnswers)
        defer { server.stop() }
        #expect(await connection.speaksSessionAuthority)

        let handle = try await connection.createSession(cwd: "/tmp/w", title: "T")

        let create = try #require(params(server, "session.create").first)
        #expect(create["cols"] == nil)
        #expect(create["source"]?.stringValue == "gui")
        #expect(create["cwd"]?.stringValue == "/tmp/w")
        #expect(create["cwd_explicit"]?.boolValue == true)
        #expect(create["title"]?.stringValue == "T")
        #expect(handle.runtimeID == "local-abc")
        #expect(handle.storedID == "local-abc")
        #expect(handle.cwd == "/tmp/w")
        // The pending prompt is adopted like a legacy `pending_approval`.
        let pending = try #require(handle.raw["pending_approval"])
        let approval = try #require(ApprovalRequest(payload: pending, sessionID: handle.runtimeID))
        #expect(approval.requestID == "p-9")
        #expect(approval.executionGeneration == 2)
        #expect(approval.choices == ["once", "deny"])
        #expect(await connection.authoritySubscriptions["local-abc"] == "sub-1")
        #expect(await connection.executionGenerations["local-abc"] == 2)
        await connection.stop()
    }

    @Test func submitCarriesASubmissionIDAndVoiceTurn() async throws {
        let (server, connection) = try await connect(authority: true, answer: Self.authorityAnswers)
        defer { server.stop() }

        try await connection.submitPrompt(sessionID: "local-abc", text: "one", interrupted: true)
        try await connection.submitPrompt(sessionID: "local-abc", text: "two")

        let submits = params(server, "prompt.submit")
        #expect(submits.count == 2)
        let first = try #require(submits.first)
        #expect(first["text"]?.stringValue == "one")
        #expect(first["voice_turn"]?.boolValue == true)
        #expect(first["interrupted"]?.boolValue == true)
        let ids = submits.compactMap { $0["submission_id"]?.stringValue }
        #expect(ids.count == 2)
        #expect(Set(ids).count == 2)
        #expect(ids.allSatisfy { UUID(uuidString: $0) != nil })
        // The receipt's generation is what an interrupt is fenced by next.
        #expect(await connection.executionGenerations["local-abc"] == 3)
        await connection.stop()
    }

    @Test func interruptUsesTheNewestGenerationFromEventFrames() async throws {
        let (server, connection) = try await connect(authority: true, answer: Self.authorityAnswers)
        defer { server.stop() }
        let updates = await connection.updates()

        _ = try await connection.createSession()
        server.send(
            #"{"jsonrpc":"2.0","method":"event","params":{"type":"message.start","session_id":"local-abc","seq":4,"authority_epoch":7,"execution_generation":5,"admission_id":"a1","payload":{}}}"#
        )
        var sawFrame = false
        for await update in updates {
            if case .event(let event) = update, event.type == "message.start" {
                #expect(event.executionGeneration == 5)
                #expect(event.seq == 4)
                sawFrame = true
                break
            }
        }
        #expect(sawFrame)

        try await connection.interruptSession(sessionID: "local-abc")
        let interrupt = try #require(params(server, "session.interrupt").first)
        #expect(keys(interrupt) == ["session_id", "execution_generation"])
        #expect(interrupt["execution_generation"]?.intValue == 5)
        await connection.stop()
    }

    @Test func promptResponsesUseTheExactCanonicalKeys() async throws {
        let (server, connection) = try await connect(authority: true, answer: Self.authorityAnswers)
        defer { server.stop() }

        let approvalEvent = GatewayEvent(
            type: "approval.request", sessionID: "local-abc",
            payload: [
                "kind": "approval", "prompt_id": "p-1", "execution_generation": 4,
                "command": "ls", "choices": ["once", "session", "deny"],
            ])
        let approval = try #require(ApprovalRequest(event: approvalEvent))
        try await connection.respondApproval(approval, choice: "session")

        let clarifyEvent = GatewayEvent(
            type: "clarify.request", sessionID: "local-abc",
            payload: [
                "kind": "clarify", "prompt_id": "c-1", "execution_generation": 4,
                "question": "which?", "choices": ["a", "b"], "multi_select": false,
            ])
        let clarify = try #require(ClarifyRequest(event: clarifyEvent))
        #expect(clarify.requestID == "c-1")
        try await connection.respondClarify(clarify, answer: "a")

        let approve = try #require(params(server, "approval.respond").first)
        #expect(keys(approve) == ["session_id", "execution_generation", "prompt_id", "choice"])
        #expect(approve["prompt_id"]?.stringValue == "p-1")
        #expect(approve["execution_generation"]?.intValue == 4)
        #expect(approve["choice"]?.stringValue == "session")

        let answer = try #require(params(server, "clarify.respond").first)
        #expect(keys(answer) == ["session_id", "execution_generation", "prompt_id", "answer"])
        #expect(answer["prompt_id"]?.stringValue == "c-1")
        #expect(answer["session_id"]?.stringValue == "local-abc")
        await connection.stop()
    }

    @Test func activateIsAResumeThatDescribesTheSameSession() async throws {
        let (server, connection) = try await connect(authority: true, answer: Self.authorityAnswers)
        defer { server.stop() }

        let handle = try await connection.resumeSession(storedID: "local-abc")
        let snapshot = try await connection.activateSession(sessionID: "local-abc")

        #expect(params(server, "session.activate").isEmpty)
        let resumes = params(server, "session.resume")
        #expect(resumes.count == 2)
        #expect(resumes.last?["omit_messages"]?.boolValue == true)
        #expect(snapshot.describesSameSession(as: handle))
        #expect(snapshot.pendingApproval?["request_id"]?.stringValue == "p-9")
        await connection.stop()
    }

    @Test func closeIsADetachOfThisSocketsSubscription() async throws {
        let (server, connection) = try await connect(authority: true, answer: Self.authorityAnswers)
        defer { server.stop() }

        _ = try await connection.createSession()
        #expect(await connection.closeSession(sessionID: "local-abc") == .closed)

        #expect(params(server, "session.close").isEmpty)
        let detach = try #require(params(server, "session.detach").first)
        #expect(keys(detach) == ["session_id", "subscription_id"])
        #expect(detach["subscription_id"]?.stringValue == "sub-1")
        #expect(await connection.authoritySubscriptions["local-abc"] == nil)
        // A second close has nothing left to detach.
        #expect(await connection.closeSession(sessionID: "local-abc") != .closed)
        #expect(params(server, "session.detach").count == 1)
        await connection.stop()
    }

    // MARK: Pure translation

    @Test func legacySnapshotKeepsCanonicalKeysAndAddsLegacyOnes() throws {
        let raw = try JSONDecoder().decode(JSONValue.self, from: Data(Self.snapshot.utf8))
        let mapped = AuthorityWire.legacySnapshot(raw)
        #expect(mapped["subscription_id"]?.stringValue == "sub-1")
        #expect(mapped["session_key"]?.stringValue == "local-abc")
        #expect(mapped["started_at"]?.intValue == 7)
        #expect(mapped["status"]?.stringValue == "idle")
        #expect(mapped["pending_clarify"] == nil)
        #expect(mapped["pending_approval"]?["prompt_id"]?.stringValue == "p-9")
        #expect(LiveSessionSnapshot(result: mapped) != nil)
    }

    @Test func createParamsTranslation() {
        let legacy: [String: JSONValue] = [
            "cols": 96, "source": "desktop", "cwd": "/w", "cwd_explicit": true, "profile": "p",
        ]
        let canonical = AuthorityWire.createParams(legacy)
        #expect(canonical["cols"] == nil)
        #expect(canonical["source"]?.stringValue == "gui")
        #expect(canonical["cwd"]?.stringValue == "/w")
        #expect(canonical["profile"]?.stringValue == "p")
    }
}
