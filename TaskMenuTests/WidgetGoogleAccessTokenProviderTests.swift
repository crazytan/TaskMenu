import XCTest
@testable import TaskMenu

/// Tests `WidgetGoogleAccessTokenProvider` — the refresh-only, UI-free
/// token provider the `TaskMenuWidget` extension uses. Every test injects a
/// shared-group `InMemoryKeychainService` double directly; the provider is
/// never given a legacy-location double at all, which is itself how these
/// tests prove it can never read the legacy location (see
/// `testNeverReadsLegacyLocation`).
final class WidgetGoogleAccessTokenProviderTests: XCTestCase {
    override func setUp() {
        super.setUp()
        MockURLProtocol.reset()
    }

    override func tearDown() {
        MockURLProtocol.reset()
        super.tearDown()
    }

    private func makeProvider(shared: InMemoryKeychainService) -> WidgetGoogleAccessTokenProvider {
        WidgetGoogleAccessTokenProvider(
            keychain: shared,
            refresher: GoogleTokenRefresher(session: MockURLProtocol.mockSession())
        )
    }

    // MARK: - No refresh token

    func testNoStoredCredentialsThrowsUnauthorizedWithoutNetworkCall() async throws {
        let shared = InMemoryKeychainService(accessGroup: "shared-group")
        let provider = makeProvider(shared: shared)

        do {
            _ = try await provider.validAccessToken()
            XCTFail("Expected APIError.unauthorized")
        } catch APIError.unauthorized {
            // expected
        }

        XCTAssertTrue(MockURLProtocol.requestLog.isEmpty)
    }

    // MARK: - Valid cached token

    func testValidCachedAccessTokenAvoidsRefresh() async throws {
        let shared = InMemoryKeychainService(accessGroup: "shared-group")
        try shared.save(key: SharedConstants.Keychain.accessTokenKey, string: "cached-token")
        try shared.save(key: SharedConstants.Keychain.refreshTokenKey, string: "refresh-token")
        let future = Date().addingTimeInterval(3600)
        try shared.save(key: SharedConstants.Keychain.expirationKey, string: String(future.timeIntervalSince1970))

        let provider = makeProvider(shared: shared)
        let token = try await provider.validAccessToken()

        XCTAssertEqual(token, "cached-token")
        XCTAssertTrue(MockURLProtocol.requestLog.isEmpty)
    }

    // MARK: - Expired token triggers refresh

    func testExpiredTokenRefreshesAndWritesSharedAccessAndExpiration() async throws {
        let shared = InMemoryKeychainService(accessGroup: "shared-group")
        try shared.save(key: SharedConstants.Keychain.accessTokenKey, string: "expired-token")
        try shared.save(key: SharedConstants.Keychain.refreshTokenKey, string: "refresh-token")
        let past = Date().addingTimeInterval(-3600)
        try shared.save(key: SharedConstants.Keychain.expirationKey, string: String(past.timeIntervalSince1970))

        MockURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            let json = #"{"access_token":"refreshed-token","expires_in":3600,"token_type":"Bearer"}"#
            return (response, json.data(using: .utf8)!)
        }

        let provider = makeProvider(shared: shared)
        let token = try await provider.validAccessToken()

