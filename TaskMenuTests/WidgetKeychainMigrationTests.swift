import Security
import XCTest
@testable import TaskMenu

/// Tests `KeychainMigration` — the coordinator that copies OAuth Keychain
/// items from the app's legacy (pre-widget) location to the shared
/// Keychain access group so `TaskMenuWidget` can read them. Every test
/// primarily uses in-memory doubles. The signed-host regression cases use
/// unique disposable services to verify real Security framework query
/// scoping, and skip when the host lacks shared Keychain entitlements.
@MainActor
final class WidgetKeychainMigrationTests: XCTestCase {
    private let allKeys = KeychainMigration.knownKeys

    // These regression tests deliberately bypass the XCTest in-memory store.
    // Only a real signed host models an omitted access group's wildcard
    // matching. Each run uses its own disposable service, never OAuth items.
    private func signedKeychains() throws -> (legacy: KeychainService, shared: KeychainService) {
        guard let group = SharedConstants.keychainAccessGroup else {
            throw XCTSkip("Requires a signed host with the shared Keychain group")
        }
        let service = "dev.crazytan.TaskMenu.migration-test.\(UUID().uuidString)"
        let legacy = KeychainService(service: service, environment: [:])
        let shared = KeychainService(service: service, accessGroup: group, environment: [:])
        do {
            try shared.save(key: allKeys[0], string: "disposable-test-value")
            try shared.delete(key: allKeys[0])
        } catch KeychainError.saveFailed(let status) where status == errSecMissingEntitlement {
            throw XCTSkip("Host has no shared Keychain entitlement")
        }
        return (legacy, shared)
    }

    func testSignedSharedCredentialsSurviveRepeatedAppStartup() throws {
        let (legacy, shared) = try signedKeychains()
        defer { try? legacy.deleteAll(); try? shared.deleteAll() }
        try shared.save(key: SharedConstants.Keychain.accessTokenKey, string: "test-access")
        try shared.save(key: SharedConstants.Keychain.refreshTokenKey, string: "test-refresh")
        let migration = KeychainMigration(legacyKeychain: legacy, sharedKeychain: shared)

        for _ in 0..<3 {
            let auth = GoogleAuthService(keychain: shared, legacyKeychain: legacy, migration: migration)
            XCTAssertTrue(auth.isSignedIn)
            XCTAssertEqual(auth.refreshToken, "test-refresh")
            XCTAssertEqual(try shared.readString(key: SharedConstants.Keychain.refreshTokenKey), "test-refresh")
            XCTAssertNil(try legacy.readString(key: SharedConstants.Keychain.refreshTokenKey))
        }
    }

    func testSignedLegacyUpgradePreservesEveryCredentialAcrossRelaunch() throws {
        let (legacy, shared) = try signedKeychains()
        defer { try? legacy.deleteAll(); try? shared.deleteAll() }
        for key in allKeys {
            try legacy.save(key: key, string: "test-\(key)")
        }
        let migration = KeychainMigration(legacyKeychain: legacy, sharedKeychain: shared)
        XCTAssertEqual(Set(migration.migrateIfNeeded().values), [.migrated])
        XCTAssertEqual(Set(migration.migrateIfNeeded().values), [.alreadyShared])
        for key in allKeys {
            XCTAssertEqual(try shared.readString(key: key), "test-\(key)")
            XCTAssertNil(try legacy.read(key: key))
        }
    }

    func testSignedLegacyCleanupKeepsNewerSharedCredential() throws {
        let (legacy, shared) = try signedKeychains()
        defer { try? legacy.deleteAll(); try? shared.deleteAll() }
        let key = SharedConstants.Keychain.refreshTokenKey
        try legacy.save(key: key, string: "stale-test-refresh")
        try shared.save(key: key, string: "current-test-refresh")
        let migration = KeychainMigration(legacyKeychain: legacy, sharedKeychain: shared)

        XCTAssertEqual(migration.migrateIfNeeded()[key], .alreadyShared)
        XCTAssertNil(try legacy.read(key: key))
        XCTAssertEqual(try shared.readString(key: key), "current-test-refresh")
    }

    // MARK: - No shared group resolved

