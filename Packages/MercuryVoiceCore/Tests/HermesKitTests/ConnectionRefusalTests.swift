import Foundation
import Testing

@testable import HermesKit

/// Issue #60, supervisor half: what the reconnect loop does with each kind of
/// refusal. All three outcomes are distinguishable only if the socket layer
/// separated them, so these run the real `HermesConnection` against a real
/// loopback gateway and count the dials the server actually received.
@Suite("Connection refusal outcomes")
struct ConnectionRefusalTests {
    private static func connection(port: UInt16) -> HermesConnection {
        HermesConnection(
            endpoint: ServerEndpoint(baseURL: URL(string: "http://127.0.0.1:\(port)")!),
            token: nil)
    }

    /// Collect phases off the real update stream until `stop` matches, or the
    /// deadline passes. Returns everything seen, so a test can assert both the
    /// terminal phase and what preceded it.
    private static func phases(
        of connection: HermesConnection,
        until stop: @escaping @Sendable (HermesConnection.Phase) -> Bool,
        timeout: Double = 6
    ) async -> [HermesConnection.Phase] {
        let collected = PhaseLog()
        let updates = await connection.updates()
        await connection.start()
        let collector = Task {
            for await update in updates {
                guard case .phase(let phase) = update else { continue }
                collected.append(phase)
                if stop(phase) { return }
            }
        }
        _ = await eventually(timeout: timeout) { collected.matched(stop) }
        collector.cancel()
        return collected.all
    }

    // Named so the assertions read as statements about the phase rather than
    // as inline pattern-matching closures.
    private static let isRefused: @Sendable (HermesConnection.Phase) -> Bool = { phase in
        if case .refused = phase { return true }
        return false
    }
    private static let isReady: @Sendable (HermesConnection.Phase) -> Bool = { phase in
        if case .ready = phase { return true }
        return false
    }
    private static let isDisconnected: @Sendable (HermesConnection.Phase) -> Bool = { phase in
        if case .disconnected = phase { return true }
        return false
    }

    // MARK: Terminal refusals

    @Test func forbiddenUpgradeStopsInsteadOfRedialingForever() async throws {
        // A 403 upgrade is an access refusal that every redial will hit
        // identically. Retrying it is a storm against a server that already
        // said no.
        let server = try await LoopbackGatewayServer.start(refuseUpgradeWith: 403)
        defer { server.stop() }
        let connection = Self.connection(port: server.port)
        defer { Task { await connection.stop() } }

        let seen = await Self.phases(of: connection, until: Self.isRefused)

        #expect(seen.contains(where: Self.isRefused))
        // Not the credential story: nothing about these credentials is wrong.
        #expect(!seen.contains(.authExpired))
        // And the refusal is terminal — one dial, no backoff loop.
        try await Task.sleep(for: .seconds(1))
        #expect(server.upgradeAttempts == 1)
    }

    @Test func unauthorizedUpgradeStopsAsAuthExpired() async throws {
        let server = try await LoopbackGatewayServer.start(refuseUpgradeWith: 401)
        defer { server.stop() }
        let connection = Self.connection(port: server.port)
        defer { Task { await connection.stop() } }

        let seen = await Self.phases(of: connection) { $0 == .authExpired }

        #expect(seen.contains(.authExpired))
        try await Task.sleep(for: .seconds(1))
        #expect(server.upgradeAttempts == 1)
    }

    @Test func midFlight4403StopsWithoutTheCredentialStory() async throws {
        let server = try await LoopbackGatewayServer.start()
        defer { server.stop() }
        let connection = Self.connection(port: server.port)
        defer { Task { await connection.stop() } }

        let ready = Task { await Self.phases(of: connection, until: Self.isReady) }
        _ = await ready.value
        #expect(await eventually { server.upgradeAttempts == 1 })

        let terminal = Task { await Self.phases(of: connection, until: Self.isRefused) }
        server.close(code: 4403)
        let seen = await terminal.value

        #expect(seen.contains(where: Self.isRefused))
        #expect(!seen.contains(.authExpired))
        try await Task.sleep(for: .seconds(1))
        #expect(server.upgradeAttempts == 1)  // never redialed
    }

    // MARK: Genuine transport failures still retry

    @Test func droppedHandshakeKeepsRetrying() async throws {
        // Nothing was refused — no status, no close code — so the supervisor
        // must keep trying instead of stopping on a guess.
        let server = try await LoopbackGatewayServer.start(dropsUpgrade: true)
        defer { server.stop() }
        let connection = Self.connection(port: server.port)
        defer { Task { await connection.stop() } }

        let seen = await Self.phases(of: connection, until: Self.isDisconnected)

        #expect(seen.contains(where: Self.isDisconnected))
        #expect(!seen.contains(.authExpired))
        #expect(!seen.contains(where: Self.isRefused))
        #expect(await eventually { server.upgradeAttempts >= 2 })
    }
}

/// Thread-safe phase log: the collector task and the assertions run on
/// different executors.
final class PhaseLog: @unchecked Sendable {
    private let lock = NSLock()
    private var phases: [HermesConnection.Phase] = []

    var all: [HermesConnection.Phase] { lock.withLock { phases } }

    func append(_ phase: HermesConnection.Phase) {
        lock.withLock { phases.append(phase) }
    }

    func matched(_ predicate: (HermesConnection.Phase) -> Bool) -> Bool {
        lock.withLock { phases.contains(where: predicate) }
    }
}
