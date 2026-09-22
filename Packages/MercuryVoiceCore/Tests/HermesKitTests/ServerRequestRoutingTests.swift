import Foundation
import Testing

@testable import HermesKit

/// Contract v7 (hermes-agent d3a44784b1): blocking prompts are JSON-RPC
/// requests the *server* sends, ids `srq-<12hex>`. The client surfaces the
/// ones it can answer and leaves the rest for another attached client.
@Suite("Server request routing")
struct ServerRequestRoutingTests {
    @Test func anApprovalRequestFrameIsSurfacedAsAnEvent() async throws {
        let (client, socket) = try await readyGatewayClient()
        let events = await client.events()
        socket.deliverText(
            #"{"jsonrpc":"2.0","id":"srq-0123456789ab","method":"approval","params":{"session_id":"s1","request_id":"a1","command":"ls","choices":["once","deny"]}}"#
        )
        var iterator = events.makeAsyncIterator()
        let event = try #require(await iterator.next())
        #expect(event.type == GatewayEvent.Kind.serverRequest)
        #expect(event.sessionID == "s1")
        let request = try #require(ServerRequest(event: event))
        #expect(request.id == "srq-0123456789ab")
        #expect(request.method == "approval")
        #expect(request.params["request_id"]?.stringValue == "a1")
        #expect(socket.sentFrames.isEmpty)  // answered later, by request.answer
        await client.close(reason: "test over")
    }

    /// An unsupported request (sudo, secret, vault.*, preview, tour, …) is
    /// dropped: no error reply, no event. The first response frame settles
    /// a server request for every attached client (upstream
    /// `resolve_response`), so a refusal would take it away from a
    /// co-attached desktop that can render it (#125, PR #126 review).
    /// Proved with more than silence — a supported frame delivered *after*
    /// the unsupported one is the first event out, and by then the socket
    /// has still seen no write, so the unsupported frame was provably
    /// processed and provably produced nothing.
    @Test func anUnsupportedRequestIsLeftForAnotherClient() async throws {
        let (client, socket) = try await readyGatewayClient()
        let events = await client.events()
        socket.deliverText(
            #"{"jsonrpc":"2.0","id":"srq-aaaaaaaaaaaa","method":"sudo","params":{"session_id":"s1","command":"x"}}"#
        )
        socket.deliverText(
            #"{"jsonrpc":"2.0","id":"srq-0123456789ab","method":"approval","params":{"session_id":"s1","request_id":"a1","command":"ls","choices":["once","deny"]}}"#
        )
        var iterator = events.makeAsyncIterator()
        let event = try #require(await iterator.next())
        let request = try #require(ServerRequest(event: event))
        #expect(request.id == "srq-0123456789ab")
        #expect(request.method == "approval")
        #expect(socket.sentFrames.isEmpty)
        await client.close(reason: "test over")
    }

    /// A response frame (no `method`) with a string id is not ours to route:
    /// it must be silently ignored, not refused. Proved with more than a lack
    /// of an immediate refusal — a *pending* int-id request, sent before the
    /// string-id frame arrives, still resolves correctly afterward, so the
    /// string-id frame provably never touched `pending` or produced a wire
    /// reply.
    @Test func aStringIDResponseIsNotMistakenForARequest() async throws {
        let (client, socket) = try await readyGatewayClient()
        let call = Task<RPCOutcome, Never> {
            await rpcOutcome { try await client.request("gateway.ping") }
        }
        await socket.awaitSend(count: 1)
        let pingID = try #require(socket.sentRequestID(at: 0))

        socket.deliverText(#"{"jsonrpc":"2.0","id":"srq-bbbbbbbbbbbb","result":{}}"#)
        // The stray string-id frame must not have produced a refusal or any
        // other reply on the wire.
        #expect(socket.sentFrames.count == 1)

        socket.deliverReply(id: pingID, result: #"{"pong":true}"#)
        #expect(await settled(call) == .value(.object(["pong": .bool(true)])))
        #expect(await client.pendingRequestCount == 0)
        await client.close(reason: "test over")
    }

    @Test func anOpenRequestsSnapshotEntryDecodesLikeAFrame() throws {
        let entry = try JSONDecoder().decode(
            JSONValue.self,
            from: Data(
                #"{"id":"srq-cccccccccccc","method":"clarify","params":{"session_id":"s1","question":"Which?"}}"#
                    .utf8))
        let request = try #require(ServerRequest(snapshot: entry))
        #expect(request.method == "clarify")
        #expect(request.sessionID == "s1")
    }
}
