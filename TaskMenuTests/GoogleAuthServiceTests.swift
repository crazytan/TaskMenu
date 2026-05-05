import AuthenticationServices
import XCTest
@testable import TaskMenu

@MainActor
final class GoogleAuthServiceTests: XCTestCase {
    nonisolated(unsafe) private static var capturedRequestBody: Data?
    private var keychain: InMemoryKeychainService!

    override func setUp() async throws {
        MockURLProtocol.reset()
        Self.capturedRequestBody = nil
        keychain = InMemoryKeychainService()
    }

    override func tearDown() async throws {
        MockURLProtocol.reset()
        Self.capturedRequestBody = nil
        try? keychain.deleteAll()
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

    func testLoadTokensClearsAllOnKeychainError() {
        let failingKeychain = FailingKeychainService()
        let auth = GoogleAuthService(keychain: failingKeychain)
        XCTAssertNil(auth.accessToken)
        XCTAssertNil(auth.refreshToken)
        XCTAssertNil(auth.tokenExpiration)
        XCTAssertFalse(auth.isSignedIn)
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

    // MARK: - OAuth Callback Parsing

    func testOAuthCallbackParserReturnsCodeWhenStateMatches() throws {
        let callbackURL = URL(string: "\(Constants.googleRedirectScheme):\(Constants.googleRedirectPath)?code=auth-code-value&state=expected-state")!

        let code = try OAuthCallbackParser.authorizationCode(
            from: callbackURL,
            expectedState: "expected-state",
            expectedScheme: Constants.googleRedirectScheme
        )

        XCTAssertEqual(code, "auth-code-value")
    }

    func testOAuthCallbackParserRejectsMismatchedState() {
        let callbackURL = URL(string: "\(Constants.googleRedirectScheme):\(Constants.googleRedirectPath)?code=auth-code-value&state=unexpected-state")!

        XCTAssertThrowsError(
            try OAuthCallbackParser.authorizationCode(
                from: callbackURL,
                expectedState: "expected-state",
                expectedScheme: Constants.googleRedirectScheme
            )
        ) { error in
            guard case GoogleAuthError.invalidState = error else {
                XCTFail("Expected GoogleAuthError.invalidState, got \(error)")
                return
            }
        }
    }

    func testOAuthCallbackParserReportsAuthorizationErrors() {
        let callbackURL = URL(string: "\(Constants.googleRedirectScheme):\(Constants.googleRedirectPath)?error=access_denied&state=expected-state")!

        XCTAssertThrowsError(
            try OAuthCallbackParser.authorizationCode(
                from: callbackURL,
                expectedState: "expected-state",
                expectedScheme: Constants.googleRedirectScheme
            )
        ) { error in
            guard case GoogleAuthError.authorizationFailed("access_denied") = error else {
                XCTFail("Expected GoogleAuthError.authorizationFailed, got \(error)")
                return
            }
        }
    }

    func testOAuthCallbackParserRejectsMissingCode() {
        let callbackURL = URL(string: "\(Constants.googleRedirectScheme):\(Constants.googleRedirectPath)?state=expected-state")!

        XCTAssertThrowsError(
            try OAuthCallbackParser.authorizationCode(
                from: callbackURL,
                expectedState: "expected-state",
                expectedScheme: Constants.googleRedirectScheme
            )
        ) { error in
            guard case GoogleAuthError.invalidCallback = error else {
                XCTFail("Expected GoogleAuthError.invalidCallback, got \(error)")
                return
            }
        }
    }

    func testOAuthCallbackParserRejectsUnexpectedScheme() {
        let callbackURL = URL(string: "unexpected.scheme:\(Constants.googleRedirectPath)?code=auth-code-value&state=expected-state")!

        XCTAssertThrowsError(
            try OAuthCallbackParser.authorizationCode(
                from: callbackURL,
                expectedState: "expected-state",
                expectedScheme: Constants.googleRedirectScheme
            )
        ) { error in
            guard case GoogleAuthError.invalidCallback = error else {
                XCTFail("Expected GoogleAuthError.invalidCallback, got \(error)")
                return
            }
        }
    }

    func testOAuthCallbackParserRejectsUnexpectedPath() {
        let callbackURL = URL(string: "\(Constants.googleRedirectScheme):/wrong-path?code=auth-code-value&state=expected-state")!

        XCTAssertThrowsError(
            try OAuthCallbackParser.authorizationCode(
                from: callbackURL,
                expectedState: "expected-state",
                expectedScheme: Constants.googleRedirectScheme
            )
        ) { error in
            guard case GoogleAuthError.invalidCallback = error else {
                XCTFail("Expected GoogleAuthError.invalidCallback, got \(error)")
                return
            }
        }
    }

    // MARK: - Sign In

    func testSignInUsesWebAuthCallbackAndPublicClientTokenExchange() async throws {
        let webAuthenticator = MockWebAuthenticator { authURL, callbackScheme in
            let state = try XCTUnwrap(queryItem("state", in: authURL))
            return URL(string: "\(callbackScheme):\(Constants.googleRedirectPath)?code=auth-code-value&state=\(state)")!
        }
        let session = MockURLProtocol.mockSession()
        MockURLProtocol.requestHandler = { request in
            Self.capturedRequestBody = requestBodyData(from: request)
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            let json = #"{"access_token":"new-access-token","refresh_token":"new-refresh-token","expires_in":3600,"token_type":"Bearer"}"#
            return (response, json.data(using: .utf8)!)
        }

        let auth = GoogleAuthService(keychain: keychain, session: session, webAuthenticator: webAuthenticator)
        try await auth.signIn()

        let authURL = try XCTUnwrap(webAuthenticator.requestedURL)
        XCTAssertEqual(webAuthenticator.requestedCallbackScheme, Constants.googleRedirectScheme)
        XCTAssertEqual(queryItem("client_id", in: authURL), Constants.googleClientId)
        XCTAssertEqual(queryItem("redirect_uri", in: authURL), Constants.googleRedirectURI)
        XCTAssertEqual(queryItem("response_type", in: authURL), "code")
        XCTAssertEqual(queryItem("scope", in: authURL), Constants.googleTasksScope)
        XCTAssertEqual(queryItem("code_challenge_method", in: authURL), "S256")
        XCTAssertEqual(queryItem("access_type", in: authURL), "offline")
        XCTAssertEqual(queryItem("prompt", in: authURL), "consent")
        XCTAssertNotNil(queryItem("state", in: authURL))
        XCTAssertNotNil(queryItem("code_challenge", in: authURL))

        XCTAssertEqual(auth.accessToken, "new-access-token")
        XCTAssertEqual(auth.refreshToken, "new-refresh-token")
        XCTAssertFalse(auth.isTokenExpired)

        let tokenRequest = try XCTUnwrap(MockURLProtocol.requestLog.last)
        XCTAssertEqual(tokenRequest.url?.absoluteString, Constants.googleTokenURL)
        let body = formParameters(from: try XCTUnwrap(Self.capturedRequestBody))
        XCTAssertEqual(body["code"], "auth-code-value")
        XCTAssertEqual(body["client_id"], Constants.googleClientId)
        XCTAssertEqual(body["grant_type"], "authorization_code")
        XCTAssertEqual(body["redirect_uri"], Constants.googleRedirectURI)
        XCTAssertNotNil(body["code_verifier"])
        XCTAssertNil(body["client_secret"])
    }

    func testDisconnectRevokesRefreshTokenBeforeClearingTokens() async throws {
        try keychain.save(key: Constants.Keychain.accessTokenKey, string: "access-token")
        try keychain.save(key: Constants.Keychain.refreshTokenKey, string: "refresh-token")

        let session = MockURLProtocol.mockSession()
        MockURLProtocol.requestHandler = { request in
            Self.capturedRequestBody = requestBodyData(from: request)
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, Data())
        }

        let auth = GoogleAuthService(keychain: keychain, session: session)
        await auth.disconnect()

        XCTAssertFalse(auth.isSignedIn)
        XCTAssertNil(auth.accessToken)
        XCTAssertNil(auth.refreshToken)
        XCTAssertNil(try keychain.readString(key: Constants.Keychain.accessTokenKey))
        XCTAssertNil(try keychain.readString(key: Constants.Keychain.refreshTokenKey))

        let revokeRequest = try XCTUnwrap(MockURLProtocol.requestLog.last)
        XCTAssertEqual(revokeRequest.url?.absoluteString, Constants.googleRevocationURL)
        let body = formParameters(from: try XCTUnwrap(Self.capturedRequestBody))
        XCTAssertEqual(body["token"], "refresh-token")
    }
}

@MainActor
private final class MockWebAuthenticator: WebAuthenticating {
    typealias CallbackFactory = @MainActor (URL, String) throws -> URL

