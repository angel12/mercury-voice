import Foundation
import Security

/// A Keychain write that the Security framework refused.
public enum KeychainError: Error, Equatable, LocalizedError {
    /// `SecItemUpdate`/`SecItemAdd` failed with this status.
    case writeFailed(OSStatus)
    /// `SecItemDelete` failed with this status.
    case deleteFailed(OSStatus)
    /// Credentials couldn't be turned into JSON to store.
    case encodingFailed

    public var errorDescription: String? {
        switch self {
        case .writeFailed(let status):
            return "Couldn't save credentials to the keychain (\(Self.message(status)))."
        case .deleteFailed(let status):
            return "Couldn't remove credentials from the keychain (\(Self.message(status)))."
        case .encodingFailed:
            return "Couldn't encode credentials for the keychain."
        }
    }

    private static func message(_ status: OSStatus) -> String {
        SecCopyErrorMessageString(status, nil) as String? ?? "OSStatus \(status)"
    }
}

/// The SecItem write functions, injectable so tests never hit the real
/// Keychain. Use `.live` everywhere outside tests.
public struct KeychainCalls: Sendable {
    public var update: @Sendable (CFDictionary, CFDictionary) -> OSStatus
    public var add: @Sendable (CFDictionary) -> OSStatus
    public var delete: @Sendable (CFDictionary) -> OSStatus

    public init(
        update: @escaping @Sendable (CFDictionary, CFDictionary) -> OSStatus,
        add: @escaping @Sendable (CFDictionary) -> OSStatus,
        delete: @escaping @Sendable (CFDictionary) -> OSStatus
    ) {
        self.update = update
        self.add = add
        self.delete = delete
    }

    /// The real Security framework functions.
    public static let live = KeychainCalls(
        update: { SecItemUpdate($0, $1) },
        add: { SecItemAdd($0, nil) },
        delete: { SecItemDelete($0) })
}

/// Per-server credential storage backed by the Keychain.
///
/// Items are keyed by `ServerEndpoint.key` (scheme://host:port) and hold a
/// JSON-encoded `ServerCredentials` (session token or password-session
/// tokens). Items written before credentials existed are raw token strings —
/// read back as `.sessionToken`. Non-secret preferences (server list, last
/// server) belong in UserDefaults, not here.
///
/// Writes throw `KeychainError` carrying the underlying `OSStatus` rather
/// than failing silently, so callers can surface the failure. Stored items
/// are device-only (`kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`):
/// they never sync to iCloud and never leave the device in a backup.
public struct KeychainTokenStore: Sendable {
    private let service: String
    private let calls: KeychainCalls

    public init(
        service: String = "com.mercury.voice.tokens",
        calls: KeychainCalls = .live
    ) {
        self.service = service
        self.calls = calls
    }

    // MARK: Credentials (either mode)

    public func credentials(for endpoint: ServerEndpoint) -> ServerCredentials? {
        guard let raw = token(for: endpoint) else { return nil }
        if let decoded = try? JSONDecoder().decode(
            ServerCredentials.self, from: Data(raw.utf8))
        {
            return decoded
        }
        return .sessionToken(raw)  // legacy pre-credentials item
    }

    /// Stores `credentials` for `endpoint`, or deletes the item when `nil`.
    ///
    /// - Throws: `KeychainError.encodingFailed` if the credentials can't be
    ///   encoded (the existing item is left untouched), or
    ///   `.writeFailed`/`.deleteFailed` from the Keychain.
    public func setCredentials(
        _ credentials: ServerCredentials?, for endpoint: ServerEndpoint
    ) throws {
        guard let credentials else {
            try deleteToken(for: endpoint)
            return
        }
        guard let data = try? JSONEncoder().encode(credentials),
            let json = String(data: data, encoding: .utf8)
        else {
            throw KeychainError.encodingFailed
        }
        try setToken(json, for: endpoint)
    }

    public func token(for endpoint: ServerEndpoint) -> String? {
        var query = baseQuery(account: endpoint.key)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Stores `token` for `endpoint`, or deletes the item when nil or empty.
    ///
    /// - Throws: `KeychainError.writeFailed` with the failing `OSStatus`, or
    ///   `.deleteFailed` when clearing.
    public func setToken(_ token: String?, for endpoint: ServerEndpoint) throws {
        guard let token, !token.isEmpty else {
            try deleteToken(for: endpoint)
            return
        }
        let data = Data(token.utf8)
        let query = baseQuery(account: endpoint.key)
        // The accessibility attribute goes on the update too, not just the add:
        // items written by earlier versions are AfterFirstUnlock, and updating
        // only kSecValueData would leave them that way forever.
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]

        let status = calls.update(query as CFDictionary, attributes as CFDictionary)
        switch status {
        case errSecSuccess:
            return
        case errSecItemNotFound:
            var add = query
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] =
                kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            let addStatus = calls.add(add as CFDictionary)
            guard addStatus == errSecSuccess else {
                throw KeychainError.writeFailed(addStatus)
            }
        default:
            throw KeychainError.writeFailed(status)
        }
    }

    /// Removes any stored item for `endpoint`. A missing item is success.
    ///
    /// - Throws: `KeychainError.deleteFailed` with the failing `OSStatus`.
    public func deleteToken(for endpoint: ServerEndpoint) throws {
        let status = calls.delete(baseQuery(account: endpoint.key) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.deleteFailed(status)
        }
    }

    private func baseQuery(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }
}
