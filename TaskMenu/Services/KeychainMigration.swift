import Foundation

/// Outcome of migrating one Keychain key. Explicit states rather than
/// booleans buried in query construction, per
/// `scratch/issue-11-desktop-widget/implementation-spec.md` ("Add a small
/// migration coordinator with explicit states rather than burying migration
/// in `baseQuery`").
enum KeychainItemMigrationState: Sendable, Hashable {
    /// No shared access group is resolved (unsigned dev/CI build); migration
    /// is a safe no-op and the app keeps working exactly as it does today.
    case skippedNoSharedGroup
    /// No legacy value existed for this key; nothing to do.
    case noLegacyValue
    /// The shared copy already existed (a prior run finished this key, or
    /// the widget provider itself wrote a refreshed value there). Shared
    /// copies always win: the legacy value is never used to overwrite it.
    /// Any lingering legacy copy is cleaned up so it cannot resurrect stale
    /// state later.
    case alreadyShared
    /// The legacy value was copied to the shared group, read back to verify
    /// it round-tripped correctly, and only then deleted from the legacy
    /// location.
    case migrated
    /// Writing the shared copy failed; the legacy item was left untouched.
    case sharedWriteFailed
    /// The shared write did not verify (a read-back mismatch or miss); the
    /// legacy item was left untouched rather than risk losing the only good
    /// copy.
    case verificationFailed
}

protocol KeychainMigrationCoordinating: Sendable {
    /// Migrates every known OAuth Keychain key from the legacy (app-only)
    /// location to the shared Keychain access group.
    ///
    /// Safe to call on every launch: already-migrated keys resolve to
    /// `.alreadyShared`, and a crash between any two item writes on a
    /// previous run is resumed safely because each key is migrated
    /// independently and verified (write, then read back) before its legacy
    /// copy is removed.
    @discardableResult
    func migrateIfNeeded() -> [String: KeychainItemMigrationState]
}

/// Migrates OAuth Keychain items from the app's legacy default-location
/// storage to the shared Keychain access group that lets `TaskMenuWidget`
/// read tokens without the containing app running.
///
/// "Legacy" here is exactly today's `KeychainService()` default — the
/// data-protection keychain with no explicit access group, falling back to
/// the file-based login keychain — per
/// `scratch/issue-11-desktop-widget/CONTRACT.md` ("Verified environment
/// facts"): the shipped app has no `application-identifier` entitlement, so
/// every existing install's tokens already live exactly there. There is no
/// "old team-prefixed access group" to reason about.
///
/// The extension never runs this type; migration is exclusively the
/// containing app's responsibility (CONTRACT.md "Target membership" — this
/// file is intentionally not part of the `TaskMenuWidget` target).
struct KeychainMigration: KeychainMigrationCoordinating {
    /// Every Keychain key OAuth state is stored under.
    static let knownKeys = [
        SharedConstants.Keychain.accessTokenKey,
        SharedConstants.Keychain.refreshTokenKey,
        SharedConstants.Keychain.expirationKey,
        SharedConstants.Keychain.accountProfileKey,
    ]

    private let legacyKeychain: any KeychainServiceProtocol
    private let sharedKeychain: (any KeychainServiceProtocol)?

    /// - Parameters:
    ///   - legacyKeychain: The app's pre-widget storage location — today's
    ///     `KeychainService()` (data-protection keychain with no explicit
    ///     access group, falling back to the login keychain for unsigned
    ///     builds).
    ///   - sharedKeychain: The shared access-group location, or `nil` when
    ///     `SharedConstants.keychainAccessGroup` did not resolve (unsigned
    ///     dev/CI build). `nil` makes `migrateIfNeeded()` a safe no-op that
    ///     never touches `legacyKeychain`.
    init(legacyKeychain: any KeychainServiceProtocol, sharedKeychain: (any KeychainServiceProtocol)?) {
        self.legacyKeychain = legacyKeychain
        self.sharedKeychain = sharedKeychain
    }

    @discardableResult
    func migrateIfNeeded() -> [String: KeychainItemMigrationState] {
        guard let sharedKeychain else {
            return Dictionary(uniqueKeysWithValues: Self.knownKeys.map { ($0, .skippedNoSharedGroup) })
        }

        var results: [String: KeychainItemMigrationState] = [:]
        for key in Self.knownKeys {
            results[key] = migrate(key: key, into: sharedKeychain)
        }
        return results
    }

    // MARK: - Private

    private func migrate(key: String, into sharedKeychain: any KeychainServiceProtocol) -> KeychainItemMigrationState {
        // Shared copies always win. If one already exists (a previous run
        // finished this key, or the widget refreshed and wrote a new
        // value), never overwrite it with a possibly-stale legacy value —
        // just make sure no lingering legacy copy can resurrect old state.
        if Self.read(sharedKeychain, key: key) != nil {
            if Self.read(legacyKeychain, key: key) != nil {
                try? legacyKeychain.delete(key: key)
            }
            return .alreadyShared
        }

        guard let legacyData = Self.read(legacyKeychain, key: key) else {
            return .noLegacyValue
        }

        do {
            try sharedKeychain.save(key: key, data: legacyData)
        } catch {
            return .sharedWriteFailed
        }

        // Never delete the legacy item until the shared item was written
        // AND read back successfully.
        guard let verifyData = Self.read(sharedKeychain, key: key), verifyData == legacyData else {
            return .verificationFailed
        }

        try? legacyKeychain.delete(key: key)
        return .migrated
    }

    private static func read(_ keychain: any KeychainServiceProtocol, key: String) -> Data? {
        (try? keychain.read(key: key)) ?? nil
    }
}
