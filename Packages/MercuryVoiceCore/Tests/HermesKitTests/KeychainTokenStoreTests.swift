import Foundation
import Security
import Testing

@testable import HermesKit

/// Records every dictionary handed to the injected SecItem closures and
/// returns scripted statuses, so no test ever touches the real Keychain.
private final class Recorder: @unchecked Sendable {
    private let lock = NSLock()

    private var _updateQueries: [[String: Any]] = []
    private var _updateAttributes: [[String: Any]] = []
    private var _addItems: [[String: Any]] = []
    private var _deleteQueries: [[String: Any]] = []
    private var _updateStatuses: [OSStatus] = [errSecSuccess]
    private var _addStatus: OSStatus = errSecSuccess
    private var _deleteStatus: OSStatus = errSecSuccess

    /// `updateStatuses` is consumed one per `update` call; the last entry
    /// repeats for any further calls.
    init(
        updateStatuses: [OSStatus] = [errSecSuccess],
        addStatus: OSStatus = errSecSuccess,
        deleteStatus: OSStatus = errSecSuccess
    ) {
        _updateStatuses = updateStatuses.isEmpty ? [errSecSuccess] : updateStatuses
        _addStatus = addStatus
        _deleteStatus = deleteStatus
    }

    convenience init(
        updateStatus: OSStatus,
        addStatus: OSStatus = errSecSuccess,
        deleteStatus: OSStatus = errSecSuccess
    ) {
        self.init(
            updateStatuses: [updateStatus], addStatus: addStatus,
            deleteStatus: deleteStatus)
    }

    var updateQueries: [[String: Any]] { lock.withLock { _updateQueries } }
    var updateAttributes: [[String: Any]] { lock.withLock { _updateAttributes } }
    var addItems: [[String: Any]] { lock.withLock { _addItems } }
    var deleteQueries: [[String: Any]] { lock.withLock { _deleteQueries } }

    var calls: KeychainCalls {
        KeychainCalls(
            update: { [self] query, attributes in
                lock.withLock {
                    _updateQueries.append(Self.dict(query))
                    _updateAttributes.append(Self.dict(attributes))
                    let index = min(_updateQueries.count - 1, _updateStatuses.count - 1)
                    return _updateStatuses[index]
                }
            },
            add: { [self] item in
                lock.withLock {
                    _addItems.append(Self.dict(item))
                    return _addStatus
                }
            },
            delete: { [self] query in
                lock.withLock {
                    _deleteQueries.append(Self.dict(query))
                    return _deleteStatus
                }
            })
    }

    private static func dict(_ cf: CFDictionary) -> [String: Any] {
        (cf as? [String: Any]) ?? [:]
    }
}

@Suite("KeychainTokenStore")
struct KeychainTokenStoreTests {
    private static let service = "com.mercury.voice.tests"

    private func endpoint() throws -> ServerEndpoint {
        try ServerEndpoint.parse("http://127.0.0.1:8080").endpoint
    }

    private func store(_ recorder: Recorder) -> KeychainTokenStore {
        KeychainTokenStore(service: Self.service, calls: recorder.calls)
    }

    // MARK: setToken