    func testMigrateIfNeededIsSafeNoOpWhenSharedGroupUnresolved() throws {
        let legacy = InMemoryKeychainService()
        try legacy.save(key: SharedConstants.Keychain.accessTokenKey, string: "legacy-access")
        try legacy.save(key: SharedConstants.Keychain.refreshTokenKey, string: "legacy-refresh")

        let migration = KeychainMigration(legacyKeychain: legacy, sharedKeychain: nil)
        let results = migration.migrateIfNeeded()

        XCTAssertEqual(Set(results.values), [.skippedNoSharedGroup])
        // Legacy data must be completely untouched.
        XCTAssertEqual(try legacy.readString(key: SharedConstants.Keychain.accessTokenKey), "legacy-access")
        XCTAssertEqual(try legacy.readString(key: SharedConstants.Keychain.refreshTokenKey), "legacy-refresh")
    }

    // MARK: - Fresh shared save/read/delete

    func testFreshSharedKeychainSaveReadDeleteRoundTrips() throws {
        let shared = InMemoryKeychainService(accessGroup: "shared-group")

        try shared.save(key: SharedConstants.Keychain.accessTokenKey, string: "fresh-token")
        XCTAssertEqual(try shared.readString(key: SharedConstants.Keychain.accessTokenKey), "fresh-token")

        try shared.delete(key: SharedConstants.Keychain.accessTokenKey)
        XCTAssertNil(try shared.readString(key: SharedConstants.Keychain.accessTokenKey))
    }

    // MARK: - Legacy-only install

    func testLegacyOnlyInstallMigratesEveryKnownKeyAndStaysSignedIn() throws {
        let legacy = InMemoryKeychainService()
        let shared = InMemoryKeychainService(accessGroup: "shared-group")

        try legacy.save(key: SharedConstants.Keychain.accessTokenKey, string: "access-value")
        try legacy.save(key: SharedConstants.Keychain.refreshTokenKey, string: "refresh-value")
        try legacy.save(key: SharedConstants.Keychain.expirationKey, string: "1234567890")
        try legacy.save(
            key: SharedConstants.Keychain.accountProfileKey,
            data: JSONEncoder().encode(GoogleAccountProfile(email: "tan@example.com"))
        )

        let migration = KeychainMigration(legacyKeychain: legacy, sharedKeychain: shared)
        let results = migration.migrateIfNeeded()

        XCTAssertEqual(Set(results.values), [.migrated])
        for key in allKeys {
            XCTAssertNil(try legacy.read(key: key), "legacy copy of \(key) should be gone")
        }
        XCTAssertEqual(try shared.readString(key: SharedConstants.Keychain.accessTokenKey), "access-value")
        XCTAssertEqual(try shared.readString(key: SharedConstants.Keychain.refreshTokenKey), "refresh-value")
        XCTAssertEqual(try shared.readString(key: SharedConstants.Keychain.expirationKey), "1234567890")

        // Reconstructing GoogleAuthService against the now-migrated shared
        // store (with an already-empty legacy store) proves the user stays
        // signed in after migration.
        let auth = GoogleAuthService(keychain: shared, legacyKeychain: InMemoryKeychainService())
        XCTAssertTrue(auth.isSignedIn)
        XCTAssertEqual(auth.accessToken, "access-value")
        XCTAssertEqual(auth.refreshToken, "refresh-value")
        XCTAssertEqual(auth.accountProfile?.email, "tan@example.com")
    }

    // MARK: - Shared copy wins

    func testSharedCopyWinsWhenBothExist() throws {
        let legacy = InMemoryKeychainService()
        let shared = InMemoryKeychainService(accessGroup: "shared-group")

        try legacy.save(key: SharedConstants.Keychain.accessTokenKey, string: "stale-legacy-value")
        try shared.save(key: SharedConstants.Keychain.accessTokenKey, string: "current-shared-value")

        let migration = KeychainMigration(legacyKeychain: legacy, sharedKeychain: shared)
        let results = migration.migrateIfNeeded()

        XCTAssertEqual(results[SharedConstants.Keychain.accessTokenKey], .alreadyShared)
        // Shared value must not be overwritten by the stale legacy value.
        XCTAssertEqual(try shared.readString(key: SharedConstants.Keychain.accessTokenKey), "current-shared-value")
        // The lingering legacy copy is cleaned up so it cannot resurrect stale state.
        XCTAssertNil(try legacy.read(key: SharedConstants.Keychain.accessTokenKey))
    }

