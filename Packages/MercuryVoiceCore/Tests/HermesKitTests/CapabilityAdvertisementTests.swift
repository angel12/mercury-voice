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
        // The reply has not been sent yet: ready must not have been published.
        #expect(await connection.phase != .ready(isReconnect: false))
        #expect(await !log.phases.contains(.ready(isReconnect: false)))

        server.answerCapabilities()

        #expect(await eventually { await connection.phase == .ready(isReconnect: false) })
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

        #expect(await eventually { await connection.phase == .ready(isReconnect: false) })

        await connection.stop()
    }
}

private actor PhaseCollector {
    private(set) var phases: [HermesConnection.Phase] = []
    func append(_ phase: HermesConnection.Phase) { phases.append(phase) }
}
