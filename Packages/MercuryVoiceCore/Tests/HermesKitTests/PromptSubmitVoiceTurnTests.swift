import Foundation
import Testing

@testable import HermesKit

/// Issue #148 (upstream 6cc1efd8f9): spoken turns carry `voice_turn: true` so
/// the backend runs them on `auxiliary.voice_chat` with reasoning off. Older
/// backends declare no such key and, with `extra="forbid"` params, answer 4000
/// naming it before the handler runs — those get one retry without it, and the
/// key stays off for the rest of the connection.
@Suite("prompt.submit voice_turn")
struct PromptSubmitVoiceTurnTests {
    private static let streaming = #""result":{"status":"streaming"}"#
    private static let rejected =
        #""error":{"code":4000,"message":"invalid params for prompt.submit: voice_turn: Extra inputs are not permitted — the client and the Hermes backend are out of sync"}"#

    private func reply(_ frame: JSONValue, _ body: String) -> String {
        #"{"jsonrpc":"2.0","id":\#(frame["id"]?.intValue ?? 0),\#(body)}"#
    }

    private func connect(
        onSubmit: @escaping @Sendable (JSONValue, Int) -> String
    ) async throws -> (LoopbackGatewayServer, HermesConnection) {
        let submits = Counter()
        let server = try await LoopbackGatewayServer.start(onRequest: { frame in
            guard frame["method"]?.stringValue == "prompt.submit" else { return nil }
            return onSubmit(frame, submits.next())
        })
        let endpoint = ServerEndpoint(baseURL: URL(string: "http://127.0.0.1:\(server.port)")!)
        let connection = HermesConnection(endpoint: endpoint, token: nil)
        await connection.start()
        #expect(await eventually { await connection.phase == .ready(isReconnect: false) })
        return (server, connection)
    }

    private func submitParams(_ server: LoopbackGatewayServer) -> [JSONValue] {
        server.receivedFrames
            .filter { $0["method"]?.stringValue == "prompt.submit" }
            .compactMap { $0["params"] }
    }

    @Test func spokenTurnIsMarked() async throws {
        let (server, connection) = try await connect { frame, _ in
            self.reply(frame, Self.streaming)
        }
        defer { server.stop() }

        try await connection.submitPrompt(sessionID: "rt-1", text: "hello", interrupted: true)

        let params = try #require(submitParams(server).first)
        #expect(params["voice_turn"]?.boolValue == true)
        #expect(params["interrupted"]?.boolValue == true)
        #expect(params["text"]?.stringValue == "hello")
        await connection.stop()
    }

    @Test func olderBackendGetsOneRetryThenNoKey() async throws {
        let (server, connection) = try await connect { frame, _ in
            let rejects = frame["params"]?["voice_turn"] != nil
            return self.reply(frame, rejects ? Self.rejected : Self.streaming)
        }
        defer { server.stop() }

        try await connection.submitPrompt(sessionID: "rt-1", text: "one")
        try await connection.submitPrompt(sessionID: "rt-1", text: "two")

        let params = submitParams(server)
        #expect(params.count == 3)
        #expect(params[1]["voice_turn"] == nil)
        #expect(params[1]["text"]?.stringValue == "one")
        #expect(params[2]["voice_turn"] == nil)
        #expect(params[2]["text"]?.stringValue == "two")
        await connection.stop()
    }

    @Test func anUnrelated4000IsNotRetried() async throws {
        let (server, connection) = try await connect { frame, _ in
            self.reply(
                frame,
                #""error":{"code":4000,"message":"invalid params for prompt.submit: surface: Extra inputs are not permitted"}"#
            )
        }
        defer { server.stop() }

        await #expect(throws: HermesError.self) {
            try await connection.submitPrompt(sessionID: "rt-1", text: "hello")
        }
        #expect(submitParams(server).count == 1)
        #expect(await connection.sendsVoiceTurn)
        await connection.stop()
    }
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func next() -> Int { lock.withLock { defer { value += 1 }; return value } }
}