    // MARK: - Partial migration resumes safely

    func testPartialMigrationResumesSafely() throws {
        let legacy = InMemoryKeychainService()
        let shared = InMemoryKeychainService(accessGroup: "shared-group")

        // All four keys still in legacy...
        try legacy.save(key: SharedConstants.Keychain.accessTokenKey, string: "access-value")
        try legacy.save(key: SharedConstants.Keychain.refreshTokenKey, string: "refresh-value")
        try legacy.save(key: SharedConstants.Keychain.expirationKey, string: "1111111111")
        try legacy.save(key: SharedConstants.Keychain.accountProfileKey, string: "profile-value")

        // ...but a previous run already finished migrating (write + verify)
        // one key before "crashing" prior to its legacy delete step.
        try shared.save(key: SharedConstants.Keychain.accessTokenKey, string: "access-value")

        let migration = KeychainMigration(legacyKeychain: legacy, sharedKeychain: shared)
        let results = migration.migrateIfNeeded()

        XCTAssertEqual(results[SharedConstants.Keychain.accessTokenKey], .alreadyShared)
        XCTAssertEqual(results[SharedConstants.Keychain.refreshTokenKey], .migrated)
        XCTAssertEqual(results[SharedConstants.Keychain.expirationKey], .migrated)
        XCTAssertEqual(results[SharedConstants.Keychain.accountProfileKey], .migrated)

        for key in allKeys {
            XCTAssertNil(try legacy.read(key: key), "legacy copy of \(key) should be gone after resuming")
        }
        XCTAssertEqual(try shared.readString(key: SharedConstants.Keychain.accessTokenKey), "access-value")
        XCTAssertEqual(try shared.readString(key: SharedConstants.Keychain.refreshTokenKey), "refresh-value")
        XCTAssertEqual(try shared.readString(key: SharedConstants.Keychain.expirationKey), "1111111111")
        XCTAssertEqual(try shared.readString(key: SharedConstants.Keychain.accountProfileKey), "profile-value")

        // Running it a third time (fully migrated state) is also safe and idempotent.
        let secondResults = migration.migrateIfNeeded()
        XCTAssertEqual(Set(secondResults.values), [.alreadyShared])
    }

    // MARK: - Failed shared write leaves legacy intact

    func testFailedSharedWriteLeavesLegacyIntact() throws {
        let legacy = InMemoryKeychainService()
        let shared = ScriptedKeychainService()
        shared.failingSaveKeys = [SharedConstants.Keychain.accessTokenKey]

        try legacy.save(key: SharedConstants.Keychain.accessTokenKey, string: "access-value")

        let migration = KeychainMigration(legacyKeychain: legacy, sharedKeychain: shared)
        let results = migration.migrateIfNeeded()

        XCTAssertEqual(results[SharedConstants.Keychain.accessTokenKey], .sharedWriteFailed)
        XCTAssertEqual(try legacy.readString(key: SharedConstants.Keychain.accessTokenKey), "access-value")
        XCTAssertNil(try shared.read(key: SharedConstants.Keychain.accessTokenKey))
    }

    // MARK: - Verified migration deletes only the exact legacy record

    func testUnverifiableSharedWriteLeavesLegacyIntact() throws {
        let legacy = InMemoryKeychainService()
        let shared = ScriptedKeychainService()
        // Simulate a write that "succeeds" but reads back as something else
        // (e.g. a concurrent writer, or a corrupted item).
        shared.readOverrides[SharedConstants.Keychain.accessTokenKey] = Data("unexpected".utf8)

        try legacy.save(key: SharedConstants.Keychain.accessTokenKey, string: "access-value")

        let migration = KeychainMigration(legacyKeychain: legacy, sharedKeychain: shared)
        let results = migration.migrateIfNeeded()

        XCTAssertEqual(results[SharedConstants.Keychain.accessTokenKey], .verificationFailed)
        XCTAssertEqual(try legacy.readString(key: SharedConstants.Keychain.accessTokenKey), "access-value")
    }

