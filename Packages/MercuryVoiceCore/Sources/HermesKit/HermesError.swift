import Foundation

public enum HermesError: Error, LocalizedError, Sendable {
    case notConnected
    case unauthorized
    case invalidCredentials
    case sessionExpired
    case httpError(status: Int, detail: String?)
    case rpcError(code: Int, message: String)
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
        case .rpcError(let code, let message):
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
    }
}
