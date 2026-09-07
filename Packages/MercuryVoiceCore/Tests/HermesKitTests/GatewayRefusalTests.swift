import Foundation
import Testing

@testable import HermesKit

/// Issue #60: unauthorized, forbidden and transport failures are three
/// different outcomes, and the socket layer is the only place that can tell
/// them apart. Everything here runs over a real `URLSessionWebSocketTask`
/// against a loopback gateway, because the signals are Apple's, not ours:
///
/// | server behavior | `task.closeCode` | `task.response` | error |
/// |---|---|---|---|
/// | upgrade answered 401 | `.invalid` (0) | 401 | `NSURLErrorDomain -1011` |
/// | upgrade answered 403 | `.invalid` (0) | 403 | `NSURLErrorDomain -1011` |
/// | close frame 4401 | 4401 | 101 | `NSPOSIXErrorDomain 57` |
/// | close frame 4403 | 4403 | 101 | `NSPOSIXErrorDomain 57` |
/// | connection dropped mid-handshake | `.invalid` (0) | nil | `NSURLErrorDomain -1005` |
///
/// A refused upgrade therefore has NO close code — classifying it needs the
/// upgrade response's status — and a dropped handshake has neither, so it
/// must stay retryable.
@Suite("Gateway refusal classification")
struct GatewayRefusalTests {
    private static func client(port: UInt16) -> GatewayClient {
        GatewayClient(
            endpoint: ServerEndpoint(baseURL: URL(string: "http://127.0.0.1:\(port)")!),
            // No credentials: the WS auth query is answered locally, so only
            // the socket dial touches the network.
            token: nil)
    }

    private static func isClosed(_ client: GatewayClient) async -> Bool {
        if case .closed = await client.state { return true }
        return false
    }

    // MARK: Apple transport facts

    @Test func rejectedUpgradeCarriesTheStatusAndNoCloseCode() async throws {
        // The premise every mapping below rests on, asserted directly against
        // URLSession so the classification is not built on an assumption.
        for status in [401, 403] {
            let server = try await LoopbackGatewayServer.start(refuseUpgradeWith: status)
            defer { server.stop() }
            let session = URLSession(configuration: .ephemeral)
            defer { session.invalidateAndCancel() }
            let task = session.webSocketTask(
                with: URL(string: "ws://127.0.0.1:\(server.port)/api/ws")!)
            task.resume()

            await #expect(throws: (any Error).self) { try await task.receive() }
            #expect(task.closeCode == .invalid)
            #expect((task.response as? HTTPURLResponse)?.statusCode == status)
        }
    }

    @Test func applicationCloseCodeReachesTheClient() async throws {
        for code in [UInt16(4401), UInt16(4403)] {
            let server = try await LoopbackGatewayServer.start()
            defer { server.stop() }
            let session = URLSession(configuration: .ephemeral)
            defer { session.invalidateAndCancel() }
            let task = session.webSocketTask(
                with: URL(string: "ws://127.0.0.1:\(server.port)/api/ws")!)
            task.resume()
            _ = try await task.receive()  // gateway.ready

            server.close(code: code)
            await #expect(throws: (any Error).self) { try await task.receive() }
            #expect(task.closeCode.rawValue == Int(code))
        }
    }

    // MARK: GatewayClient classification

    @Test func upgradeRejectedWith401IsUnauthorized() async throws {
        let server = try await LoopbackGatewayServer.start(refuseUpgradeWith: 401)
        defer { server.stop() }
        let client = Self.client(port: server.port)

        await #expect(throws: (any Error).self) { try await client.connect(timeout: 5) }
        #expect(await client.closeCause == .unauthorized)
        if case .closed(let reason) = await client.state {
            #expect(reason?.contains("(4401)") == true)
        } else {
            Issue.record("expected the client to be closed")
        }
    }

    @Test func upgradeRejectedWith403IsForbiddenNotUnauthorized() async throws {
        // 403 on the upgrade is an access refusal (Host/Origin guard, peer
        // check, permission gate) — never a dead credential. Calling it
        // unauthorized sends the app off asking for a fresh token that would
        // be refused exactly the same way.
        let server = try await LoopbackGatewayServer.start(refuseUpgradeWith: 403)
        defer { server.stop() }
        let client = Self.client(port: server.port)

        await #expect(throws: (any Error).self) { try await client.connect(timeout: 5) }
        #expect(await client.closeCause == .forbidden)
        if case .closed(let reason) = await client.state {
            #expect(reason?.contains("(4403)") == true)
            #expect(reason?.contains("4401") != true)
        } else {
            Issue.record("expected the client to be closed")
        }
    }

    @Test func close4401IsUnauthorized() async throws {
        let server = try await LoopbackGatewayServer.start()
        defer { server.stop() }
        let client = Self.client(port: server.port)
        try await client.connect(timeout: 5)

        server.close(code: 4401)
        #expect(await eventually { await client.closeCause == .unauthorized })
    }

    @Test func close4403IsForbiddenNotUnauthorized() async throws {
        let server = try await LoopbackGatewayServer.start()
        defer { server.stop() }
        let client = Self.client(port: server.port)
        try await client.connect(timeout: 5)

        // The event stream finishing is the disconnect signal; the cause is
        // what the supervisor branches on.
        var events = await client.events().makeAsyncIterator()
        server.close(code: 4403)
        while await events.next() != nil {}

        #expect(await client.closeCause == .forbidden)
        if case .closed(let reason) = await client.state {
            #expect(reason?.contains("(4403)") == true)
        } else {
            Issue.record("expected the client to be closed")
        }
    }

    @Test func droppedHandshakeStaysTransient() async throws {
        // No HTTP status and no close code ever reach the client, so nothing
        // has been refused: this is the retryable case and must not be
        // classified as an auth or access failure.
        let server = try await LoopbackGatewayServer.start(dropsUpgrade: true)
        defer { server.stop() }
        let client = Self.client(port: server.port)

        await #expect(throws: (any Error).self) { try await client.connect(timeout: 5) }
        #expect(await client.closeCause == .other)
    }

    @Test func normalClosureStaysTransient() async throws {
        let server = try await LoopbackGatewayServer.start()
        defer { server.stop() }
        let client = Self.client(port: server.port)
        try await client.connect(timeout: 5)

        server.close(code: 1000)
        #expect(await eventually { await Self.isClosed(client) })
        #expect(await client.closeCause == .other)
    }
}
