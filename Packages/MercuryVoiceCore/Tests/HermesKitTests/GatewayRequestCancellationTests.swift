import Foundation
import Testing

@testable import HermesKit

/// Cancellation and completion accounting for gateway RPCs (issue #59).
///
/// A JSON-RPC call parks its caller on a continuation held in `pending` until
/// a reply, a write failure, a socket close or its own timeout arrives — and
/// `prompt.submit` runs with a 1,800 second timeout. So a cancelled caller
/// that is not handled explicitly stays suspended for up to half an hour,
/// keeps a timer alive, and still puts its frame on the wire. Each test below
/// pins one edge of "cancellation is observed, exactly once, and nothing is
/// left behind" — and, just as importantly, that cancelling locally neither
/// interrupts the backend nor tears down the socket.
@Suite("Gateway request cancellation")
struct GatewayRequestCancellationTests {
    // MARK: Cancellation is observed

    @Test func cancellingACallerReleasesItAndForgetsTheRequest() async throws {
        let (client, socket) = try await readyGatewayClient()
        let call = Task<RPCOutcome, Never> {
            await rpcOutcome {
                // The real prompt timeout: the whole point is that a
                // cancelled caller must not wait for it.
                try await client.request("prompt.submit", timeout: 1800)
            }
        }
        await socket.awaitSend(count: 1)  // the frame is on the wire

        call.cancel()

        #expect(await settled(call) == .cancelled)
        #expect(await client.pendingRequestCount == 0)
        #expect(await client.liveRequestTimeouts == 0)
        await client.close(reason: "test over")
    }

    @Test func anAlreadyCancelledCallerPutsNothingOnTheWire() async throws {
        let (client, socket) = try await readyGatewayClient()
        let gate = TestGate()
        let call = Task<RPCOutcome, Never> {
            await gate.wait()
            return await rpcOutcome {
                try await client.request("prompt.submit", timeout: 1800)
            }
        }
        // Cancel before the task can reach `request`, then let it run: the
        // send must be refused, not merely un-awaited. A prompt nobody is
        // waiting for still starts a turn on the backend.
        call.cancel()
        gate.openGate()

        #expect(await settled(call) == .cancelled)
        #expect(socket.sentFrames.isEmpty)
        #expect(await client.pendingRequestCount == 0)
        #expect(await client.liveRequestTimeouts == 0)
        await client.close(reason: "test over")
    }

    @Test func cancellationWinsOverTheNotConnectedCheck() async throws {
        let (client, socket) = try await readyGatewayClient()
        await client.close(reason: "server went away")
        let gate = TestGate()
        let call = Task<RPCOutcome, Never> {
            await gate.wait()
            return await rpcOutcome { try await client.request("session.create") }
        }
        call.cancel()
        gate.openGate()

        // Both answers are failures, but the caller asked to stop first —
        // reporting the socket state instead would invent a server story for
        // a purely local decision.
        #expect(await settled(call) == .cancelled)
        #expect(socket.sentFrames.isEmpty)
    }

    // MARK: Exactly-once completion under races

