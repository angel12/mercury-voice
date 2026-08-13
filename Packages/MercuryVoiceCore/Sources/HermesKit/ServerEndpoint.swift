import Foundation

/// A Hermes backend the app can talk to: normalized base URL + session token.
///
/// Accepts the forms users actually paste:
///   - `localhost:8080`, `192.168.1.5:8080` (default to http),
///     `my-mac.tail1234.ts.net` (DNS names default to https)
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
        // Qualified DNS names default to https:// — iOS ATS blocks plaintext
        // HTTP to them anyway, and they're the case (Tailscale MagicDNS, real
        // domains) where TLS is actually available. IP literals, loopback,
        // `.local`, and single-label LAN names keep the http:// default;
        // that's the home-lab case where HTTPS is rarely an option, and an
        // explicit scheme is always honored (issue #41).
        let withScheme: String
        if trimmed.contains("://") {
            withScheme = trimmed
        } else {
            let probeHost = URLComponents(string: "http://" + trimmed)?.host ?? ""
            withScheme = (defaultsToHTTPS(host: probeHost) ? "https://" : "http://") + trimmed
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

    /// True when a schemeless input's host should default to `https://`:
    /// a qualified DNS name that isn't loopback, `.local`, or an IP literal.
    private static func defaultsToHTTPS(host: String) -> Bool {
        let host = host.lowercased()
        guard !host.isEmpty else { return false }
        if host == "localhost" { return false }
        if host.contains(":") { return false }  // IPv6 literal
        if host.hasSuffix(".local") { return false }
        guard host.contains(".") else { return false }  // single-label LAN name
        let isIPv4 = host.split(separator: ".").allSatisfy {
            !$0.isEmpty && $0.allSatisfy(\.isNumber)
        }
        return !isIPv4
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
