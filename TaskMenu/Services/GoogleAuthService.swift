import AppKit
import AuthenticationServices
import CryptoKit
import Foundation
import os.log

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "TaskMenu", category: "Auth")

enum GoogleAuthError: LocalizedError, Sendable {
    case authorizationFailed(String)
    case canceled
    case invalidCallback
    case invalidState
    case unableToStartAuthenticationSession

    var errorDescription: String? {
        switch self {
        case .authorizationFailed(let message):
            return "Authorization failed: \(message)"
        case .canceled:
            return "Sign in was canceled."
        case .invalidCallback:
            return "Google returned an invalid sign-in response."
        case .invalidState:
            return "Google returned a sign-in response that did not match this session."
        case .unableToStartAuthenticationSession:
            return "Unable to start the Google sign-in session."
        }
    }
}

enum OAuthCallbackParser {
    static func authorizationCode(
        from callbackURL: URL,
        expectedState: String,
        expectedScheme: String,
        expectedPath: String = Constants.googleRedirectPath
    ) throws -> String {
        guard callbackURL.scheme?.lowercased() == expectedScheme.lowercased(),
              callbackURL.path == expectedPath,
              let components = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false) else {
            throw GoogleAuthError.invalidCallback
        }

        let queryItems = responseQueryItems(from: components)
        guard queryItems.first(where: { $0.name == "state" })?.value == expectedState else {
            throw GoogleAuthError.invalidState
        }

        if let error = queryItems.first(where: { $0.name == "error" })?.value {
            throw GoogleAuthError.authorizationFailed(error)
        }

        guard let code = queryItems.first(where: { $0.name == "code" })?.value, !code.isEmpty else {
            throw GoogleAuthError.invalidCallback
        }

        return code
    }

    private static func responseQueryItems(from components: URLComponents) -> [URLQueryItem] {
        if let queryItems = components.queryItems, !queryItems.isEmpty {
            return queryItems
        }

        guard let fragment = components.fragment,
              let fragmentComponents = URLComponents(string: "?\(fragment)") else {
            return []
        }
        return fragmentComponents.queryItems ?? []
    }
}

@MainActor
protocol WebAuthenticating: AnyObject {
    func authenticate(
        url: URL,
        callbackScheme: String,
        presentationContextProvider: any ASWebAuthenticationPresentationContextProviding
    ) async throws -> URL
}

@MainActor
final class ASWebAuthenticationSessionAuthenticator: WebAuthenticating {
    private var webAuthSession: ASWebAuthenticationSession?

    func authenticate(
        url: URL,
        callbackScheme: String,
        presentationContextProvider: any ASWebAuthenticationPresentationContextProviding
    ) async throws -> URL {
        finishAuthenticationSession()

        return try await withCheckedThrowingContinuation { continuation in
            let session = ASWebAuthenticationSession(
                url: url,
                callback: .customScheme(callbackScheme)
            ) { [weak self] callbackURL, error in
                Task { @MainActor in
                    self?.webAuthSession = nil
                }

                if let error {
                    continuation.resume(throwing: webAuthenticationError(from: error))
                    return
                }

                guard let callbackURL else {
                    continuation.resume(throwing: GoogleAuthError.invalidCallback)
                    return
                }

                continuation.resume(returning: callbackURL)
            }
            session.presentationContextProvider = presentationContextProvider
            session.prefersEphemeralWebBrowserSession = false

            webAuthSession = session

            guard session.start() else {
                webAuthSession = nil
                continuation.resume(throwing: GoogleAuthError.unableToStartAuthenticationSession)
                return
            }
        }
    }

    private func finishAuthenticationSession() {
        webAuthSession?.cancel()
        webAuthSession = nil
    }
}

@MainActor
final class GoogleAuthService: Sendable {
    private let keychain: any KeychainServiceProtocol
    private let session: URLSession
    private let webAuthenticator: any WebAuthenticating
    private let presentationContextProvider = AuthenticationPresentationContextProvider()

