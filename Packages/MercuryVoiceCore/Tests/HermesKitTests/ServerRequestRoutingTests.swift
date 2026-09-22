import Foundation
import Testing

@testable import HermesKit

/// Contract v7 (hermes-agent d3a44784b1): blocking prompts are JSON-RPC
/// requests the *server* sends, ids `srq-<12hex>`. The client surfaces the
/// ones it can answer and refuses the rest at once, so the agent does not
/// park for the 300 s clarify deadline on a frame nobody will answer.
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

    @Test func anUnsupportedRequestIsRefusedImmediately() async throws {
        let (client, socket) = try await readyGatewayClient()
        socket.deliverText(
            #"{"jsonrpc":"2.0","id":"srq-aaaaaaaaaaaa","method":"sudo","params":{"session_id":"s1","command":"x"}}"#
        )
        await socket.awaitSend(count: 1)
        let reply = try JSONDecoder().decode(
            JSONValue.self, from: Data(socket.sentFrames[0].utf8))
        #expect(reply["id"]?.stringValue == "srq-aaaaaaaaaaaa")
        #expect(reply["error"]?["code"]?.intValue == -32601)
        #expect(reply["method"] == nil)
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
