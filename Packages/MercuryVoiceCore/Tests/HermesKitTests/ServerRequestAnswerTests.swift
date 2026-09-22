import Foundation
import Testing

@testable import HermesKit

/// `request.answer {id, result}` (contract ≥ 7) — answers an open
/// server→client request. `SessionAPI.answerServerRequest` is a thin
/// extension on the `HermesConnection` actor, which has no seam for
/// injecting a scripted socket (unlike `GatewayClient`, which
/// `readyGatewayClient()` wires directly). So this exercises the exact wire
/// encoding and status mapping `answerServerRequest` uses — `{id, result}`
/// params and `status == "expired"` vs. anything else — against a
/// `GatewayClient` from `readyGatewayClient()`, the same helper
/// `ServerRequestRoutingTests`/`GatewayRequestCancellationTests` use.
@Suite("request.answer encoding")
struct ServerRequestAnswerTests {
    /// Mirrors the mapping in `SessionAPI.answerServerRequest`.
    private func mapAnswer(_ reply: JSONValue) -> ServerRequestAnswer {
        reply["status"]?.stringValue == "expired" ? .expired : .answered
    }

    @Test func sendsIdAndResultAndMapsAnOkStatusToAnswered() async throws {
        let (client, socket) = try await readyGatewayClient()
        let call = Task<RPCOutcome, Never> {
            await rpcOutcome {
                try await client.request(
                    "request.answer",
                    params: [
                        "id": .string("srq-aaaaaaaaaaaa"),
                        "result": .object(["choice": .string("once")]),
                    ])
            }
        }
        await socket.awaitSend(count: 1)
        let id = try #require(socket.sentRequestID(at: 0))
        let frame = try JSONDecoder().decode(
            JSONValue.self, from: Data(socket.sentFrames[0].utf8))
        #expect(frame["method"]?.stringValue == "request.answer")
        #expect(frame["params"]?["id"]?.stringValue == "srq-aaaaaaaaaaaa")
        #expect(frame["params"]?["result"]?["choice"]?.stringValue == "once")

        socket.deliverReply(id: id, result: #"{"status":"ok"}"#)
        guard case .value(let result) = await settled(call) else {
            Issue.record("request.answer did not settle with a value")
            return
        }
        #expect(mapAnswer(result) == .answered)
        await client.close(reason: "test over")
    }

    @Test func mapsAnExpiredStatusToExpired() async throws {
        let (client, socket) = try await readyGatewayClient()
        let call = Task<RPCOutcome, Never> {
            await rpcOutcome {
                try await client.request(
                    "request.answer",
                    params: [
                        "id": .string("srq-bbbbbbbbbbbb"),
                        "result": .object(["answer": .string("dev")]),
                    ])
            }
        }
        await socket.awaitSend(count: 1)
        let id = try #require(socket.sentRequestID(at: 0))
        socket.deliverReply(id: id, result: #"{"status":"expired"}"#)
        guard case .value(let result) = await settled(call) else {
            Issue.record("request.answer did not settle with a value")
            return
        }
        #expect(mapAnswer(result) == .expired)
        await client.close(reason: "test over")
    }
}
