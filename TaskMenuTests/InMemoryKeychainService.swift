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
final class InMemoryKeychainService: KeychainServiceProtocol, @unchecked Sendable {
    private var storage: [String: Data] = [:]

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
