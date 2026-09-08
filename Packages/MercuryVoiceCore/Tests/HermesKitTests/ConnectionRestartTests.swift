import Foundation
import Testing
@testable import HermesKit

/// Real supervisor and loopback sockets; only actor-suspension timing is gated.
/// Removing the lifetime checks lets retired cleanup erase the replacement's
/// gateway or publish an obsolete event/refusal after the replacement is ready.
@Suite struct ConnectionRestartTests {
    @Test(arguments: [
        (HermesConnection.SupervisorCheckpoint.eventsEnded, UInt16(1000)),
        (.closeCauseRead, 4401), (.closeCauseRead, 4403), (.closeCauseRead, 1000),
        (.closeReasonRead, 4403), (.closeReasonRead, 1000),
        (.eventReceived, 1000), (.connected, 1000), (.connectFailed, 4403),
    ])
    func retiredSupervisorCannotMutateReplacement(
        checkpoint: HermesConnection.SupervisorCheckpoint, closeCode: UInt16
    ) async throws {
        let server = try await LoopbackGatewayServer.start { server in
            if checkpoint == .connectFailed && server.upgradeAttempts == 1 {
                server.close(code: 4403)
            } else {
                server.sendEvent(type: "gateway.ready", payload: #"{"replay_epoch":"live"}"#)
            }
        }
        defer { server.stop() }
        let gate = SupervisorGate(checkpoint)
        let endpoint = ServerEndpoint(baseURL: URL(string: "http://127.0.0.1:\(server.port)")!)
        let connection = HermesConnection(
            endpoint: endpoint,
            authenticator: HermesAuthenticator(endpoint: endpoint, credentials: nil),
            supervisorCheckpoint: { await gate.visit($0) })
        let log = RestartUpdateLog()
        let updates = await connection.updates()
        let collector = Task {
            for await update in updates { await log.append(update) }
        }
        defer { collector.cancel() }
        await connection.start()
        let handshake = checkpoint == .connected || checkpoint == .connectFailed
        if !handshake {
            #expect(await eventually { await connection.phase == .ready(isReconnect: false) })
            // A received marker proves subscription is installed before ending
            // the stream; no guessed sleep is used to position the old task.
            #expect(await eventually { await gate.subscribed == 1 })
            server.sendEvent(type: "old.marker")
            if checkpoint == .eventReceived {
                #expect(await eventually { await gate.isParked })
            } else {
                #expect(await eventually { await log.events.contains("old.marker") })
                if checkpoint == .eventsEnded {
                    await connection.stop()
                } else {
                    server.close(code: closeCode)
                }
            }
        }
        #expect(await eventually { await gate.isParked })
        await connection.stop()
        await connection.stop()  // idempotent even while cleanup is parked
        await connection.start()
        let replacementPhase = HermesConnection.Phase.ready(isReconnect: !handshake)
        #expect(await eventually { await connection.phase == replacementPhase })
        #expect(await connection.replayEpoch == "live")
        #expect(await eventually { await log.phases.last == replacementPhase })
        let baseline = await log.snapshot
        await gate.release()
        #expect(await eventually { await gate.finished >= 1 })
        // An old task has actually returned, not merely entered its cleanup.
        #expect(await connection.phase == replacementPhase)
        #expect(await connection.replayEpoch == "live")
        await connection.start()  // an obsolete terminal error must not clear the task handle
        #expect(await eventually { await gate.subscribed == (handshake ? 1 : 2) })
        server.sendEvent(type: "replacement.marker")
        #expect(await eventually { await log.events.contains("replacement.marker") })
        #expect(await log.phases == baseline.phases)
        if checkpoint == .eventReceived {
            #expect(await log.events == ["replacement.marker"])
        }
        #expect(server.upgradeAttempts == 2)
        await connection.stop()
        #expect(await eventually { await gate.finished == 2 })
        #expect(await connection.phase == .stopped)
        #expect(await connection.replayEpoch == nil)
    }

    @Test func repeatedStopStartKeepsEachReplacementUsable() async throws {
        let server = try await LoopbackGatewayServer.start { server in
            server.sendEvent(type: "gateway.ready", payload: #"{"replay_epoch":"live"}"#)
        }
        defer { server.stop() }
        let gate = SupervisorGate(.eventsEnded)
        let endpoint = ServerEndpoint(baseURL: URL(string: "http://127.0.0.1:\(server.port)")!)
        let connection = HermesConnection(
            endpoint: endpoint,
            authenticator: HermesAuthenticator(endpoint: endpoint, credentials: nil),
            supervisorCheckpoint: { await gate.visit($0) })
        await connection.start()
        #expect(await eventually { await connection.phase == .ready(isReconnect: false) })
        for cycle in 1...4 {
            await gate.arm()
            await connection.stop()
            #expect(await eventually { await gate.isParked })
            await connection.start()
            #expect(await eventually { await connection.phase == .ready(isReconnect: true) })
            await gate.release()
            #expect(await eventually { await gate.finished == cycle })
            #expect(await connection.replayEpoch == "live")
        }
        await connection.stop()
        #expect(await eventually { await gate.finished == 5 })
        #expect(await connection.phase == .stopped)
    }
}

private actor SupervisorGate {
    let target: HermesConnection.SupervisorCheckpoint
    private var armed = true
    private var continuation: CheckedContinuation<Void, Never>?
    private(set) var finished = 0
    private(set) var subscribed = 0
    var isParked: Bool { continuation != nil }

    init(_ target: HermesConnection.SupervisorCheckpoint) { self.target = target }

    func arm() { armed = true }

    func visit(_ checkpoint: HermesConnection.SupervisorCheckpoint) async {
        if checkpoint == .finished { finished += 1 }
        if checkpoint == .eventsSubscribed { subscribed += 1 }
        guard checkpoint == target, armed else { return }
        armed = false
        // Deliberately non-cooperative: cancellation must not bypass the
        // barrier. It models an already-enqueued actor read completing late.
        await withCheckedContinuation { continuation = $0 }
    }

    func release() {
        continuation?.resume()
        continuation = nil
    }
}

private actor RestartUpdateLog {
    private(set) var phases: [HermesConnection.Phase] = []
    private(set) var events: [String] = []
    var snapshot: (phases: [HermesConnection.Phase], events: [String]) { (phases, events) }

    func append(_ update: HermesConnection.Update) {
        switch update {
        case .phase(let phase): phases.append(phase)
        case .event(let event): events.append(event.type)
        }
    }
}
