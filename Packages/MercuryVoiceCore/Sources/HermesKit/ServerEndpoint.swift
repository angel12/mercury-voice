import Foundation

/// A Hermes backend the app can talk to: normalized base URL + session token.
///
/// Accepts the forms users actually paste:
///   - `localhost:8080`, `192.168.1.5:8080`, `my-mac.tail1234.ts.net`
///   - `http://127.0.0.1:8080` / `https://hermes.example.com`
///   - a full dashboard URL `http://127.0.0.1:8080/?token=abc123` (hermes
///     prints/opens this on startup) — the token is lifted out automatically.
public struct ServerEndpoint: Sendable, Equatable, Codable, Identifiable {
    /// Scheme + host + port only, no path, no trailing slash.
    public var baseURL: URL

    public init(baseURL: URL) {
        self.baseURL = baseURL
    }

    public var id: String { key }

    /// Stable identity for keychain/preferences storage.
    public var key: String {
        let scheme = baseURL.scheme ?? "http"
        let host = baseURL.host ?? ""
        let port = baseURL.port.map { ":\($0)" } ?? ""
        return "\(scheme)://\(host.lowercased())\(port)"
    }

    public var displayName: String {
        let host = baseURL.host ?? "?"
        if let port = baseURL.port { return "\(host):\(port)" }
        return host
    }

    public var isSecure: Bool { baseURL.scheme == "https" }

    public var isLoopbackHost: Bool {
        let host = (baseURL.host ?? "").lowercased()
        return host == "localhost" || host == "127.0.0.1" || host == "::1"
    }

    // MARK: Parsing

    public struct ParseResult: Sendable, Equatable {
        public var endpoint: ServerEndpoint
        /// Token found in a pasted dashboard URL's `?token=` query, if any.
        public var embeddedToken: String?
    }

    public enum ParseError: Error, LocalizedError, Equatable {
        case empty
        case invalid(String)

        public var errorDescription: String? {
            switch self {
            case .empty: return "Enter a server address."
            case .invalid(let input): return "\"\(input)\" is not a valid server address."
            }
        }
    }

    /// Parse user input into an endpoint, extracting an embedded `?token=`.
    public static func parse(_ input: String) throws -> ParseResult {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw ParseError.empty }

        // Prepend a scheme when missing so URLComponents can parse host:port.
        let withScheme: String
        if trimmed.contains("://") {
            withScheme = trimmed
        } else {
            withScheme = "http://" + trimmed
        }

        guard let components = URLComponents(string: withScheme),
            let host = components.host, !host.isEmpty,
            let scheme = components.scheme?.lowercased(),
            scheme == "http" || scheme == "https"
        else {
            throw ParseError.invalid(trimmed)
        }

        let token = components.queryItems?.first(where: { $0.name == "token" })?.value
            .flatMap { $0.isEmpty ? nil : $0 }

        var base = URLComponents()
        base.scheme = scheme
        base.host = host
        base.port = components.port
        guard let baseURL = base.url else { throw ParseError.invalid(trimmed) }

        return ParseResult(
            endpoint: ServerEndpoint(baseURL: baseURL),
            embeddedToken: token)
    }

    // MARK: URL builders

    public func restURL(_ path: String, query: [URLQueryItem] = []) -> URL {
        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)!
        components.path = path
        components.queryItems = query.isEmpty ? nil : query
        return components.url!
    }

    /// `ws(s)://host:port/<path>?<query>` — for `/api/ws` and
    /// `/api/audio/speak-stream`.
    public func webSocketURL(_ path: String, query: [URLQueryItem]) -> URL {
        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)!
        components.scheme = isSecure ? "wss" : "ws"
        components.path = path
        components.queryItems = query.isEmpty ? nil : query
        return components.url!
    }
}
