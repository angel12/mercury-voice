import Foundation

/// How the app authenticates to a Hermes backend. Exactly one of two modes,
/// mirroring the server's two auth schemes (one active per bind):
///
/// * `.sessionToken` — loopback / `--insecure` mode: the ephemeral
///   `_SESSION_TOKEN` from the dashboard URL, sent as
///   `X-Hermes-Session-Token` on REST and `?token=` on WebSockets.
/// * `.password` — gated mode with the `basic` (username/password)
///   dashboard-auth provider: provider-minted bearer tokens, sent as
///   `Authorization: Bearer` on REST and exchanged for single-use
///   `?ticket=` values on WebSockets.
public enum ServerCredentials: Sendable, Equatable, Codable {
    case sessionToken(String)
    case password(PasswordSession)

    /// Prefer the live credentials, which may have rotated during validation.
    public static func credentialsToPersist(
        original: ServerCredentials?,
        authenticatorCurrent: ServerCredentials?
    ) -> ServerCredentials? {
        authenticatorCurrent ?? original
    }
}

/// Tokens minted by a password (basic-auth) login. The access token is
/// short-lived (~12h default) and rotated via `/auth/native/refresh` using
/// the 30-day refresh token; both live in the keychain.
public struct PasswordSession: Sendable, Equatable, Codable {
    /// Dashboard-auth provider name (`"basic"` for username/password).
    public var provider: String
    /// Remembered so re-login can prefill; never stored with the password.
    public var username: String
    public var accessToken: String
    public var refreshToken: String
    /// Unix seconds when the access token lapses (0 = unknown).
    public var expiresAt: Int

    public init(
        provider: String,
        username: String,
        accessToken: String,
        refreshToken: String,
        expiresAt: Int = 0
    ) {
        self.provider = provider
        self.username = username
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresAt = expiresAt
    }
}

/// A sign-in option advertised by `GET /api/auth/providers` (public route,
/// only present on gated binds).
public struct AuthProviderInfo: Sendable, Equatable, Identifiable {
    public var name: String
    public var displayName: String
    public var supportsPassword: Bool

    public var id: String { name }

    public init?(json: JSONValue) {
        guard let name = json["name"]?.stringValue, !name.isEmpty else { return nil }
        self.name = name
        self.displayName = json["display_name"]?.stringValue ?? name
        self.supportsPassword = json["supports_password"]?.truthy ?? false
    }
}
