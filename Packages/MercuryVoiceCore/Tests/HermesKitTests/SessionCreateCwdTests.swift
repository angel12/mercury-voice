import Foundation
import Testing

@testable import HermesKit

/// Issue #144 item 2 (upstream a9972dc3f9, 66bc259712): a named profile's
/// `terminal.cwd` now beats the `cwd` sent with `session.create` unless the
/// client marks it `cwd_explicit: true`. Every cwd the app sends is a project
/// the user tapped, so it is always explicit. Backends before 66bc259712
/// declare no such key and, with `extra="forbid"` params, answer 4000 naming
/// it — those get one retry without the flag (they never let the profile cwd
/// win anyway).
@Suite("session.create cwd_explicit")
struct SessionCreateCwdTests {
    private static let created = #""result":{"session_id":"rt-1","stored_session_id":"st-1"}"#

    private func reply(_ frame: JSONValue, _ body: String) -> String {
        #"{"jsonrpc":"2.0","id":\#(frame["id"]?.intValue ?? 0),\#(body)}"#
    }

    private func connect(
        onCreate: @escaping @Sendable (JSONValue, Int) -> String
    ) async throws -> (LoopbackGatewayServer, HermesConnection) {
        let creates = Counter()
        let server = try await LoopbackGatewayServer.start(onRequest: { frame in
            guard frame["method"]?.stringValue == "session.create" else { return nil }
            return onCreate(frame, creates.next())
        })
        let endpoint = ServerEndpoint(baseURL: URL(string: "http://127.0.0.1:\(server.port)")!)
        let connection = HermesConnection(endpoint: endpoint, token: nil)
        await connection.start()
        #expect(await eventually { await connection.phase == .ready(isReconnect: false) })
        return (server, connection)
    }

    private func createParams(_ server: LoopbackGatewayServer) -> [JSONValue] {
        server.receivedFrames
            .filter { $0["method"]?.stringValue == "session.create" }
            .compactMap { $0["params"] }
    }

    @Test func projectCwdIsSentAsExplicit() async throws {
        let (server, connection) = try await connect { frame, _ in
            self.reply(frame, Self.created)
        }
        defer { server.stop() }

        let handle = try await connection.createSession(cwd: "/work/repo", profile: "voice")

        #expect(handle.runtimeID == "rt-1")
        let params = try #require(createParams(server).first)
        #expect(params["cwd"]?.stringValue == "/work/repo")
        #expect(params["cwd_explicit"]?.boolValue == true)
        await connection.stop()
    }

    @Test func noCwdSendsNoFlag() async throws {
        let (server, connection) = try await connect { frame, _ in
            self.reply(frame, Self.created)
        }
        defer { server.stop() }

        _ = try await connection.createSession(cwd: nil, profile: "voice")

        let params = try #require(createParams(server).first)
        #expect(params["cwd"] == nil)
        #expect(params["cwd_explicit"] == nil)
        await connection.stop()
    }

    @Test func olderBackendRejectingTheKeyGetsOneRetryWithoutIt() async throws {
        let (server, connection) = try await connect { frame, attempt in
            if attempt == 0 {
                return self.reply(
                    frame,
                    #""error":{"code":4000,"message":"invalid params for session.create: cwd_explicit: Extra inputs are not permitted — the client and the Hermes backend are out of sync"}"#
                )
            }
            return self.reply(frame, Self.created)
        }
        defer { server.stop() }

        let handle = try await connection.createSession(cwd: "/work/repo")

        #expect(handle.runtimeID == "rt-1")
        let params = createParams(server)
        #expect(params.count == 2)
        #expect(params.last?["cwd"]?.stringValue == "/work/repo")
        #expect(params.last?["cwd_explicit"] == nil)
        await connection.stop()
    }

    @Test func anUnrelated4000IsNotRetried() async throws {
        let (server, connection) = try await connect { frame, _ in
            self.reply(
                frame,
                #""error":{"code":4000,"message":"invalid params for session.create: title: Extra inputs are not permitted"}"#
            )
        }
        defer { server.stop() }

        await #expect(throws: HermesError.self) {
            _ = try await connection.createSession(cwd: "/work/repo")
        }
        #expect(createParams(server).count == 1)
        await connection.stop()
    }
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func next() -> Int { lock.withLock { defer { value += 1 }; return value } }
}