    private let callbackFactory: CallbackFactory
    private(set) var requestedURL: URL?
    private(set) var requestedCallbackScheme: String?

    init(callbackFactory: @escaping CallbackFactory) {
        self.callbackFactory = callbackFactory
    }

    func authenticate(
        url: URL,
        callbackScheme: String,
        presentationContextProvider: any ASWebAuthenticationPresentationContextProviding
    ) async throws -> URL {
        requestedURL = url
        requestedCallbackScheme = callbackScheme
        return try callbackFactory(url, callbackScheme)
    }
}

private func queryItem(_ name: String, in url: URL) -> String? {
    URLComponents(url: url, resolvingAgainstBaseURL: false)?
        .queryItems?
        .first(where: { $0.name == name })?
        .value
}

private func formParameters(from body: Data) -> [String: String] {
    guard let bodyString = String(data: body, encoding: .utf8),
          let components = URLComponents(string: "?\(bodyString)") else {
        return [:]
    }

    var params: [String: String] = [:]
    for item in components.queryItems ?? [] {
        params[item.name] = item.value
    }
    return params
}

private func requestBodyData(from request: URLRequest) -> Data? {
    if let httpBody = request.httpBody {
        return httpBody
    }

    guard let stream = request.httpBodyStream else { return nil }
    stream.open()
    defer { stream.close() }

    var data = Data()
    var buffer = [UInt8](repeating: 0, count: 1024)
    while stream.hasBytesAvailable {
        let count = stream.read(&buffer, maxLength: buffer.count)
        guard count > 0 else { break }
        data.append(buffer, count: count)
    }
    return data.isEmpty ? nil : data
}
