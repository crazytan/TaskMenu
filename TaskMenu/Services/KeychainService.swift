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

        // Delete existing item first
        let deleteQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
        SecItemDelete(deleteQuery as CFDictionary)

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]

        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw KeychainError.saveFailed(status)
        }
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

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

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

    func readString(key: String) throws -> String? {
        guard let data = try read(key: key) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func delete(key: String) throws {
        if let testStore {
            testStore.delete(service: service, key: key)
            return
        }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]

        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.deleteFailed(status)
        }
    }

    func deleteAll() throws {
        if let testStore {
            testStore.deleteAll(service: service)
            return
        }

        // Delete known keys individually for reliability across macOS versions
        for key in [Constants.Keychain.accessTokenKey, Constants.Keychain.refreshTokenKey, Constants.Keychain.expirationKey] {
            try delete(key: key)
        }
    }
}
