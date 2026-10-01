import Foundation
import Testing

@testable import HermesKit

/// Issue #146 item 7 (upstream e33f1a0faf): window-owned bridges
/// (`preview.read`, `preview.act`, `terminal.read`, `window.read`, `tour`)
/// are answered only by a desktop window showing the session. A backend
/// that advertises `declines_not_shown` counts a 4404 as one client
/// abstaining, and settles the request with a refusal only once every
/// attached client declined. This app can never show one, so it declines
/// at once there — otherwise its silence alone keeps the agent waiting out
/// the whole deadline even when every desktop window already declined.
@Suite("Not-shown declines")
struct NotShownDeclineTests {
    private static func frame(_ method: String, id: String = "srq-aaaaaaaaaaaa") -> String {
        #"{"jsonrpc":"2.0","id":"\#(id)","method":"\#(method)","params":{"session_id":"s1"}}"#
    }

    /// Delivers `frame`, then a routed approval: once the approval's event is
    /// out, the first frame has provably been processed.
    private func deliver(_ frame: String, to socket: ScriptedGatewaySocket, events: AsyncStream<GatewayEvent>) async {
        socket.deliverText(frame)
        socket.deliverText(
            #"{"jsonrpc":"2.0","id":"srq-0123456789ab","method":"approval","params":{"session_id":"s1","request_id":"a1","command":"ls","choices":["once","deny"]}}"#
        )
        var iterator = events.makeAsyncIterator()
        _ = await iterator.next()
    }

    @Test(arguments: ["preview.read", "preview.act", "terminal.read", "window.read", "tour"])
    func aWindowOwnedRequestIsDeclinedWhenTheBackendCountsDeclines(method: String) async throws {
        let (client, socket) = try await readyGatewayClient()
        await client.setBackendCountsDeclines(true)
        let events = await client.events()

        await deliver(Self.frame(method), to: socket, events: events)

        let sent = try #require(socket.sentFrames.first)
        let reply = try JSONDecoder().decode(JSONValue.self, from: Data(sent.utf8))
        #expect(socket.sentFrames.count == 1)
        #expect(reply["id"]?.stringValue == "srq-aaaaaaaaaaaa")
        #expect(reply["method"] == nil)
        #expect(reply["error"]?["code"]?.intValue == 4404)
        #expect(reply["result"] == nil)
        await client.close(reason: "test over")
    }

    /// An older backend settles a request on the first error, which would
    /// take it away from a desktop that can serve it: stay silent there.
    @Test func noDeclineWithoutTheCapability() async throws {
        let (client, socket) = try await readyGatewayClient()
        let events = await client.events()

        await deliver(Self.frame("tour"), to: socket, events: events)

        #expect(socket.sentFrames.isEmpty)
        await client.close(reason: "test over")
    }

    /// Only the known window-owned bridges: an unknown method might be one
    /// this app simply predates.
    @Test func unknownMethodsAreNotDeclined() async throws {
        let (client, socket) = try await readyGatewayClient()
        await client.setBackendCountsDeclines(true)
        let events = await client.events()

        await deliver(Self.frame("future.thing"), to: socket, events: events)

        #expect(socket.sentFrames.isEmpty)
        await client.close(reason: "test over")
    }

    // MARK: Through the real connection

    private func connect(capabilities: String) async throws
        -> (LoopbackGatewayServer, HermesConnection)
    {
        let server = try await LoopbackGatewayServer.start(
            onRequest: { frame in
                guard frame["method"]?.stringValue == "gateway.ping" else { return nil }
                return #"{"jsonrpc":"2.0","id":\#(frame["id"]?.intValue ?? 0),"result":{"pong":true}}"#
            },
            capabilitiesResult: capabilities)
        let endpoint = ServerEndpoint(baseURL: URL(string: "http://127.0.0.1:\(server.port)")!)
        let connection = HermesConnection(endpoint: endpoint, token: nil)
        await connection.start()
        #expect(await eventually { await connection.phase == .ready(isReconnect: false) })
        return (server, connection)
    }

    private func declines(_ server: LoopbackGatewayServer) -> [JSONValue] {
        server.receivedFrames.filter { $0["error"]?["code"]?.intValue == 4404 }
    }

    @Test func theCapabilitiesReplySwitchesDeclinesOn() async throws {
        let (server, connection) = try await connect(
            capabilities: #"{"server_requests":["approval","clarify"],"declines_not_shown":true}"#)
        defer { server.stop() }

        server.send(Self.frame("terminal.read", id: "srq-bbbbbbbbbbbb"))
        #expect(await eventually { self.declines(server).count == 1 })
        #expect(declines(server).first?["id"]?.stringValue == "srq-bbbbbbbbbbbb")
        await connection.stop()
    }

    @Test func aBackendWithoutTheCapabilityGetsNoDecline() async throws {
        let (server, connection) = try await connect(capabilities: #"{"server_requests":[]}"#)
        defer { server.stop() }

        server.send(Self.frame("terminal.read", id: "srq-bbbbbbbbbbbb"))
        // A follow-up round trip proves the bridge frame was processed first.
        _ = try await connection.request("gateway.ping", params: nil)
        #expect(declines(server).isEmpty)
        await connection.stop()
    }
}
