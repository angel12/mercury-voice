import Foundation
import Testing

@testable import HermesKit

/// The close-code mapping the reconnect supervisor branches on. A socket-level
/// 4401 has to be distinguishable from an ordinary drop, or a dead token is
/// retried with backoff forever instead of prompting for a fresh credential.
@Suite("Gateway close outcomes")
struct GatewayCloseTests {
    private struct Dropped: LocalizedError {
        var errorDescription: String? { "The network connection was lost." }
    }

    @Test func unauthorizedCloseIsTerminal() {
        let outcome = GatewayClient.closeOutcome(
            closeCode: .init(rawValue: 4401)!, error: Dropped())
        #expect(outcome.cause == .unauthorized)
        #expect(outcome.reason.contains("4401"))
    }

    @Test func transportErrorReportsTheUnderlyingFailure() {
        // No close frame: URLSession reports `.invalid` and the error carries
        // the real reason (unreachable, reset, TLS).
        let outcome = GatewayClient.closeOutcome(closeCode: .invalid, error: Dropped())
        #expect(outcome.cause == .other)
        #expect(outcome.reason == "The network connection was lost.")
    }

    @Test func ordinaryCloseCodesStayRetryable() {
        let codes: [URLSessionWebSocketTask.CloseCode] = [
            .normalClosure, .goingAway, .internalServerError,
        ]
        for code in codes {
            let outcome = GatewayClient.closeOutcome(closeCode: code, error: Dropped())
            #expect(outcome.cause == .other)
            #expect(outcome.reason.contains("\(code.rawValue)"))
        }
    }
}
