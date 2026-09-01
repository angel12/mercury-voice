import Foundation
import Testing

@testable import HermesKit

/// prompt.submit refusals carry a machine-readable `error.data.reason`
/// (hermes_cli/active_sessions.py: "the reason is the contract; the message
/// is for people"). The app must branch on the reason, never the prose —
/// and the voice notice must be speakable: no pids, paths, or timestamps.
@Suite("RPC refusal reasons")
struct RPCErrorReasonTests {
    /// The raw server prose these errors replace — asserting it stays OUT
    /// of the friendly copy.
    private static let serverProse =
        "Session abc123 already has a live owner (gui, pid 4821, running 3m)."

    private func refusal(_ reason: String) -> HermesError {
        .rpcError(
            code: HermesError.RPCCode.sessionSlotRefused,
            message: Self.serverProse,
            data: .object(["reason": .string(reason)]))
    }

    @Test func reasonIsExtractedFromData() {
        let error = refusal(HermesError.RefusalReason.sessionNotOwned)
        #expect(error.rpcReason == "SESSION_NOT_OWNED")
    }

    @Test func reasonIsNilWithoutData() {
        let error = HermesError.rpcError(code: 4090, message: "busy", data: nil)
        #expect(error.rpcReason == nil)
    }

    @Test func reasonIsNilForOtherCases() {
        #expect(HermesError.notConnected.rpcReason == nil)
    }

    @Test func sessionNotOwnedSpeaksCloseTheOtherApp() {
        let text = refusal(HermesError.RefusalReason.sessionNotOwned)
            .errorDescription ?? ""
        #expect(text.contains("Another app"))
        #expect(!text.contains("pid"))
        #expect(!text.contains("abc123"))
    }

    @Test func maxConcurrentSpeaksTryAgain() {
        let text = refusal(HermesError.RefusalReason.maxConcurrentSessions)
            .errorDescription ?? ""
        #expect(text.contains("session limit"))
        #expect(!text.contains("pid"))
    }

    @Test func coordinationUnavailableNamesTheRegistry() {
        let text = refusal(HermesError.RefusalReason.coordinationUnavailable)
            .errorDescription ?? ""
        #expect(text.contains("registry"))
        // Server prose for this reason names a filesystem path; the spoken
        // notice must not.
        #expect(!text.contains("/"))
    }

    @Test func storageUnavailableByCodeAlone() {
        // 5072 carries no data.reason — mapped by code.
        let error = HermesError.rpcError(
            code: HermesError.RPCCode.sessionStorageUnavailable,
            message: "session storage unavailable: state.db could not be opened — repair state.db",
            data: nil)
        let text = error.errorDescription ?? ""
        #expect(text.contains("storage"))
        #expect(!text.contains("state.db"))
    }

    @Test func unknownReasonFallsBackToGeneric() {
        let error = refusal("SOME_FUTURE_REASON")
        #expect(error.errorDescription == "Hermes error 4090: \(Self.serverProse)")
    }

    @Test func unknownCodeWithoutReasonStaysGeneric() {
        let error = HermesError.rpcError(code: 4007, message: "session not found", data: .null)
        #expect(error.errorDescription == "Hermes error 4007: session not found")
    }
}
