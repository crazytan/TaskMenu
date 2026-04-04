import XCTest
@testable import TaskMenu

/// Tests KeychainServiceProtocol contract using InMemoryKeychainService.
/// Avoids real macOS Keychain access (and password prompts) during tests.
final class KeychainServiceTests: XCTestCase {
    private var keychain: InMemoryKeychainService!
    private let testEnvironment = ["XCTestConfigurationFilePath": "/tmp/TaskMenuTests.xctestconfiguration"]

    override func setUp() {
        super.setUp()
        keychain = InMemoryKeychainService()
    }

    func testSaveAndReadString() throws {
        try keychain.save(key: "token", string: "abc123")
        let result = try keychain.readString(key: "token")
        XCTAssertEqual(result, "abc123")
    }

    func testSaveAndReadData() throws {
        let data = "hello".data(using: .utf8)!
        try keychain.save(key: "data", data: data)
        let result = try keychain.read(key: "data")
        XCTAssertEqual(result, data)
    }

    func testReadMissingKeyReturnsNil() throws {
        let result = try keychain.readString(key: "nonexistent")
        XCTAssertNil(result)
    }

    func testOverwriteExistingValue() throws {
        try keychain.save(key: "token", string: "old")
        try keychain.save(key: "token", string: "new")
        let result = try keychain.readString(key: "token")
        XCTAssertEqual(result, "new")
    }

    func testDeleteKey() throws {
        try keychain.save(key: "token", string: "abc")
        try keychain.delete(key: "token")
        let result = try keychain.readString(key: "token")
        XCTAssertNil(result)
    }

    func testDeleteNonexistentKeyDoesNotThrow() throws {
        XCTAssertNoThrow(try keychain.delete(key: "nonexistent"))
    }

    func testDeleteAll() throws {
        try keychain.save(key: Constants.Keychain.accessTokenKey, string: "token1")
        try keychain.save(key: Constants.Keychain.refreshTokenKey, string: "token2")
        try keychain.save(key: Constants.Keychain.expirationKey, string: "12345")
        try keychain.deleteAll()
        XCTAssertNil(try keychain.readString(key: Constants.Keychain.accessTokenKey))
        XCTAssertNil(try keychain.readString(key: Constants.Keychain.refreshTokenKey))
        XCTAssertNil(try keychain.readString(key: Constants.Keychain.expirationKey))
    }

    func testProductionKeychainUsesInMemoryStoreUnderXCTest() throws {
        let keychain = KeychainService(
            service: "dev.crazytan.TaskMenu.test.production.\(UUID().uuidString)",
            environment: testEnvironment
        )

        try keychain.save(key: "token", string: "abc123")

        XCTAssertEqual(try keychain.readString(key: "token"), "abc123")
    }

    func testProductionKeychainInMemoryStoreIsScopedByService() throws {
        let keychainA = KeychainService(
            service: "dev.crazytan.TaskMenu.test.production.a.\(UUID().uuidString)",
            environment: testEnvironment
        )
        let keychainB = KeychainService(
            service: "dev.crazytan.TaskMenu.test.production.b.\(UUID().uuidString)",
            environment: testEnvironment
        )

        try keychainA.save(key: "token", string: "value-a")

        XCTAssertEqual(try keychainA.readString(key: "token"), "value-a")
        XCTAssertNil(try keychainB.readString(key: "token"))
    }
}
