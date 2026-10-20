import Foundation
import Security

enum KeychainError: Error, Sendable {
    case saveFailed(OSStatus)
    case readFailed(OSStatus)
    case deleteFailed(OSStatus)
    case unexpectedData
}

protocol KeychainServiceProtocol: Sendable {
    func save(key: String, data: Data) throws
    func save(key: String, string: String) throws
    func read(key: String) throws -> Data?
    func readString(key: String) throws -> String?
    func delete(key: String) throws
    func deleteAll() throws
}

private final class TestKeychainStore: @unchecked Sendable {
    static let shared = TestKeychainStore()

    private let lock = NSLock()
    private var storage: [String: [String: Data]] = [:]

    func save(service: String, key: String, data: Data) {
        lock.lock()
        defer { lock.unlock() }

        var serviceStorage = storage[service] ?? [:]
        serviceStorage[key] = data
        storage[service] = serviceStorage
    }

    func read(service: String, key: String) -> Data? {
        lock.lock()
        defer { lock.unlock() }

        return storage[service]?[key]
    }

    func delete(service: String, key: String) {
        lock.lock()
        defer { lock.unlock() }

        storage[service]?[key] = nil
        if storage[service]?.isEmpty == true {
            storage[service] = nil
        }
    }

    func deleteAll(service: String) {
        lock.lock()
        defer { lock.unlock() }

        storage[service] = nil
    }
}

struct KeychainService: KeychainServiceProtocol, Sendable {
    let service: String
    /// An explicit group uses only that group's data-protection keychain.
    /// With no group, use only the legacy file-based login keychain. Never
    /// issue an unqualified data-protection query: it can match the shared
    /// credentials and let migration cleanup delete the current sign-in.
    let accessGroup: String?
    private let testStore: TestKeychainStore?

    init(
        service: String = SharedConstants.Keychain.service,
        accessGroup: String? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        self.service = service
        self.accessGroup = accessGroup
        // Hosted unit tests launch the app target, so avoid touching the login keychain entirely.
        self.testStore = environment["XCTestConfigurationFilePath"] == nil ? nil : .shared
    }

    func save(key: String, data: Data) throws {
        if let testStore {
            testStore.save(service: testStoreKey, key: key, data: data)
            return
        }

        try addItem(key: key, data: data, useDataProtection: accessGroup != nil)
    }

    func save(key: String, string: String) throws {
        guard let data = string.data(using: .utf8) else {
            throw KeychainError.unexpectedData
        }
        try save(key: key, data: data)
    }

    func read(key: String) throws -> Data? {
        if let testStore {
            return testStore.read(service: testStoreKey, key: key)
        }

        return try copyItem(key: key, useDataProtection: accessGroup != nil)
    }

    func readString(key: String) throws -> String? {
        guard let data = try read(key: key) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func delete(key: String) throws {
        if let testStore {
            testStore.delete(service: testStoreKey, key: key)
            return
        }

        let status = deleteItem(key: key, useDataProtection: accessGroup != nil)
        guard status == errSecSuccess
            || status == errSecItemNotFound
            || status == errSecMissingEntitlement else {
            throw KeychainError.deleteFailed(status)
        }
    }

    func deleteAll() throws {
        if let testStore {
            testStore.deleteAll(service: testStoreKey)
            return
        }

        // Delete known keys individually for reliability across macOS versions
        for key in [
            SharedConstants.Keychain.accessTokenKey,
            SharedConstants.Keychain.refreshTokenKey,
            SharedConstants.Keychain.expirationKey,
            SharedConstants.Keychain.accountProfileKey,
        ] {
            try delete(key: key)
        }
    }

    // MARK: - SecItem Helpers

    /// XCTest in-memory store key: composite of `service` and `accessGroup`
    /// so a shared-group instance and a legacy (no-group) instance sharing
    /// the same `service` string remain distinct stores under test, matching
    /// the two production locations (legacy login vs shared data protection).
    private var testStoreKey: String {
        guard let accessGroup else { return service }
        return "\(service)#\(accessGroup)"
    }

    // The released pre-widget app lacked an application-identifier entitlement
    // and saved to the login keychain. Keep that migration source disjoint
    // from all shared data-protection items, including on subsequent launches.
    private func baseQuery(key: String, useDataProtection: Bool) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
        query[kSecUseDataProtectionKeychain as String] = useDataProtection
        if let accessGroup {
            query[kSecAttrAccessGroup as String] = accessGroup
        }
        return query
    }

    private func addItem(key: String, data: Data, useDataProtection: Bool) throws {
        // Delete existing item first
        _ = deleteItem(key: key, useDataProtection: useDataProtection)

        var query = baseQuery(key: key, useDataProtection: useDataProtection)
        query[kSecValueData as String] = data
        query[kSecAttrAccessible as String] = useDataProtection
            ? kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            : kSecAttrAccessibleAfterFirstUnlock

        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw KeychainError.saveFailed(status)
        }
    }

    private func copyItem(key: String, useDataProtection: Bool) throws -> Data? {
        var query = baseQuery(key: key, useDataProtection: useDataProtection)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        if status == errSecItemNotFound {
            return nil
        }

        guard status == errSecSuccess else {
            throw KeychainError.readFailed(status)
        }

        return result as? Data
    }

    private func deleteItem(key: String, useDataProtection: Bool) -> OSStatus {
        SecItemDelete(baseQuery(key: key, useDataProtection: useDataProtection) as CFDictionary)
    }
}
