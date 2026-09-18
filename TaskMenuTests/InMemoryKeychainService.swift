@testable import TaskMenu
import Foundation

/// Keychain stub that always throws — for testing error-handling paths.
final class FailingKeychainService: KeychainServiceProtocol, @unchecked Sendable {
    func save(key: String, data: Data) throws {
        throw KeychainError.saveFailed(-1)
    }

    func save(key: String, string: String) throws {
        throw KeychainError.saveFailed(-1)
    }

    func read(key: String) throws -> Data? {
        throw KeychainError.readFailed(-1)
    }

    func readString(key: String) throws -> String? {
        throw KeychainError.readFailed(-1)
    }

    func delete(key: String) throws {
        throw KeychainError.deleteFailed(-1)
    }

    func deleteAll() throws {
        throw KeychainError.deleteFailed(-1)
    }
}

/// In-memory keychain replacement for tests — avoids macOS Keychain prompts.
///
/// Each instance is an independent store, which is itself how it models a
/// Keychain access group for tests: construct one `InMemoryKeychainService`
/// to stand in for the legacy (no group) location and a separate one for
/// the shared access group, and pass each to the code under test exactly as
/// production would pass two differently-scoped `KeychainService` instances.
/// `accessGroup` is a label only — it does not change behavior — so
/// migration/provider tests can express "the shared group" and "the legacy
/// location" as clearly distinct doubles.
final class InMemoryKeychainService: KeychainServiceProtocol, @unchecked Sendable {
    let accessGroup: String?
    private var storage: [String: Data] = [:]

    init(accessGroup: String? = nil) {
        self.accessGroup = accessGroup
    }

    func save(key: String, data: Data) throws {
        storage[key] = data
    }

    func save(key: String, string: String) throws {
        guard let data = string.data(using: .utf8) else {
            throw KeychainError.unexpectedData
        }
        storage[key] = data
    }

    func read(key: String) throws -> Data? {
        storage[key]
    }

    func readString(key: String) throws -> String? {
        guard let data = storage[key] else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func delete(key: String) throws {
        storage.removeValue(forKey: key)
    }

    func deleteAll() throws {
        storage.removeAll()
    }
}