    private(set) var accessToken: String?
    private(set) var refreshToken: String?
    private(set) var tokenExpiration: Date?

    var isSignedIn: Bool {
        refreshToken != nil
    }

    var isTokenExpired: Bool {
        guard let expiration = tokenExpiration else { return true }
        return Date() >= expiration
    }

    init(
        keychain: any KeychainServiceProtocol = KeychainService(),
        session: URLSession = .shared,
        webAuthenticator: (any WebAuthenticating)? = nil
    ) {
        self.keychain = keychain
        self.session = session
        self.webAuthenticator = webAuthenticator ?? ASWebAuthenticationSessionAuthenticator()
        loadTokens()
    }

    // MARK: - Sign In

    func signIn() async throws {
        let codeVerifier = generateCodeVerifier()
        let codeChallenge = generateCodeChallenge(from: codeVerifier)
        let state = generateState()
        let redirectScheme = Constants.googleRedirectScheme
        let redirectURI = Constants.googleRedirectURI

        var components = URLComponents(string: Constants.googleAuthURL)!
        components.queryItems = [
            URLQueryItem(name: "client_id", value: Constants.googleClientId),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: Constants.googleTasksScope),
            URLQueryItem(name: "code_challenge", value: codeChallenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "access_type", value: "offline"),
            URLQueryItem(name: "prompt", value: "consent"),
            URLQueryItem(name: "state", value: state),
        ]

        guard let authURL = components.url else {
            throw GoogleAuthError.invalidCallback
        }

        let callbackURL = try await webAuthenticator.authenticate(
            url: authURL,
            callbackScheme: redirectScheme,
            presentationContextProvider: presentationContextProvider
        )
        let authCode = try OAuthCallbackParser.authorizationCode(
            from: callbackURL,
            expectedState: state,
            expectedScheme: redirectScheme
        )

