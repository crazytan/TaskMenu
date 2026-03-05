import AuthenticationServices
import CryptoKit
import Foundation

@MainActor
final class GoogleAuthService: Sendable {
    private let keychain: KeychainService
    private let session: URLSession

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

    init(keychain: KeychainService = KeychainService(), session: URLSession = .shared) {
        self.keychain = keychain
        self.session = session
        loadTokens()
    }

    // MARK: - Sign In

    func signIn() async throws {
        let codeVerifier = generateCodeVerifier()
        let codeChallenge = generateCodeChallenge(from: codeVerifier)
        let port = findAvailablePort()
        let redirectURI = "http://\(Constants.redirectHost):\(port)/callback"

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
        ]

        let authCode = try await startLocalServerAndAuth(
            url: components.url!,
            port: UInt16(port),
            redirectURI: redirectURI
        )

        try await exchangeCodeForTokens(
            code: authCode,
            codeVerifier: codeVerifier,
            redirectURI: redirectURI
        )
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

        let (data, _) = try await session.data(for: request)
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

    private func saveTokens() {
        try? keychain.save(key: Constants.Keychain.accessTokenKey, string: accessToken ?? "")
        if let refreshToken {
            try? keychain.save(key: Constants.Keychain.refreshTokenKey, string: refreshToken)
        }
        if let expiration = tokenExpiration {
            let data = String(expiration.timeIntervalSince1970)
            try? keychain.save(key: Constants.Keychain.expirationKey, string: data)
        }
    }

    private func loadTokens() {
        accessToken = try? keychain.readString(key: Constants.Keychain.accessTokenKey)
        refreshToken = try? keychain.readString(key: Constants.Keychain.refreshTokenKey)
        if let expStr = try? keychain.readString(key: Constants.Keychain.expirationKey),
           let interval = Double(expStr) {
            tokenExpiration = Date(timeIntervalSince1970: interval)
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

    // MARK: - Local Server for OAuth Callback

    private nonisolated func findAvailablePort() -> Int {
        // Use a random port in the ephemeral range
        Int.random(in: 49152...65535)
    }

    private func startLocalServerAndAuth(url: URL, port: UInt16, redirectURI: String) async throws -> String {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String, Error>) in
            let serverSocket = createLocalServer(port: port) { queryString in
                if let code = URLComponents(string: "?\(queryString)")?.queryItems?.first(where: { $0.name == "code" })?.value {
                    continuation.resume(returning: code)
                } else {
                    continuation.resume(throwing: APIError.unauthorized)
                }
            }

            guard serverSocket != nil else {
                continuation.resume(throwing: APIError.networkError(URLError(.cannotConnectToHost)))
                return
            }

            NSWorkspace.shared.open(url)
        }
    }

    private nonisolated func createLocalServer(port: UInt16, completion: @escaping @Sendable (String) -> Void) -> CFSocket? {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }

        var reuse: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")

        let bindResult = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }

        guard bindResult == 0 else {
            close(fd)
            return nil
        }

        listen(fd, 1)

        DispatchQueue.global(qos: .userInitiated).async {
            let clientFd = accept(fd, nil, nil)
            guard clientFd >= 0 else {
                close(fd)
                return
            }

            var buffer = [UInt8](repeating: 0, count: 4096)
            let bytesRead = read(clientFd, &buffer, buffer.count)

            if bytesRead > 0 {
                let request = String(bytes: buffer[0..<bytesRead], encoding: .utf8) ?? ""
                // Parse GET /callback?code=...
                if let firstLine = request.split(separator: "\r\n").first,
                   let path = firstLine.split(separator: " ").dropFirst().first,
                   let queryStart = path.firstIndex(of: "?") {
                    let query = String(path[path.index(after: queryStart)...])

                    let successHTML = """
                    HTTP/1.1 200 OK\r\nContent-Type: text/html\r\n\r\n\
                    <html><body style="font-family:-apple-system;text-align:center;padding:60px">\
                    <h2>Signed in to TaskMenu!</h2><p>You can close this tab.</p></body></html>
                    """
                    _ = successHTML.withCString { ptr in
                        write(clientFd, ptr, strlen(ptr))
                    }

                    close(clientFd)
                    close(fd)
                    completion(query)
                    return
                }
            }

            let errorHTML = "HTTP/1.1 400 Bad Request\r\n\r\nError"
            _ = errorHTML.withCString { ptr in
                write(clientFd, ptr, strlen(ptr))
            }
            close(clientFd)
            close(fd)
        }

        return nil // We manage the fd manually
    }
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
