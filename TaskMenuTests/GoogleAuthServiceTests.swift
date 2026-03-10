import XCTest
@testable import TaskMenu

@MainActor
final class GoogleAuthServiceTests: XCTestCase {
    private var keychain: KeychainService!

    override func setUp() {
        super.setUp()
        keychain = KeychainService(service: "com.taskmenu.authtest.\(UUID().uuidString)")
    }

    override func tearDown() {
        try? keychain.deleteAll()
        super.tearDown()
    }

    // MARK: - isSignedIn

    func testIsSignedInWhenNoTokens() {
        let auth = GoogleAuthService(keychain: keychain)
        XCTAssertFalse(auth.isSignedIn)
    }

    func testIsSignedInWhenRefreshTokenExists() throws {
        try keychain.save(key: Constants.Keychain.refreshTokenKey, string: "refresh-token-value")
        let auth = GoogleAuthService(keychain: keychain)
        XCTAssertTrue(auth.isSignedIn)
    }

    func testIsSignedInWithOnlyAccessToken() throws {
        try keychain.save(key: Constants.Keychain.accessTokenKey, string: "access-token-value")
        let auth = GoogleAuthService(keychain: keychain)
        // Without a refresh token, the user is not considered signed in
        XCTAssertFalse(auth.isSignedIn)
    }

    // MARK: - isTokenExpired

    func testIsTokenExpiredWhenNoExpiration() {
        let auth = GoogleAuthService(keychain: keychain)
        XCTAssertTrue(auth.isTokenExpired)
    }

    func testIsTokenExpiredWhenExpirationInPast() throws {
        let pastDate = Date().addingTimeInterval(-3600)
        try keychain.save(key: Constants.Keychain.expirationKey, string: String(pastDate.timeIntervalSince1970))
        let auth = GoogleAuthService(keychain: keychain)
        XCTAssertTrue(auth.isTokenExpired)
    }

    func testIsTokenNotExpiredWhenExpirationInFuture() throws {
        let futureDate = Date().addingTimeInterval(3600)
        try keychain.save(key: Constants.Keychain.expirationKey, string: String(futureDate.timeIntervalSince1970))
        let auth = GoogleAuthService(keychain: keychain)
        XCTAssertFalse(auth.isTokenExpired)
    }

    // MARK: - Token Loading

    func testLoadTokensFromKeychain() throws {
        try keychain.save(key: Constants.Keychain.accessTokenKey, string: "my-access-token")
        try keychain.save(key: Constants.Keychain.refreshTokenKey, string: "my-refresh-token")
        let expiration = Date().addingTimeInterval(7200)
        try keychain.save(key: Constants.Keychain.expirationKey, string: String(expiration.timeIntervalSince1970))

        let auth = GoogleAuthService(keychain: keychain)
        XCTAssertEqual(auth.accessToken, "my-access-token")
        XCTAssertEqual(auth.refreshToken, "my-refresh-token")
        XCTAssertNotNil(auth.tokenExpiration)
    }

    func testLoadTokensWithInvalidExpirationString() throws {
        try keychain.save(key: Constants.Keychain.expirationKey, string: "not-a-number")
        let auth = GoogleAuthService(keychain: keychain)
        XCTAssertNil(auth.tokenExpiration)
    }

    // MARK: - Sign Out

    func testSignOutClearsTokens() throws {
        try keychain.save(key: Constants.Keychain.accessTokenKey, string: "access")
        try keychain.save(key: Constants.Keychain.refreshTokenKey, string: "refresh")
        try keychain.save(key: Constants.Keychain.expirationKey, string: String(Date().timeIntervalSince1970))

        let auth = GoogleAuthService(keychain: keychain)
        XCTAssertTrue(auth.isSignedIn)

        auth.signOut()

        XCTAssertNil(auth.accessToken)
        XCTAssertNil(auth.refreshToken)
        XCTAssertNil(auth.tokenExpiration)
        XCTAssertFalse(auth.isSignedIn)
    }

    func testSignOutClearsKeychain() throws {
        try keychain.save(key: Constants.Keychain.accessTokenKey, string: "access")
        try keychain.save(key: Constants.Keychain.refreshTokenKey, string: "refresh")

        let auth = GoogleAuthService(keychain: keychain)
        auth.signOut()

        // Verify keychain was also cleared
        XCTAssertNil(try keychain.readString(key: Constants.Keychain.accessTokenKey))
        XCTAssertNil(try keychain.readString(key: Constants.Keychain.refreshTokenKey))
        XCTAssertNil(try keychain.readString(key: Constants.Keychain.expirationKey))
    }

    // MARK: - validAccessToken

    func testValidAccessTokenThrowsWhenNoRefreshToken() async {
        let auth = GoogleAuthService(keychain: keychain)
        do {
            _ = try await auth.validAccessToken()
            XCTFail("Expected APIError.unauthorized")
        } catch {
            guard case APIError.unauthorized = error else {
                XCTFail("Expected APIError.unauthorized, got \(error)")
                return
            }
        }
    }

    func testValidAccessTokenReturnsNonExpiredToken() async throws {
        try keychain.save(key: Constants.Keychain.accessTokenKey, string: "valid-token")
        let futureDate = Date().addingTimeInterval(3600)
        try keychain.save(key: Constants.Keychain.expirationKey, string: String(futureDate.timeIntervalSince1970))

        let auth = GoogleAuthService(keychain: keychain)
        let token = try await auth.validAccessToken()
        XCTAssertEqual(token, "valid-token")
    }
}