    @Test func cancellingAWriteThatHasNotFlushedYetKeepsTheSocketHealthy() async throws {
        // The write is handed to the transport but its completion has not
        // fired — the window where "unsend" does not exist. Here the socket is
        // fine and only the caller walked away, so the write later *succeeds*.
        let (client, socket) = try await readyGatewayClient(acknowledgesWrites: false)
        let call = Task<RPCOutcome, Never> {
            await rpcOutcome {
                try await client.request("prompt.submit", timeout: 1800)
            }
        }
        await socket.awaitSend(count: 1)
        let cancelledID = try #require(socket.sentRequestID(at: 0))

        call.cancel()
        #expect(await settled(call) == .cancelled)
        #expect(await client.pendingRequestCount == 0)

        // Everything that could still complete that request arrives late and
        // must be dropped: the flushed write, then the server's reply. A
        // second resume of the same continuation traps the process.
        #expect(socket.flushWrite(at: 0))
        socket.deliverReply(id: cancelledID, result: #"{"status":"streaming"}"#)

        // A fresh call proves the ignored frames were processed (the receive
        // loop is ordered) and that a purely local withdrawal cost the shared
        // socket nothing.
        let followUp = Task<RPCOutcome, Never> {
            await rpcOutcome { try await client.request("gateway.ping") }
        }
        await socket.awaitSend(count: 2)
        let pingID = try #require(socket.sentRequestID(at: 1))
        #expect(socket.flushWrite(at: 1))
        socket.deliverReply(id: pingID, result: #"{"pong":true}"#)

        #expect(await settled(followUp) == .value(.object(["pong": .bool(true)])))
        #expect(socket.cancelCount == 0)
        #expect(await client.state == .ready)
        #expect(await client.pendingRequestCount == 0)
        #expect(await client.liveRequestTimeouts == 0)
        await client.close(reason: "test over")
    }

    @Test func aTerminalWriteFailureSettlesEveryRequestOnceAndClosesTheSocket() async throws {
        // A send error is terminal for a URLSessionWebSocketTask — "If an
        // error occurs, any outstanding work will also fail"
        // (`NSURLSession.h:647`). So this is the other half of the case above:
        // one caller has already cancelled, two are still waiting, and the
        // failing write takes the receive down with it. Nothing may be
        // completed twice and no timer may outlive the calls.
        let (client, socket) = try await readyGatewayClient(acknowledgesWrites: false)
        let cancelled = Task<RPCOutcome, Never> {
            await rpcOutcome { try await client.request("prompt.submit", timeout: 1800) }
        }
        await socket.awaitSend(count: 1)
        cancelled.cancel()
        #expect(await settled(cancelled) == .cancelled)

        let failing = Task<RPCOutcome, Never> {
            await rpcOutcome { try await client.request("session.create", timeout: 1800) }
        }
        await socket.awaitSend(count: 2)
        let other = Task<RPCOutcome, Never> {
            await rpcOutcome { try await client.request("session.close", timeout: 1800) }
        }
        await socket.awaitSend(count: 3)

        // The whole task ends here: this write fails, so does the cancelled
        // caller's still-held write (a late failure for an id the client has
        // forgotten), so does the third caller's, and so does the parked
        // receive — which is what makes the client run its close sweep.
        #expect(socket.failWrite(at: 1))

        // URLSession does not order the write completions against the receive
        // failure, so either the send error or the close sweep may answer a
        // given caller. Both are correct; being answered twice is not.
        let dropped = ScriptedGatewaySocket.Dropped()
        let permitted: Set<String> = [
            "\(dropped)",
            HermesError.connectionClosed(dropped.errorDescription!).errorDescription!,
        ]
        let failingText = try #require(failureText(await settled(failing)))
        #expect(permitted.contains(failingText), "failed write ended as \(failingText)")
        let otherText = try #require(failureText(await settled(other)))
        #expect(permitted.contains(otherText), "other pending call ended as \(otherText)")

        #expect(await closed(client))
        #expect(await client.state == .closed(reason: dropped.errorDescription))
        #expect(socket.cancelCount == 1)  // the close sweep cancelled the socket
        #expect(await client.pendingRequestCount == 0)
        #expect(await client.liveRequestTimeouts == 0)

        // No healthy reuse after transport loss: the next call is refused
        // locally instead of being handed to a dead task.
        let after = Task<RPCOutcome, Never> {
            await rpcOutcome { try await client.request("gateway.ping") }
        }
        #expect(await settled(after) == .failure(HermesError.notConnected.errorDescription!))
        #expect(socket.sentFrames.count == 3)
    }

    @Test func closingWithAWriteInFlightSettlesItAndReleasesTheCallerOnce() async throws {
        let (client, socket) = try await readyGatewayClient(acknowledgesWrites: false)
        let call = Task<RPCOutcome, Never> {
            await rpcOutcome { try await client.request("prompt.submit", timeout: 1800) }
        }
        await socket.awaitSend(count: 1)

        // close() cancels the socket, and cancelling a task fails its
        // outstanding writes too — so a write failure arrives for a request
        // the close sweep has already released. It must find nothing to
        // resume; the caller keeps the close error it was given.
        await client.close(reason: "stopped")
        let closedError = HermesError.connectionClosed("stopped").errorDescription!
        #expect(await settled(call) == .failure(closedError))
        #expect(socket.cancelCount == 1)
        #expect(await client.pendingRequestCount == 0)
        #expect(await client.liveRequestTimeouts == 0)
    }

    @Test func aReplyAlreadyDeliveredIsNotUndoneByALateCancel() async throws {
        let (client, socket) = try await readyGatewayClient()
        let call = Task<RPCOutcome, Never> {
            await rpcOutcome { try await client.request("session.create") }
        }
        await socket.awaitSend(count: 1)
        let id = try #require(socket.sentRequestID(at: 0))
        socket.deliverReply(id: id, result: #"{"session_id":"s1"}"#)

        #expect(await settled(call) == .value(.object(["session_id": .string("s1")])))
        // Cancelling a call that already answered must not resume anything a
        // second time, nor leave a marker behind that a later request
        // inherits.
        call.cancel()
        #expect(await client.pendingRequestCount == 0)
        #expect(await client.liveRequestTimeouts == 0)
        await client.close(reason: "test over")
    }

    @Test func closeAfterACancelCompletesNothingTwice() async throws {
        let (client, socket) = try await readyGatewayClient()
        let call = Task<RPCOutcome, Never> {
            await rpcOutcome { try await client.request("prompt.submit", timeout: 1800) }
        }
        await socket.awaitSend(count: 1)

        call.cancel()
        #expect(await settled(call) == .cancelled)
        // close() sweeps `pending` with a connectionClosed error; the
        // cancelled entry must already be gone.
        await client.close(reason: "socket dropped")
        #expect(await client.pendingRequestCount == 0)
        #expect(await client.liveRequestTimeouts == 0)
    }

    @Test func aCloseThatArrivesFirstStillReportsTheConnectionError() async throws {
        let (client, socket) = try await readyGatewayClient()
        let call = Task<RPCOutcome, Never> {
            await rpcOutcome { try await client.request("prompt.submit", timeout: 1800) }
        }
        await socket.awaitSend(count: 1)

        // The socket drops under the request: the original error still wins,
        // cancellation only ever replaces *waiting*, never a real answer.
        socket.failReceive()
        let outcome = await settled(call)
        let dropped = ScriptedGatewaySocket.Dropped().errorDescription!
        #expect(outcome == .failure(HermesError.connectionClosed(dropped).errorDescription!))
        call.cancel()  // late, and a no-op
        #expect(await client.pendingRequestCount == 0)
        #expect(await client.liveRequestTimeouts == 0)
    }

    @Test func aTimeoutStillFiresAndLeavesNothingBehind() async throws {
        let (client, socket) = try await readyGatewayClient()
        let call = Task<RPCOutcome, Never> {
            await rpcOutcome { try await client.request("gateway.ping", timeout: 0.05) }
        }
        await socket.awaitSend(count: 1)

        #expect(
            await settled(call) == .failure(HermesError.timeout("gateway.ping").errorDescription!))
        #expect(await client.pendingRequestCount == 0)
        #expect(await client.liveRequestTimeouts == 0)
        await client.close(reason: "test over")
    }

    @Test func closeReleasesEveryPendingRequest() async throws {
        let (client, socket) = try await readyGatewayClient()
        let first = Task<RPCOutcome, Never> {
            await rpcOutcome { try await client.request("prompt.submit", timeout: 1800) }
        }
        await socket.awaitSend(count: 1)
        let second = Task<RPCOutcome, Never> {
            await rpcOutcome { try await client.request("session.close", timeout: 1800) }
        }
        await socket.awaitSend(count: 2)

        await client.close(reason: "stopped")
        let closed = HermesError.connectionClosed("stopped").errorDescription!
        #expect(await settled(first) == .failure(closed))
        #expect(await settled(second) == .failure(closed))
        #expect(await client.pendingRequestCount == 0)
        #expect(await client.liveRequestTimeouts == 0)
    }

    @Test(arguments: 0..<25)
    func cancelRacingAReplyProducesExactlyOneOutcome(iteration: Int) async throws {
        let (client, socket) = try await readyGatewayClient()
        let call = Task<RPCOutcome, Never> {
            await rpcOutcome { try await client.request("prompt.submit", timeout: 1800) }
        }
        await socket.awaitSend(count: 1)
        let id = try #require(socket.sentRequestID(at: 0))

        // Unsynchronised on purpose: whichever side lands first, the caller
        // must be resumed exactly once (a double resume traps) and the
        // request must be forgotten.
        let replier = Task { socket.deliverReply(id: id, result: #"{"status":"streaming"}"#) }
        call.cancel()
        _ = await replier.value

        let outcome = await settled(call)
        #expect(
            outcome == .cancelled
                || outcome == .value(.object(["status": .string("streaming")])),
            "iteration \(iteration) ended as \(String(describing: outcome))")
        #expect(await client.pendingRequestCount == 0)
        #expect(await client.liveRequestTimeouts == 0)
        await client.close(reason: "test over")
    }

    // MARK: Local cancellation is not a backend interrupt

    @Test func cancellingACallNeitherInterruptsTheBackendNorDropsTheSocket() async throws {
        let (client, socket) = try await readyGatewayClient()
        let call = Task<RPCOutcome, Never> {
            await rpcOutcome { try await client.request("prompt.submit", timeout: 1800) }
        }
        await socket.awaitSend(count: 1)

        call.cancel()
        #expect(await settled(call) == .cancelled)

        // Withdrawing locally says nothing about the turn the backend may
        // already be running: no session.interrupt is invented, and the
        // socket everyone else shares stays up.
        let followUp = Task<RPCOutcome, Never> {
            await rpcOutcome { try await client.request("gateway.ping") }
        }
        await socket.awaitSend(count: 2)
        let pingID = try #require(socket.sentRequestID(at: 1))
        socket.deliverReply(id: pingID, result: #"{"pong":true}"#)

        #expect(await settled(followUp) == .value(.object(["pong": .bool(true)])))
        #expect(socket.sentMethods == ["prompt.submit", "gateway.ping"])
        #expect(socket.cancelCount == 0)
        #expect(await client.state == .ready)
        await client.close(reason: "test over")
    }

    // MARK: The supervisor's passthrough

    @Test func theConnectionPassthroughAnswersACancelledCallerAsCancelled() async throws {
        // Never started, so there is no socket to blame — and the caller
        // stopped caring anyway.
        let connection = HermesConnection(
            endpoint: ServerEndpoint(baseURL: URL(string: "http://127.0.0.1:8080")!),
            token: nil)
        let gate = TestGate()
        let call = Task<RPCOutcome, Never> {
            await gate.wait()
            return await rpcOutcome { try await connection.request("session.create") }
        }
        call.cancel()
        gate.openGate()

        #expect(await settled(call) == .cancelled)
    }

    // MARK: Control

    @Test func anOrdinaryRoundTripLeavesNoContinuationOrTimer() async throws {
        let (client, socket) = try await readyGatewayClient()
        let call = Task<RPCOutcome, Never> {
            await rpcOutcome { try await client.request("gateway.ping") }
        }
        await socket.awaitSend(count: 1)
        let id = try #require(socket.sentRequestID(at: 0))
        socket.deliverErrorReply(id: id, code: -32601, message: "method not found")

        #expect(
            await settled(call)
                == .failure(
                    HermesError.rpcError(code: -32601, message: "method not found", data: nil)
                        .errorDescription!))
        #expect(await client.pendingRequestCount == 0)
        #expect(await client.liveRequestTimeouts == 0)
        await client.close(reason: "test over")
    }
}