    func testMigrationDeletesOnlyTheExactLegacyRecordItVerified() throws {
        let legacy = InMemoryKeychainService()
        let shared = InMemoryKeychainService(accessGroup: "shared-group")

        try legacy.save(key: SharedConstants.Keychain.accessTokenKey, string: "access-value")
        try legacy.save(key: SharedConstants.Keychain.refreshTokenKey, string: "refresh-value")
        // A key outside the known-keys list must never be touched by migration.
        try legacy.save(key: "unrelated-app-setting", string: "leave-me-alone")

        let migration = KeychainMigration(legacyKeychain: legacy, sharedKeychain: shared)
        _ = migration.migrateIfNeeded()

        XCTAssertNil(try legacy.read(key: SharedConstants.Keychain.accessTokenKey))
        XCTAssertNil(try legacy.read(key: SharedConstants.Keychain.refreshTokenKey))
        XCTAssertEqual(try legacy.readString(key: "unrelated-app-setting"), "leave-me-alone")
    }

    func testNoLegacyValueResultsInNoLegacyValueState() throws {
        let legacy = InMemoryKeychainService()
        let shared = InMemoryKeychainService(accessGroup: "shared-group")

        let migration = KeychainMigration(legacyKeychain: legacy, sharedKeychain: shared)
        let results = migration.migrateIfNeeded()

        XCTAssertEqual(Set(results.values), [.noLegacyValue])
    }

    // MARK: - Sign-out removes both locations

    func testSignOutRemovesBothSharedAndLegacyCopies() throws {
        let shared = InMemoryKeychainService(accessGroup: "shared-group")
        let legacy = InMemoryKeychainService()

        try shared.save(key: SharedConstants.Keychain.accessTokenKey, string: "shared-access")
        try shared.save(key: SharedConstants.Keychain.refreshTokenKey, string: "shared-refresh")
        try legacy.save(key: SharedConstants.Keychain.accessTokenKey, string: "legacy-access")
        try legacy.save(key: SharedConstants.Keychain.refreshTokenKey, string: "legacy-refresh")

        let auth = GoogleAuthService(keychain: shared, legacyKeychain: legacy)
        XCTAssertTrue(auth.isSignedIn)

        auth.signOut()

        XCTAssertNil(try shared.readString(key: SharedConstants.Keychain.accessTokenKey))
        XCTAssertNil(try shared.readString(key: SharedConstants.Keychain.refreshTokenKey))
        XCTAssertNil(try legacy.readString(key: SharedConstants.Keychain.accessTokenKey))
        XCTAssertNil(try legacy.readString(key: SharedConstants.Keychain.refreshTokenKey))
        XCTAssertFalse(auth.isSignedIn)
    }
}

// MARK: - Test Doubles

/// Scriptable keychain double for exercising migration edge cases that
/// `InMemoryKeychainService` cannot express on its own: a write that throws
/// for a specific key, or a write that "succeeds" but reads back
/// mismatched/missing data (simulating a verification failure).
private final class ScriptedKeychainService: KeychainServiceProtocol, @unchecked Sendable {
    private var storage: [String: Data] = [:]
    var failingSaveKeys: Set<String> = []
    var readOverrides: [String: Data] = [:]

    func save(key: String, data: Data) throws {
        if failingSaveKeys.contains(key) {
            throw KeychainError.saveFailed(-1)
        }
        storage[key] = data
    }

    func save(key: String, string: String) throws {
        try save(key: key, data: Data(string.utf8))
    }

    func read(key: String) throws -> Data? {
        // The override only kicks in once something has actually been
        // written, so it simulates a readback *mismatch* after a real save
        // (e.g. a corrupted write) rather than fabricating a value out of
        // thin air before migration has written anything.
        guard let stored = storage[key] else { return nil }
        return readOverrides[key] ?? stored
    }

    func readString(key: String) throws -> String? {
        guard let data = try read(key: key) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func delete(key: String) throws {
        storage.removeValue(forKey: key)
    }

    func deleteAll() throws {
        storage.removeAll()
    }
}
