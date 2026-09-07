import Foundation
import Testing

@testable import HermesKit

/// The close mapping the reconnect supervisor branches on. A socket-level
/// 4401 has to be distinguishable from an ordinary drop, or a dead token is
/// retried with backoff forever instead of prompting for a fresh credential —
/// and a 4403 has to be distinguishable from *both*, or an access refusal is
/// either retried forever or told as an expired session (issue #60).
///
/// These pin the table; `GatewayRefusalTests` proves the inputs are what
/// Apple's transport actually reports.
@Suite("Gateway close outcomes")
struct GatewayCloseTests {
    private struct Dropped: LocalizedError {
        var errorDescription: String? { "The network connection was lost." }
    }

    @Test func unauthorizedCloseIsTerminal() {
        let outcome = GatewayClient.closeOutcome(
            closeCode: .init(rawValue: 4401)!, upgradeStatus: 101, error: Dropped())
        #expect(outcome.cause == .unauthorized)
        #expect(outcome.reason.contains("4401"))
    }

    @Test func forbiddenCloseIsTerminalButNotUnauthorized() {
        let outcome = GatewayClient.closeOutcome(
            closeCode: .init(rawValue: 4403)!, upgradeStatus: 101, error: Dropped())
        #expect(outcome.cause == .forbidden)
        #expect(outcome.reason.contains("4403"))
        #expect(!outcome.reason.contains("4401"))
    }

    @Test func rejectedUpgradeIsClassifiedByItsStatus() {
        // A refused upgrade has no close code at all, so the status carries
        // the whole signal.
        let unauthorized = GatewayClient.closeOutcome(
            closeCode: .invalid, upgradeStatus: 401, error: Dropped())
        #expect(unauthorized.cause == .unauthorized)
        #expect(unauthorized.reason.contains("4401"))

        let forbidden = GatewayClient.closeOutcome(
            closeCode: .invalid, upgradeStatus: 403, error: Dropped())
        #expect(forbidden.cause == .forbidden)
        #expect(forbidden.reason.contains("4403"))
    }

    @Test func otherUpgradeStatusesStayRetryable() {
        // 502/503 from a proxy in front of the gateway is a transport-level
        // failure, not a refusal of this client.
        for status in [500, 502, 503] {
            let outcome = GatewayClient.closeOutcome(
                closeCode: .invalid, upgradeStatus: status, error: Dropped())
            #expect(outcome.cause == .other)
            #expect(outcome.reason == "The network connection was lost.")
        }
    }

    @Test func transportErrorReportsTheUnderlyingFailure() {
        // No close frame and no upgrade response: URLSession reports
        // `.invalid` and the error carries the real reason (unreachable,
        // reset, TLS).
        let outcome = GatewayClient.closeOutcome(
            closeCode: .invalid, upgradeStatus: nil, error: Dropped())
        #expect(outcome.cause == .other)
        #expect(outcome.reason == "The network connection was lost.")
    }

    @Test func ordinaryCloseCodesStayRetryable() {
        let codes: [URLSessionWebSocketTask.CloseCode] = [
            .normalClosure, .goingAway, .internalServerError,
        ]
        for code in codes {
            let outcome = GatewayClient.closeOutcome(
                closeCode: code, upgradeStatus: 101, error: Dropped())
            #expect(outcome.cause == .other)
            #expect(outcome.reason.contains("\(code.rawValue)"))
        }
    }
}