    @Test func updateSuccessWritesTokenBytesAndSkipsAdd() throws {
        let recorder = Recorder(updateStatus: errSecSuccess)
        let endpoint = try endpoint()
        try store(recorder).setToken("tok-123", for: endpoint)

        #expect(recorder.updateQueries.count == 1)
        #expect(recorder.updateQueries.first?[kSecAttrAccount as String] as? String == endpoint.key)
        #expect(recorder.addItems.isEmpty)
        let attributes = try #require(recorder.updateAttributes.first)
        #expect(attributes[kSecValueData as String] as? Data == Data("tok-123".utf8))
        // Re-marks pre-existing items, which shipped as AfterFirstUnlock.
        #expect(
            attributes[kSecAttrAccessible as String] as? String
                == kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String)
    }

    @Test func addFallbackUsesDeviceOnlyAccessibilityAndNoSync() throws {
        let recorder = Recorder(updateStatus: errSecItemNotFound, addStatus: errSecSuccess)
        let endpoint = try endpoint()
        try store(recorder).setToken("tok-123", for: endpoint)

        let item = try #require(recorder.addItems.first)
        #expect(recorder.addItems.count == 1)
        #expect(
            item[kSecAttrAccessible as String] as? String
                == kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String)
        #expect(
            item[kSecClass as String] as? String == kSecClassGenericPassword as String)
        #expect(item[kSecAttrService as String] as? String == Self.service)
        #expect(item[kSecAttrAccount as String] as? String == endpoint.key)
        #expect(item[kSecValueData as String] as? Data == Data("tok-123".utf8))
        #expect(item[kSecAttrSynchronizable as String] == nil)
    }

    @Test func updateRetriesWithoutAccessibilityWhenPlatformRejectsIt() throws {
        let recorder = Recorder(updateStatuses: [errSecParam, errSecSuccess])
        try store(recorder).setToken("tok-123", for: try endpoint())

        #expect(recorder.updateQueries.count == 2)
        #expect(recorder.addItems.isEmpty)
        let retry = try #require(recorder.updateAttributes.last)
        #expect(retry[kSecAttrAccessible as String] == nil)
        #expect(retry[kSecValueData as String] as? Data == Data("tok-123".utf8))
    }

    @Test func updateRetryFailureThrowsWriteFailed() throws {
        let recorder = Recorder(updateStatuses: [errSecParam, errSecAuthFailed])
        let store = store(recorder)
        let endpoint = try endpoint()

        #expect(throws: KeychainError.writeFailed(errSecAuthFailed)) {
            try store.setToken("tok-123", for: endpoint)
        }
        #expect(recorder.updateQueries.count == 2)
        #expect(recorder.addItems.isEmpty)
    }

    @Test func updateFailureThrowsWriteFailedAndSkipsAdd() throws {
        let recorder = Recorder(updateStatus: errSecAuthFailed)
        let store = store(recorder)
        let endpoint = try endpoint()

        #expect(throws: KeychainError.writeFailed(errSecAuthFailed)) {
            try store.setToken("tok-123", for: endpoint)
        }
        #expect(recorder.addItems.isEmpty)
    }

    @Test func addFailureThrowsWriteFailed() throws {
        let recorder = Recorder(
            updateStatus: errSecItemNotFound, addStatus: errSecDuplicateItem)
        let store = store(recorder)
        let endpoint = try endpoint()

        #expect(throws: KeychainError.writeFailed(errSecDuplicateItem)) {
            try store.setToken("tok-123", for: endpoint)
        }
    }

    @Test(arguments: [nil, ""] as [String?])
    func nilOrEmptyTokenDeletes(token: String?) throws {
        let recorder = Recorder()
        let endpoint = try endpoint()
        try store(recorder).setToken(token, for: endpoint)

        #expect(recorder.deleteQueries.count == 1)
        #expect(recorder.deleteQueries.first?[kSecAttrAccount as String] as? String == endpoint.key)
        #expect(recorder.updateQueries.isEmpty)
        #expect(recorder.addItems.isEmpty)
    }

    // MARK: deleteToken

    @Test func deleteTreatsItemNotFoundAsSuccess() throws {
        let recorder = Recorder(deleteStatus: errSecItemNotFound)
        let endpoint = try endpoint()
        try store(recorder).deleteToken(for: endpoint)
        #expect(recorder.deleteQueries.count == 1)
        #expect(recorder.deleteQueries.first?[kSecAttrAccount as String] as? String == endpoint.key)
    }

    @Test func deleteFailureThrowsDeleteFailed() throws {
        let recorder = Recorder(deleteStatus: errSecAuthFailed)
        let store = store(recorder)
        let endpoint = try endpoint()

        #expect(throws: KeychainError.deleteFailed(errSecAuthFailed)) {
            try store.deleteToken(for: endpoint)
        }
        #expect(recorder.deleteQueries.first?[kSecAttrAccount as String] as? String == endpoint.key)
    }

    // MARK: setCredentials

    @Test func nilCredentialsDeletes() throws {
        let recorder = Recorder()
        let endpoint = try endpoint()
        try store(recorder).setCredentials(nil, for: endpoint)

        #expect(recorder.deleteQueries.count == 1)
        #expect(recorder.deleteQueries.first?[kSecAttrAccount as String] as? String == endpoint.key)
        #expect(recorder.updateQueries.isEmpty)
        #expect(recorder.addItems.isEmpty)
    }

    @Test func credentialsAreStoredAsDecodableJSON() throws {
        let recorder = Recorder(updateStatus: errSecSuccess)
        try store(recorder).setCredentials(.sessionToken("abc"), for: try endpoint())

        let data = try #require(
            recorder.updateAttributes.first?[kSecValueData as String] as? Data)
        let decoded = try JSONDecoder().decode(ServerCredentials.self, from: data)
        #expect(decoded == .sessionToken("abc"))
    }

    // MARK: errors

    @Test func writeFailedDescriptionMentionsKeychain() {
        let description = KeychainError.writeFailed(errSecAuthFailed).errorDescription
        #expect(description?.contains("keychain") == true)
    }
}