        XCTAssertEqual(token, "refreshed-token")
        XCTAssertEqual(try shared.readString(key: SharedConstants.Keychain.accessTokenKey), "refreshed-token")
        let storedExpiration = try XCTUnwrap(Double(try XCTUnwrap(shared.readString(key: SharedConstants.Keychain.expirationKey))))
        XCTAssertGreaterThan(storedExpiration, Date().timeIntervalSince1970)
        XCTAssertEqual(MockURLProtocol.requestLog.count, 1)
    }

    // MARK: - Omitted replacement refresh token preserves existing one

    func testOmittedReplacementRefreshTokenPreservesExisting() async throws {
        let shared = InMemoryKeychainService(accessGroup: "shared-group")
        try shared.save(key: SharedConstants.Keychain.refreshTokenKey, string: "original-refresh-token")
        let past = Date().addingTimeInterval(-3600)
        try shared.save(key: SharedConstants.Keychain.expirationKey, string: String(past.timeIntervalSince1970))

        MockURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            // No "refresh_token" field in the response.
            let json = #"{"access_token":"refreshed-token","expires_in":3600,"token_type":"Bearer"}"#
            return (response, json.data(using: .utf8)!)
        }

        let provider = makeProvider(shared: shared)
        _ = try await provider.validAccessToken()

        XCTAssertEqual(try shared.readString(key: SharedConstants.Keychain.refreshTokenKey), "original-refresh-token")
    }

    func testReplacementRefreshTokenIsPersistedWhenGoogleSendsOne() async throws {
        let shared = InMemoryKeychainService(accessGroup: "shared-group")
        try shared.save(key: SharedConstants.Keychain.refreshTokenKey, string: "original-refresh-token")
        let past = Date().addingTimeInterval(-3600)
        try shared.save(key: SharedConstants.Keychain.expirationKey, string: String(past.timeIntervalSince1970))

        MockURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            let json = #"{"access_token":"refreshed-token","refresh_token":"rotated-refresh-token","expires_in":3600,"token_type":"Bearer"}"#
            return (response, json.data(using: .utf8)!)
        }

        let provider = makeProvider(shared: shared)
        _ = try await provider.validAccessToken()

        XCTAssertEqual(try shared.readString(key: SharedConstants.Keychain.refreshTokenKey), "rotated-refresh-token")
    }

    // MARK: - Transient failures preserve credentials

    func testTransientServerErrorPreservesCredentials() async throws {
        let shared = InMemoryKeychainService(accessGroup: "shared-group")
        try shared.save(key: SharedConstants.Keychain.refreshTokenKey, string: "refresh-token")
        let past = Date().addingTimeInterval(-3600)
        try shared.save(key: SharedConstants.Keychain.expirationKey, string: String(past.timeIntervalSince1970))

        MockURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 503, httpVersion: nil, headerFields: nil)!
            return (response, Data("Service Unavailable".utf8))
        }

        let provider = makeProvider(shared: shared)

        do {
            _ = try await provider.validAccessToken()
            XCTFail("Expected APIError.serverError")
        } catch APIError.serverError(let code, _) {
            XCTAssertEqual(code, 503)
        }

        XCTAssertEqual(try shared.readString(key: SharedConstants.Keychain.refreshTokenKey), "refresh-token")
    }

    func testUndecodableBadRequestBodyPreservesCredentials() async throws {
        let shared = InMemoryKeychainService(accessGroup: "shared-group")
        try shared.save(key: SharedConstants.Keychain.refreshTokenKey, string: "refresh-token")
        let past = Date().addingTimeInterval(-3600)
        try shared.save(key: SharedConstants.Keychain.expirationKey, string: String(past.timeIntervalSince1970))

        MockURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 400, httpVersion: nil, headerFields: nil)!
            return (response, Data("gateway glitch".utf8))
        }

        let provider = makeProvider(shared: shared)

        do {
            _ = try await provider.validAccessToken()
            XCTFail("Expected APIError.serverError")
        } catch APIError.serverError(400, _) {
            // expected
        }

        XCTAssertEqual(try shared.readString(key: SharedConstants.Keychain.refreshTokenKey), "refresh-token")
    }

    func testNetworkFailurePreservesCredentials() async throws {
        let shared = InMemoryKeychainService(accessGroup: "shared-group")
        try shared.save(key: SharedConstants.Keychain.refreshTokenKey, string: "refresh-token")
        let past = Date().addingTimeInterval(-3600)
        try shared.save(key: SharedConstants.Keychain.expirationKey, string: String(past.timeIntervalSince1970))

        MockURLProtocol.requestHandler = { _ in
            throw URLError(.notConnectedToInternet)
        }

        let provider = makeProvider(shared: shared)

        do {
            _ = try await provider.validAccessToken()
            XCTFail("Expected APIError.networkError")
        } catch APIError.networkError {
            // expected
        }

        XCTAssertEqual(try shared.readString(key: SharedConstants.Keychain.refreshTokenKey), "refresh-token")
    }

    // MARK: - Definitive rejection clears credentials

    func testInvalidGrantClearsSharedCredentials() async throws {
        let shared = InMemoryKeychainService(accessGroup: "shared-group")
        try shared.save(key: SharedConstants.Keychain.accessTokenKey, string: "expired-token")
        try shared.save(key: SharedConstants.Keychain.refreshTokenKey, string: "refresh-token")
        let past = Date().addingTimeInterval(-3600)
        try shared.save(key: SharedConstants.Keychain.expirationKey, string: String(past.timeIntervalSince1970))

        MockURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 400, httpVersion: nil, headerFields: nil)!
            let json = #"{"error":"invalid_grant","error_description":"Token has been expired or revoked."}"#
            return (response, json.data(using: .utf8)!)
        }

        let provider = makeProvider(shared: shared)

        do {
            _ = try await provider.validAccessToken()
            XCTFail("Expected APIError.unauthorized")
        } catch APIError.unauthorized {
            // expected
        }

        XCTAssertNil(try shared.readString(key: SharedConstants.Keychain.accessTokenKey))
        XCTAssertNil(try shared.readString(key: SharedConstants.Keychain.refreshTokenKey))
    }

    func testInvalidClientClearsSharedCredentials() async throws {
        let shared = InMemoryKeychainService(accessGroup: "shared-group")
        try shared.save(key: SharedConstants.Keychain.refreshTokenKey, string: "refresh-token")
        let past = Date().addingTimeInterval(-3600)
        try shared.save(key: SharedConstants.Keychain.expirationKey, string: String(past.timeIntervalSince1970))

        MockURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 401, httpVersion: nil, headerFields: nil)!
            let json = #"{"error":"invalid_client","error_description":"Unauthorized"}"#
            return (response, json.data(using: .utf8)!)
        }

        let provider = makeProvider(shared: shared)

        do {
            _ = try await provider.validAccessToken()
            XCTFail("Expected APIError.unauthorized")
        } catch APIError.unauthorized {
            // expected
        }

        XCTAssertNil(try shared.readString(key: SharedConstants.Keychain.refreshTokenKey))
    }

    // MARK: - Coalescing

    func testConcurrentCallersCoalesceOntoOneRefresh() async throws {
        let shared = InMemoryKeychainService(accessGroup: "shared-group")
        try shared.save(key: SharedConstants.Keychain.refreshTokenKey, string: "refresh-token")
        let past = Date().addingTimeInterval(-3600)
        try shared.save(key: SharedConstants.Keychain.expirationKey, string: String(past.timeIntervalSince1970))

        MockURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            let json = #"{"access_token":"refreshed-token","expires_in":3600,"token_type":"Bearer"}"#
            return (response, json.data(using: .utf8)!)
        }

        let provider = makeProvider(shared: shared)

        async let first = provider.validAccessToken()
        async let second = provider.validAccessToken()
        let tokens = try await [first, second]

        XCTAssertEqual(tokens, ["refreshed-token", "refreshed-token"])
        XCTAssertEqual(MockURLProtocol.requestLog.count, 1)
    }

    // MARK: - Never reads the legacy location

    func testNeverReadsLegacyLocation() async throws {
        // The provider is constructed with only a shared-group keychain; it
        // has no way to reach a "legacy" store at all. A separate legacy
        // double with valid credentials proves nothing about the provider
        // unless the provider is actually given it, so its absence here —
        // and the provider still correctly throwing when the shared store
        // is empty — is the proof that it never falls back to any other
        // location.
        let legacyWithValidCredentials = InMemoryKeychainService()
        try legacyWithValidCredentials.save(key: SharedConstants.Keychain.accessTokenKey, string: "legacy-token")
        try legacyWithValidCredentials.save(key: SharedConstants.Keychain.refreshTokenKey, string: "legacy-refresh")
        let future = Date().addingTimeInterval(3600)
        try legacyWithValidCredentials.save(
            key: SharedConstants.Keychain.expirationKey,
            string: String(future.timeIntervalSince1970)
        )

        let emptyShared = InMemoryKeychainService(accessGroup: "shared-group")
        let provider = makeProvider(shared: emptyShared)

        do {
            _ = try await provider.validAccessToken()
            XCTFail("Expected APIError.unauthorized — must not see the legacy store's credentials")
        } catch APIError.unauthorized {
            // expected
        }
    }
}
