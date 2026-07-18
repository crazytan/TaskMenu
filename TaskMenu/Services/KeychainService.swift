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
    private let testStore: TestKeychainStore?

    init(
        service: String = Constants.Keychain.service,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        self.service = service
        // Hosted unit tests launch the app target, so avoid touching the login keychain entirely.
        self.testStore = environment["XCTestConfigurationFilePath"] == nil ? nil : .shared
    }

    func save(key: String, data: Data) throws {
        if let testStore {
            testStore.save(service: service, key: key, data: data)
            return
        }

        do {
            try addItem(key: key, data: data, useDataProtection: true)
        } catch KeychainError.saveFailed(let status) where status == errSecMissingEntitlement {
            // Unsigned/dev builds cannot use the data-protection keychain; keep legacy behavior.
            try addItem(key: key, data: data, useDataProtection: false)
            return
        }
        // Remove any stale legacy copy so it cannot shadow the migrated value later.
        _ = deleteItem(key: key, useDataProtection: false)
    }

    func save(key: String, string: String) throws {
        guard let data = string.data(using: .utf8) else {
            throw KeychainError.unexpectedData
        }
        try save(key: key, data: data)
    }

    func read(key: String) throws -> Data? {
        if let testStore {
            return testStore.read(service: service, key: key)
        }

        do {
            if let data = try copyItem(key: key, useDataProtection: true) {
                return data
            }
        } catch KeychainError.readFailed(let status) where status == errSecMissingEntitlement {
            // Unsigned/dev builds cannot use the data-protection keychain; keep legacy behavior.
            return try copyItem(key: key, useDataProtection: false)
        }

        guard let legacyData = try copyItem(key: key, useDataProtection: false) else {
            return nil
        }

        // Transparent migration: move the legacy login-keychain item to the data-protection keychain.
        do {
            try addItem(key: key, data: legacyData, useDataProtection: true)
            _ = deleteItem(key: key, useDataProtection: false)
        } catch {
            // Leave the legacy item in place so the value survives when migration cannot complete.
        }
        return legacyData
    }

    func readString(key: String) throws -> String? {
        guard let data = try read(key: key) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func delete(key: String) throws {
        if let testStore {
            testStore.delete(service: service, key: key)
            return
        }

        for status in [
            deleteItem(key: key, useDataProtection: true),
            deleteItem(key: key, useDataProtection: false),
        ] {
            guard status == errSecSuccess
                || status == errSecItemNotFound
                || status == errSecMissingEntitlement else {
                throw KeychainError.deleteFailed(status)
            }
        }
    }

    func deleteAll() throws {
        if let testStore {
            testStore.deleteAll(service: service)
            return
        }

        // Delete known keys individually for reliability across macOS versions
        for key in [
            Constants.Keychain.accessTokenKey,
            Constants.Keychain.refreshTokenKey,
            Constants.Keychain.expirationKey,
            Constants.Keychain.accountProfileKey,
        ] {
            try delete(key: key)
        }
    }

    // MARK: - SecItem Helpers

    // `useDataProtection: false` is the legacy login-keychain location used before the
    // data-protection keychain migration; it also serves unsigned/dev builds that lack
    // the entitlement (SecItem calls return errSecMissingEntitlement there).
    private func baseQuery(key: String, useDataProtection: Bool) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
        if useDataProtection {
            query[kSecUseDataProtectionKeychain as String] = true
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
