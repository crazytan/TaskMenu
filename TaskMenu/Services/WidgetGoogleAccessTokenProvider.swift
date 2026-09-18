import Foundation

/// Refresh-only access-token provider for the `TaskMenuWidget` extension.
///
/// Reads OAuth state exclusively from the shared Keychain access group —
/// never the legacy app-only location; migration is exclusively the
/// containing app's responsibility (see `KeychainMigration`). Refreshes
/// through `GoogleTokenRefresher`, the same extension-safe request/response
/// policy `GoogleAuthService` uses, so the "definitive rejection" rule lives
/// in exactly one place. Never presents UI and never imports
/// `AuthenticationServices`/`AppKit`.
actor WidgetGoogleAccessTokenProvider: AccessTokenProviding {
    private let keychain: any KeychainServiceProtocol
    private let refresher: GoogleTokenRefresher
    private var refreshTask: Task<String, any Error>?

    /// - Parameters:
    ///   - keychain: The shared access-group Keychain. Production callers
    ///     should pass `KeychainService(accessGroup: SharedConstants.keychainAccessGroup)`;
    ///     the default here does exactly that.
    ///   - refresher: The shared refresh-token request/response policy.
    init(
        keychain: any KeychainServiceProtocol = KeychainService(accessGroup: SharedConstants.keychainAccessGroup),
        refresher: GoogleTokenRefresher = GoogleTokenRefresher()
    ) {
        self.keychain = keychain
        self.refresher = refresher
    }

    func validAccessToken() async throws -> String {
        if let cached = cachedAccessTokenIfValid() {
            return cached
        }

        guard let refreshToken = try keychain.readString(key: SharedConstants.Keychain.refreshTokenKey),
              !refreshToken.isEmpty else {
            throw APIError.unauthorized
        }

        // Coalesce concurrent callers within this process onto one refresh.
        if let inFlight = refreshTask {
            return try await inFlight.value
        }

        let task = Task<String, any Error> {
            defer { self.refreshTask = nil }
            return try await self.performRefresh(refreshToken: refreshToken)
        }
        refreshTask = task
        return try await task.value
    }

    // MARK: - Private

    private func cachedAccessTokenIfValid() -> String? {
        // `try?` on an already-Optional-returning throw flattens to a single
        // Optional (SE-0230): a thrown error and a stored nil both read as
        // `nil` here, which is the right behavior either way.
        guard let token = try? keychain.readString(key: SharedConstants.Keychain.accessTokenKey),
              !token.isEmpty else {
            return nil
        }
        guard let expirationString = try? keychain.readString(key: SharedConstants.Keychain.expirationKey),
              let interval = Double(expirationString) else {
            return nil
        }
        let expiration = Date(timeIntervalSince1970: interval)
        guard Date() < expiration else { return nil }
        return token
    }

    private func performRefresh(refreshToken: String) async throws -> String {
        do {
            let result = try await refresher.refresh(refreshToken: refreshToken)
            persist(result: result)
            return result.accessToken
        } catch GoogleTokenRefresherError.definitiveRejection {
            try? keychain.deleteAll()
            throw APIError.unauthorized
        } catch GoogleTokenRefresherError.transient(let apiError) {
            throw apiError
        }
    }

    private func persist(result: GoogleTokenRefresherResult) {
        do {
            try keychain.save(key: SharedConstants.Keychain.accessTokenKey, string: result.accessToken)
            try keychain.save(
                key: SharedConstants.Keychain.expirationKey,
                string: String(result.expiration.timeIntervalSince1970)
            )
            // Google omits the refresh token on most refreshes; when that
            // happens, keep the one already stored rather than clearing it.
            if let newRefreshToken = result.refreshToken {
                try keychain.save(key: SharedConstants.Keychain.refreshTokenKey, string: newRefreshToken)
            }
        } catch {
            // Best-effort persistence: the freshly refreshed access token is
            // still returned to the caller for this request even if the
            // shared write failed; the next call will refresh again.
        }
    }
}
