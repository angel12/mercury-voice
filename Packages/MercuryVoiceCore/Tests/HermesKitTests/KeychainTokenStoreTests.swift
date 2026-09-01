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
    private var _updateStatus: OSStatus = errSecSuccess
    private var _addStatus: OSStatus = errSecSuccess
    private var _deleteStatus: OSStatus = errSecSuccess

    init(
        updateStatus: OSStatus = errSecSuccess,
        addStatus: OSStatus = errSecSuccess,
        deleteStatus: OSStatus = errSecSuccess
    ) {
        _updateStatus = updateStatus
        _addStatus = addStatus
        _deleteStatus = deleteStatus
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
                    return _updateStatus
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
        try store(recorder).setToken("tok-123", for: try endpoint())

        #expect(recorder.updateQueries.count == 1)
        #expect(recorder.addItems.isEmpty)
        let data = recorder.updateAttributes.first?[kSecValueData as String] as? Data
        #expect(data == Data("tok-123".utf8))
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
        try store(recorder).setToken(token, for: try endpoint())

        #expect(recorder.deleteQueries.count == 1)
        #expect(recorder.updateQueries.isEmpty)
        #expect(recorder.addItems.isEmpty)
    }

    // MARK: deleteToken

    @Test func deleteTreatsItemNotFoundAsSuccess() throws {
        let recorder = Recorder(deleteStatus: errSecItemNotFound)
        try store(recorder).deleteToken(for: try endpoint())
        #expect(recorder.deleteQueries.count == 1)
    }

    @Test func deleteFailureThrowsDeleteFailed() throws {
        let recorder = Recorder(deleteStatus: errSecAuthFailed)
        let store = store(recorder)
        let endpoint = try endpoint()

        #expect(throws: KeychainError.deleteFailed(errSecAuthFailed)) {
            try store.deleteToken(for: endpoint)
        }
    }

    // MARK: setCredentials

    @Test func nilCredentialsDeletes() throws {
        let recorder = Recorder()
        try store(recorder).setCredentials(nil, for: try endpoint())

        #expect(recorder.deleteQueries.count == 1)
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
