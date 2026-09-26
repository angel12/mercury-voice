import Foundation
import Testing

@testable import HermesKit

@Suite struct ConnectionBudgetTests {
    @Test(arguments: [false, true])
    func freshLifetimeOrSuccessfulHandshakeResetsBudget(successfulHandshake: Bool) async throws {
        let server = try await LoopbackGatewayServer.start { server in
            if successfulHandshake && server.upgradeAttempts == 10 {
                server.sendEvent(type: "gateway.ready")
            } else {
                server.close(code: 1011)
            }
        }
        defer { server.stop() }
        let checkpoints = BudgetCheckpoints()
        let endpoint = ServerEndpoint(baseURL: URL(string: "http://127.0.0.1:\(server.port)")!)
        let connection = HermesConnection(
            endpoint: endpoint,
            authenticator: HermesAuthenticator(endpoint: endpoint, credentials: nil),
            supervisorCheckpoint: { await checkpoints.visit($0) }, backoffDelay: 60)
        let updates = await connection.updates()
        let collector = Task {
            for await update in updates {
                guard case .phase(.disconnected) = update else { continue }
                // Stop after nine failures in the old lifetime. Otherwise
                // skip backoff only after it is registered by the actor.
                if !successfulHandshake && server.upgradeAttempts == 9 {
                    await connection.stop()
                } else {
                    await connection.pokeReconnect()
                }
            }
        }
        defer { collector.cancel() }
        await connection.start()
        if successfulHandshake {
            // Wait for `.ready`, not `.eventsSubscribed`: the subscription
            // precedes the `client.capabilities` round-trip, and a close that
            // beats its reply leaves this socket unready — a tenth failed dial
            // (#128), so the budget never resets and the run stops at 10.
            #expect(
                await eventually {
                    if case .ready = await connection.phase { return true }
                    return false
                })
            server.close(code: 1011)
        } else {
            #expect(await eventually { await checkpoints.finishes == 1 })
            #expect(server.upgradeAttempts == 9)
            await connection.start()
        }
        #expect(
            await eventually {
                if case .unreachable = await connection.phase { return true }
                return false
            })
        #expect(server.upgradeAttempts == (successfulHandshake ? 20 : 19))
        await connection.stop()
        collector.cancel()
        await collector.value
    }
    /// A socket that finishes the WebSocket handshake but dies before the
    /// `client.capabilities` reply is never published ready, so it must not
    /// reset the dial budget or the backoff attempt either (#128): a server
    /// that always dies there has to reach `.unreachable` like any other
    /// dead server, with the attempt count still growing.
    @Test func socketsThatDieBeforeReadyCountAgainstTheBudget() async throws {
        let server = try await LoopbackGatewayServer.start(autoAnswersCapabilities: false) {
            server in
            server.sendEvent(type: "gateway.ready")
            server.close(code: 1011)
        }
        defer { server.stop() }
        let endpoint = ServerEndpoint(baseURL: URL(string: "http://127.0.0.1:\(server.port)")!)
        let connection = HermesConnection(
            endpoint: endpoint,
            authenticator: HermesAuthenticator(endpoint: endpoint, credentials: nil),
            supervisorCheckpoint: nil, backoffDelay: 60)
        let updates = await connection.updates()
        let log = PhaseLog()
        let collector = Task {
            for await update in updates {
                guard case .phase(let phase) = update else { continue }
                log.append(phase)
                if case .disconnected = phase { await connection.pokeReconnect() }
                if case .unreachable = phase { return }
                if server.upgradeAttempts > 10 { return }
            }
        }
        await connection.start()
        #expect(
            await eventually {
                if case .unreachable = await connection.phase { return true }
                return server.upgradeAttempts > 10
            })
        collector.cancel()
        await collector.value
        let terminal = await connection.phase
        guard case .unreachable = terminal else {
            Issue.record("Expected unreachable, got \(terminal)")
            await connection.stop()
            return
        }
        #expect(server.upgradeAttempts == 10)
        let phases = log.all
        #expect(!phases.contains { if case .ready = $0 { return true }; return false })
        let attempts = phases.compactMap { phase -> Int? in
            if case .connecting(let attempt) = phase { return attempt }
            return nil
        }
        #expect(attempts == Array(0..<10))
        await connection.stop()
    }

    @Test func tenFailedDialsStopUntilManualStart() async throws {
        let server = try await LoopbackGatewayServer.start(refuseUpgradeWith: 503)
        defer { server.stop() }
        let endpoint = ServerEndpoint(baseURL: URL(string: "http://127.0.0.1:\(server.port)")!)
        let connection = HermesConnection(
            endpoint: endpoint,
            authenticator: HermesAuthenticator(endpoint: endpoint, credentials: nil),
            supervisorCheckpoint: nil, backoffDelay: 60)
        let updates = await connection.updates()
        let collector = Task {
            for await update in updates {
                guard case .phase(let phase) = update else { continue }
                if case .disconnected = phase { await connection.pokeReconnect() }
                if case .connecting(let attempt) = phase, attempt >= 10 { return }
                if case .unreachable = phase { return }
            }
        }
        await connection.start()
        #expect(
            await eventually {
                let phase = await connection.phase
                if case .unreachable = phase { return true }
                return server.upgradeAttempts > 10
            })
        collector.cancel()
        await collector.value
        let terminal = await connection.phase
        if case .unreachable(let reason) = terminal {
            #expect(reason.contains("Server unreachable after 10 failed connection attempts."))
        } else {
            Issue.record("Expected unreachable, got \(terminal)")
        }
        #expect(server.upgradeAttempts == 10)
        await connection.pokeReconnect()
        #expect(await connection.phase == terminal)
        await connection.start()
        #expect(await eventually { server.upgradeAttempts >= 11 })
        await connection.stop()
    }
}

private actor BudgetCheckpoints {
    var finishes = 0
    func visit(_ checkpoint: HermesConnection.SupervisorCheckpoint) {
        if checkpoint == .finished { finishes += 1 }
    }
}
