import Foundation
import Testing

@testable import HermesKit

/// Opt-in live check of the session-authority wire against a real v0.23
/// gateway. Skipped unless `MERCURY_AUTHORITY_LIVE_URL` names an `http://`
/// base whose `/api/ws` reaches a session authority with no credentials —
/// in practice a local relay that mints a `session-ticket` over
/// `~/.hermes/gateway.sock` per dial and forwards to the gateway's loopback
/// `api_origin` with the `hermes-gateway-v1` subprotocols (the app itself
/// reaches a Webapp with its usual `/api/auth/ws-ticket` ticket instead).
///
/// Runs real agent turns. Prints the session id: delete it afterwards with
/// `hermes sessions delete --yes <id>`.
@Suite("session authority live", .serialized)
struct SessionAuthorityLiveTests {
    static let base = ProcessInfo.processInfo.environment["MERCURY_AUTHORITY_LIVE_URL"]

    private func wait(
        _ updates: inout AsyncStream<HermesConnection.Update>.Iterator,
        seconds: Double = 180,
        until match: (GatewayEvent) -> Bool
    ) async -> GatewayEvent? {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            guard let update = await updates.next() else { return nil }
            if case .event(let event) = update {
                print("live event:", event.type, event.executionGeneration.map(String.init) ?? "-")
                if match(event) { return event }
            }
        }
        return nil
    }

    @Test(.enabled(if: base != nil))
    func fullConversationOverTheAuthority() async throws {
        let endpoint = ServerEndpoint(baseURL: URL(string: Self.base!)!)
        let connection = HermesConnection(endpoint: endpoint, token: nil)
        var updates = await connection.updates().makeAsyncIterator()
        await connection.start()
        #expect(await eventually(timeout: 15) { await connection.phase == .ready(isReconnect: false) })
        #expect(await connection.speaksSessionAuthority)

        let handle = try await connection.createSession(title: "mercury authority live test")
        let sid = handle.runtimeID
        print("LIVE SESSION:", sid)

        // 1. A plain spoken turn completes.
        try await connection.submitPrompt(sessionID: sid, text: "Reply with exactly the word: ok")
        let done = await wait(&updates) { $0.type == "message.complete" && $0.sessionID == sid }
        #expect(done != nil)

        // 2. Interrupt a running turn: fenced by the generation the frames carry.
        try await connection.submitPrompt(
            sessionID: sid,
            text: "Write the numbers from 1 to 400 as words, one per line. No tools.")
        let started = await wait(&updates) {
            ($0.type == "message.delta" || $0.type == "message.start") && $0.sessionID == sid
        }
        #expect(started != nil)
        try await connection.interruptSession(sessionID: sid)
        let stopped = await wait(&updates) { $0.type == "message.complete" && $0.sessionID == sid }
        print("interrupted completion:", stopped?.payload["status"] ?? "nil")

        // 3. Approval round trip (deny), if the model asks for one.
        try await connection.submitPrompt(
            sessionID: sid,
            text: "Use the terminal tool to run exactly this command: rm -rf /tmp/mercury-authority-probe-does-not-exist . Do not ask me first; just run it.")
        let asked = await wait(&updates) {
            ($0.type == "approval.request" || $0.type == "message.complete") && $0.sessionID == sid
        }
        if let asked, let approval = ApprovalRequest(event: asked) {
            print("approval:", approval.requestID ?? "nil", approval.executionGeneration ?? -1)
            try await connection.respondApproval(approval, choice: "deny")
            _ = await wait(&updates) { $0.type == "message.complete" && $0.sessionID == sid }
        } else {
            print("no approval was raised; skipped approval.respond")
        }

        // 4. Clarify round trip, if the model asks.
        try await connection.submitPrompt(
            sessionID: sid,
            text: "Use the clarify tool to ask me one question: red or blue? Offer exactly those two choices.")
        let clarifyAsked = await wait(&updates) {
            ($0.type == "clarify.request" || $0.type == GatewayEvent.Kind.serverRequest
                || $0.type == "message.complete") && $0.sessionID == sid
        }
        if let clarifyAsked, let clarify = ClarifyRequest(event: clarifyAsked) {
            print("clarify event:", clarify.requestID, clarify.executionGeneration ?? -1)
            try await connection.respondClarify(clarify, answer: "blue")
            _ = await wait(&updates) { $0.type == "message.complete" && $0.sessionID == sid }
        } else if let clarifyAsked, let request = ServerRequest(event: clarifyAsked),
            let clarify = ClarifyRequest(serverRequest: request)
        {
            print("clarify srq:", clarify.requestID)
            let answer = try await connection.answerServerRequest(
                id: request.id, result: ["answer": "blue"])
            print("request.answer:", answer)
            _ = await wait(&updates) { $0.type == "message.complete" && $0.sessionID == sid }
        } else {
            print("no clarify was raised; skipped clarify.respond")
        }

        // 5. The reconnect re-read, then leaving.
        let resumed = try await connection.resumeSession(storedID: sid)
        let snapshot = try await connection.activateSession(sessionID: sid)
        #expect(snapshot.describesSameSession(as: resumed))
        #expect(await connection.closeSession(sessionID: sid) == .closed)
        await connection.stop()
    }
}
