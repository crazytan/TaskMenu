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

    // MARK: - Access Group

    func testAccessGroupInstanceIsIsolatedFromLegacyInstanceUnderSameService() throws {
        let service = "dev.crazytan.TaskMenu.test.accessgroup.\(UUID().uuidString)"
        let legacy = KeychainService(service: service, environment: testEnvironment)
        let shared = KeychainService(service: service, accessGroup: "test-shared-group", environment: testEnvironment)

        try legacy.save(key: "token", string: "legacy-value")

        // Same service string, different access group: must not see each other's data.
        XCTAssertNil(try shared.readString(key: "token"))
        XCTAssertEqual(try legacy.readString(key: "token"), "legacy-value")

        try shared.save(key: "token", string: "shared-value")
        XCTAssertEqual(try shared.readString(key: "token"), "shared-value")
        XCTAssertEqual(try legacy.readString(key: "token"), "legacy-value")
    }

    func testAccessGroupInstanceDeleteDoesNotTouchLegacyInstance() throws {
        let service = "dev.crazytan.TaskMenu.test.accessgroup.delete.\(UUID().uuidString)"
        let legacy = KeychainService(service: service, environment: testEnvironment)
        let shared = KeychainService(service: service, accessGroup: "test-shared-group", environment: testEnvironment)

        try legacy.save(key: "token", string: "legacy-value")
        try shared.save(key: "token", string: "shared-value")

        try shared.delete(key: "token")

        XCTAssertNil(try shared.readString(key: "token"))
        XCTAssertEqual(try legacy.readString(key: "token"), "legacy-value")
    }

    func testAccessGroupInstanceRoundTripsData() throws {
        let shared = KeychainService(
            service: "dev.crazytan.TaskMenu.test.accessgroup.roundtrip.\(UUID().uuidString)",
            accessGroup: "test-shared-group",
            environment: testEnvironment
        )

        try shared.save(key: "token", string: "abc123")
        XCTAssertEqual(try shared.readString(key: "token"), "abc123")

        try shared.delete(key: "token")
        XCTAssertNil(try shared.readString(key: "token"))
    }
}