        try await exchangeCodeForTokens(
            code: authCode,
            codeVerifier: codeVerifier,
            redirectURI: redirectURI
        )
    }

    func disconnect() async {
        let tokenToRevoke = refreshToken ?? accessToken
        if let tokenToRevoke {
            do {
                try await revokeToken(tokenToRevoke)
            } catch {
                logger.error("Failed to revoke Google OAuth token: \(error.localizedDescription)")
            }
        }
        signOut()
    }

    func signOut() {
        accessToken = nil
        refreshToken = nil
        tokenExpiration = nil
        try? keychain.deleteAll()
    }

    // MARK: - Token Management

    func validAccessToken() async throws -> String {
        if let token = accessToken, !isTokenExpired {
            return token
        }

        guard let refresh = refreshToken else {
            throw APIError.unauthorized
        }

        try await refreshAccessToken(refreshToken: refresh)

        guard let token = accessToken else {
            throw APIError.unauthorized
        }
        return token
    }

    // MARK: - Private

    private func exchangeCodeForTokens(code: String, codeVerifier: String, redirectURI: String) async throws {
        var request = URLRequest(url: URL(string: Constants.googleTokenURL)!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        let params = [
            "code": code,
            "client_id": Constants.googleClientId,
            "code_verifier": codeVerifier,
            "grant_type": "authorization_code",
            "redirect_uri": redirectURI,
        ]
        request.httpBody = params.urlEncodedString().data(using: .utf8)

        let (data, response) = try await session.data(for: request)
        try validateTokenResponse(response)
        let tokenResponse = try JSONDecoder().decode(TokenResponse.self, from: data)

        accessToken = tokenResponse.accessToken
        refreshToken = tokenResponse.refreshToken ?? refreshToken
        tokenExpiration = Date().addingTimeInterval(TimeInterval(tokenResponse.expiresIn))
        saveTokens()
    }

    private func refreshAccessToken(refreshToken: String) async throws {
        var request = URLRequest(url: URL(string: Constants.googleTokenURL)!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        let params = [
            "refresh_token": refreshToken,
            "client_id": Constants.googleClientId,
            "grant_type": "refresh_token",
        ]
        request.httpBody = params.urlEncodedString().data(using: .utf8)

        let (data, response) = try await session.data(for: request)

        if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode != 200 {
            signOut()
            throw APIError.unauthorized
        }

        let tokenResponse = try JSONDecoder().decode(TokenResponse.self, from: data)
        accessToken = tokenResponse.accessToken
        tokenExpiration = Date().addingTimeInterval(TimeInterval(tokenResponse.expiresIn))
        saveTokens()
    }

    private func revokeToken(_ token: String) async throws {
        var request = URLRequest(url: URL(string: Constants.googleRevocationURL)!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = ["token": token].urlEncodedString().data(using: .utf8)

        let (_, response) = try await session.data(for: request)
        if let httpResponse = response as? HTTPURLResponse, !(200..<300).contains(httpResponse.statusCode) {
            throw APIError.unauthorized
        }
    }

    private func validateTokenResponse(_ response: URLResponse) throws {
        guard let httpResponse = response as? HTTPURLResponse else { return }
        guard httpResponse.statusCode == 200 else {
            throw APIError.unauthorized
        }
    }

    private func saveTokens() {
        do {
            try keychain.save(key: Constants.Keychain.accessTokenKey, string: accessToken ?? "")
            if let refreshToken {
                try keychain.save(key: Constants.Keychain.refreshTokenKey, string: refreshToken)
            }
            if let expiration = tokenExpiration {
                try keychain.save(key: Constants.Keychain.expirationKey, string: String(expiration.timeIntervalSince1970))
            }
        } catch {
            logger.error("Failed to save tokens to keychain: \(error.localizedDescription)")
        }
    }

    private func loadTokens() {
        do {
            accessToken = try keychain.readString(key: Constants.Keychain.accessTokenKey)
            refreshToken = try keychain.readString(key: Constants.Keychain.refreshTokenKey)
            if let expStr = try keychain.readString(key: Constants.Keychain.expirationKey),
               let interval = Double(expStr) {
                tokenExpiration = Date(timeIntervalSince1970: interval)
            }
        } catch {
            logger.error("Failed to load tokens from keychain: \(error.localizedDescription)")
            accessToken = nil
            refreshToken = nil
            tokenExpiration = nil
        }
    }

    // MARK: - PKCE

    private func generateCodeVerifier() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes).base64URLEncoded()
    }

    private func generateCodeChallenge(from verifier: String) -> String {
        let data = Data(verifier.utf8)
        let hash = SHA256.hash(data: data)
        return Data(hash).base64URLEncoded()
    }

    private func generateState() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes).base64URLEncoded()
    }
}

@MainActor
private final class AuthenticationPresentationContextProvider: NSObject, ASWebAuthenticationPresentationContextProviding {
    private var fallbackWindow: NSWindow?

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        if let window = NSApp.keyWindow ?? NSApp.mainWindow ?? NSApp.windows.first(where: { $0.isVisible }) {
            return window
        }

        if let fallbackWindow {
            return fallbackWindow
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1, height: 1),
            styleMask: [],
            backing: .buffered,
            defer: false
        )
        fallbackWindow = window
        return window
    }
}

private func webAuthenticationError(from error: Error) -> Error {
    let nsError = error as NSError
    if nsError.domain == ASWebAuthenticationSessionError.errorDomain,
       nsError.code == ASWebAuthenticationSessionError.Code.canceledLogin.rawValue {
        return GoogleAuthError.canceled
    }
    return error
}

// MARK: - Token Response

private struct TokenResponse: Codable {
    let accessToken: String
    let refreshToken: String?
    let expiresIn: Int
    let tokenType: String?

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case expiresIn = "expires_in"
        case tokenType = "token_type"
    }
}

// MARK: - Helpers

private extension Dictionary where Key == String, Value == String {
    func urlEncodedString() -> String {
        map { key, value in
            let escapedKey = key.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? key
            let escapedValue = value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? value
            return "\(escapedKey)=\(escapedValue)"
        }.joined(separator: "&")
    }
}

private extension Data {
    func base64URLEncoded() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
