import Foundation
import Testing

@testable import HermesKit

/// `request.answer {id, result}` (contract ≥ 7) — answers an open
/// server→client request. The params shape and the `status` mapping live on
/// `ServerRequestAnswer` itself (`answerParams(id:result:)`, `init(reply:)`)
/// so `SessionAPI.answerServerRequest` and these tests share one source of
/// truth instead of the tests re-deriving the production logic.
@Suite("request.answer encoding")
struct ServerRequestAnswerTests {
    // MARK: Params shape

    @Test func answerParamsCarriesExactlyIDAndResult() throws {
        let params = ServerRequestAnswer.answerParams(
            id: "srq-aaaaaaaaaaaa", result: .object(["choice": .string("once")]))
        #expect(params.objectValue?.keys.sorted() == ["id", "result"])
        #expect(params["id"]?.stringValue == "srq-aaaaaaaaaaaa")
        #expect(params["result"]?["choice"]?.stringValue == "once")
    }

    // MARK: Status mapping

    @Test func okStatusMapsToAnswered() throws {
        #expect(ServerRequestAnswer(reply: try json(#"{"status":"ok"}"#)) == .answered)
    }

    @Test func expiredStatusMapsToExpired() throws {
        #expect(ServerRequestAnswer(reply: try json(#"{"status":"expired"}"#)) == .expired)
    }

    @Test func anUnrecognisedOrAbsentStatusMapsToAnswered() throws {
        #expect(ServerRequestAnswer(reply: try json(#"{"status":"something-new"}"#)) == .answered)
        #expect(ServerRequestAnswer(reply: try json(#"{}"#)) == .answered)
    }

    private func json(_ string: String) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: Data(string.utf8))
    }

    // MARK: Wire encoding, through the same request path `answerServerRequest` uses

    /// `SessionAPI.answerServerRequest` is a thin extension on the
    /// `HermesConnection` actor, which has no seam for injecting a scripted
    /// socket (unlike `GatewayClient`, which `readyGatewayClient()` wires
    /// directly). So this exercises the production `ServerRequestAnswer`
    /// helpers — `method`, `answerParams(id:result:)`, `init(reply:)` — over
    /// `GatewayClient.request`, the same call `answerServerRequest` makes,
    /// against the same scripted-socket helper
    /// `ServerRequestRoutingTests`/`GatewayRequestCancellationTests` use.
    @Test func sendsIDAndResultAndMapsAnOkStatusToAnswered() async throws {
        let (client, socket) = try await readyGatewayClient()
        let call = Task<RPCOutcome, Never> {
            await rpcOutcome {
                try await client.request(
                    ServerRequestAnswer.method,
                    params: ServerRequestAnswer.answerParams(
                        id: "srq-aaaaaaaaaaaa", result: .object(["choice": .string("once")])))
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
        #expect(ServerRequestAnswer(reply: result) == .answered)
        await client.close(reason: "test over")
    }

    @Test func mapsAnExpiredStatusToExpired() async throws {
        let (client, socket) = try await readyGatewayClient()
        let call = Task<RPCOutcome, Never> {
            await rpcOutcome {
                try await client.request(
                    ServerRequestAnswer.method,
                    params: ServerRequestAnswer.answerParams(
                        id: "srq-bbbbbbbbbbbb", result: .object(["answer": .string("dev")])))
            }
        }
        await socket.awaitSend(count: 1)
        let id = try #require(socket.sentRequestID(at: 0))
        socket.deliverReply(id: id, result: #"{"status":"expired"}"#)
        guard case .value(let result) = await settled(call) else {
            Issue.record("request.answer did not settle with a value")
            return
        }
        #expect(ServerRequestAnswer(reply: result) == .expired)
        await client.close(reason: "test over")
    }
}
