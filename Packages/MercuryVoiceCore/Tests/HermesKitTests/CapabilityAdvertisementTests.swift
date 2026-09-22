import Foundation
import Testing

@testable import HermesKit

/// Contract-7 backends only deliver approval/clarify prompts to a socket
/// that has advertised `client.capabilities {"server_requests": true}` on
/// it. `HermesConnection`'s supervisor must send that advertisement, and
/// await its reply, before publishing `.phase(.ready)` — `ConversationController`
/// answers ready with `session.resume`, so a late advertisement would race
/// the very first prompt of a session.
@Suite("Capability advertisement")
struct CapabilityAdvertisementTests {
    @Test func capabilitiesIsTheFirstFrameAndReadyWaitsForItsReply() async throws {
        // Default onOpen: the server sends `gateway.ready` immediately, the
        // way a real backend does — that is what unblocks `GatewayClient`'s
        // own `connect()` and lets the supervisor's `client.request` go out.
        let server = try await LoopbackGatewayServer.start(autoAnswersCapabilities: false)
        defer { server.stop() }
        let endpoint = ServerEndpoint(baseURL: URL(string: "http://127.0.0.1:\(server.port)")!)
        let connection = HermesConnection(
            endpoint: endpoint, authenticator: HermesAuthenticator(endpoint: endpoint, credentials: nil))
        let updates = await connection.updates()
        let log = PhaseCollector()
        let collector = Task {
            for await update in updates {
                if case .phase(let phase) = update { await log.append(phase) }
            }
        }
        defer { collector.cancel() }

        await connection.start()

        #expect(await eventually { server.receivedMethods == ["client.capabilities"] })
        // The frame actually carries the capability, not just the method —
        // a regression sending `server_requests: false` (or no params at
        // all) must fail this, not merely "some frame went out".
        let capabilitiesFrame = try #require(server.receivedFrames.first)
        #expect(capabilitiesFrame["params"]?["server_requests"]?.boolValue == true)
        // The reply has not been sent yet: ready must not have been published.
        #expect(await connection.phase != .ready(isReconnect: false))
        #expect(await !log.phases.contains(.ready(isReconnect: false)))

        server.answerCapabilities()

        // A short deadline here, not the suite default (5s, same as the
        // capabilities request's own timeout): a bug that makes `ready`
        // depend on the timeout firing instead of processing this reply
        // must show up as a failure, not a slow pass.
        #expect(await eventually(timeout: 1) { await connection.phase == .ready(isReconnect: false) })
        #expect(server.receivedMethods == ["client.capabilities"])

        await connection.stop()
    }

    @Test func aContract6BackendsErrorReplyStillReachesReady() async throws {
        let server = try await LoopbackGatewayServer.start(autoAnswersCapabilities: false)
        defer { server.stop() }
        let endpoint = ServerEndpoint(baseURL: URL(string: "http://127.0.0.1:\(server.port)")!)
        let connection = HermesConnection(
            endpoint: endpoint, authenticator: HermesAuthenticator(endpoint: endpoint, credentials: nil))
        await connection.start()

        #expect(await eventually { server.receivedMethods == ["client.capabilities"] })
        server.answerCapabilities(asError: true)  // -32601, as a contract-6 backend answers

        // Same reasoning as above: must reach ready promptly from the error
        // reply, not from the 5s request timeout expiring underneath it.
        #expect(await eventually(timeout: 1) { await connection.phase == .ready(isReconnect: false) })

        await connection.stop()
    }

    @Test func aSocketDroppedDuringTheCapabilitiesAwaitNeverPublishesReadyForThatGeneration()
        async throws
    {
        let server = try await LoopbackGatewayServer.start(autoAnswersCapabilities: false)
        defer { server.stop() }
        let endpoint = ServerEndpoint(baseURL: URL(string: "http://127.0.0.1:\(server.port)")!)
        // A large fixed backoff: once the dropped socket sends this
        // generation to `.disconnected`, nothing should race a redial while
        // the assertions below run.
        let connection = HermesConnection(
            endpoint: endpoint,
            authenticator: HermesAuthenticator(endpoint: endpoint, credentials: nil),
            supervisorCheckpoint: nil, backoffDelay: 60)
        let updates = await connection.updates()
        let log = PhaseCollector()
        let collector = Task {
            for await update in updates {
                if case .phase(let phase) = update { await log.append(phase) }
            }
        }
        defer { collector.cancel() }

        await connection.start()
        #expect(await eventually { server.receivedMethods == ["client.capabilities"] })

        // Kill the transport with the capabilities reply still withheld —
        // the request that's awaiting it must fail out from under the
        // supervisor instead of ever seeing a reply.
        server.dropConnections()

        #expect(
            await eventually {
                await log.phases.contains { if case .disconnected = $0 { return true }; return false }
            })
        #expect(!(await log.phases.contains(.ready(isReconnect: false))))
        #expect(await connection.phase != .ready(isReconnect: false))

        await connection.stop()
    }
}

private actor PhaseCollector {
    private(set) var phases: [HermesConnection.Phase] = []
    func append(_ phase: HermesConnection.Phase) { phases.append(phase) }
}
