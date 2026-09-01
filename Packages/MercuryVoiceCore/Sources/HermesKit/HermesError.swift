import Foundation

public enum HermesError: Error, LocalizedError, Sendable {
    case notConnected
    case unauthorized
    case invalidCredentials
    case sessionExpired
    case httpError(status: Int, detail: String?)
    case rpcError(code: Int, message: String, data: JSONValue?)
    case malformedResponse(String)
    case connectionClosed(String?)
    case timeout(String)

    public var errorDescription: String? {
        switch self {
        case .notConnected:
            return "Not connected to the Hermes server."
        case .unauthorized:
            return "The session token was rejected. Paste a fresh dashboard URL — the token changes every time the backend restarts."
        case .invalidCredentials:
            return "Invalid username or password."
        case .sessionExpired:
            return "Your session has expired. Sign in again."
        case .httpError(let status, let detail):
            return "Server error \(status)\(detail.map { ": \($0)" } ?? "")"
        case .rpcError(let code, let message, _):
            // Refusal reasons are the machine contract (the prose is server
            // wording that will change); map the known ones to copy that is
            // safe to speak aloud — no pids, paths, or session ids.
            if let reason = rpcReason {
                switch reason {
                case RefusalReason.sessionNotOwned:
                    return
                        "Another app is running this session. Close it there or wait for it to finish, then try again."
                case RefusalReason.maxConcurrentSessions:
                    return "The server is at its session limit. Try again in a moment."
                case RefusalReason.coordinationUnavailable:
                    return
                        "The server can't verify who owns this session. Its active-session registry needs repair — check the backend."
                default:
                    break
                }
            }
            if code == RPCCode.sessionStorageUnavailable {
                return
                    "The server couldn't save your message — its session storage needs repair."
            }
            return "Hermes error \(code): \(message)"
        case .malformedResponse(let why):
            return "Unexpected response from server: \(why)"
        case .connectionClosed(let reason):
            return "Connection closed\(reason.map { ": \($0)" } ?? "")."
        case .timeout(let what):
            return "Timed out waiting for \(what)."
        }
    }

    /// Gateway error codes with defined meanings (tui_gateway).
    public enum RPCCode {
        public static let sessionIDRequired = 4006
        public static let sessionNotFound = 4007
        public static let sessionBusy = 4009
        public static let methodNotFound = -32601
        /// prompt.submit refused: no active-session slot. Carries
        /// `data.reason` (see RefusalReason) on backends ≥ 2026-08-31.
        public static let sessionSlotRefused = 4090
        /// prompt.submit failed: state.db could not be opened; the message
        /// was NOT saved.
        public static let sessionStorageUnavailable = 5072
    }

    /// Machine-readable `error.data.reason` values attached to 4090 refusals
    /// (hermes_cli/active_sessions.py). Open set — unknown reasons fall back
    /// to the generic description.
    public enum RefusalReason {
        public static let sessionNotOwned = "SESSION_NOT_OWNED"
        public static let maxConcurrentSessions = "MAX_CONCURRENT_SESSIONS"
        public static let coordinationUnavailable = "SESSION_COORDINATION_UNAVAILABLE"
    }

    /// The `data.reason` of an `.rpcError`, when the server attached one.
    public var rpcReason: String? {
        guard case .rpcError(_, _, let data) = self else { return nil }
        return data?["reason"]?.stringValue
    }
}
