import Foundation

/// Extension-safe (Foundation only) refresh-token request building and
/// response/error policy shared by `GoogleAuthService` (app) and
/// `WidgetGoogleAccessTokenProvider` (extension), so the "definitive
/// rejection" rule lives in exactly one place:
///
/// - `invalid_grant` / `invalid_client` on HTTP 400/401 is a **definitive
///   rejection** — callers must clear stored credentials.
/// - Anything else (429, 5xx, undecodable body, network failure) is
///   **transient** — callers must preserve stored credentials and may retry
///   later.
enum GoogleTokenRefresherError: Error, Sendable {
    /// Google definitively rejected the refresh token. Callers must clear
    /// stored credentials.
    case definitiveRejection
    /// Transient failure. Callers must preserve stored credentials.
    case transient(APIError)
}

/// The result of a successful refresh.
struct GoogleTokenRefresherResult: Sendable, Equatable {
    let accessToken: String
    /// `nil` when Google's response omitted a replacement refresh token;
    /// callers must retain their existing refresh token in that case.
    let refreshToken: String?
    let expiration: Date
}

struct GoogleTokenRefresher: Sendable {
    private let session: URLSession
    private let tokenURL: String
    private let clientId: String

    init(
        session: URLSession = .shared,
        tokenURL: String = SharedConstants.googleTokenURL,
        clientId: String = SharedConstants.googleClientId
    ) {
        self.session = session
        self.tokenURL = tokenURL
        self.clientId = clientId
    }

    /// Exchanges `refreshToken` for a fresh access token.
    ///
    /// - Throws: `GoogleTokenRefresherError.definitiveRejection` when Google
    ///   rejects the refresh token outright, or
    ///   `GoogleTokenRefresherError.transient` for everything else
    ///   (network/decoding/server failures) that must not destroy stored
    ///   credentials.
    func refresh(refreshToken: String) async throws -> GoogleTokenRefresherResult {
        guard let url = URL(string: tokenURL) else {
            throw GoogleTokenRefresherError.transient(.networkError(URLError(.badURL)))
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        let params = [
            "refresh_token": refreshToken,
            "client_id": clientId,
            "grant_type": "refresh_token",
        ]
        request.httpBody = params.formURLEncoded().data(using: .utf8)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError {
            throw GoogleTokenRefresherError.transient(.networkError(error))
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw GoogleTokenRefresherError.transient(.networkError(URLError(.badServerResponse)))
        }

        if httpResponse.statusCode != 200 {
            if Self.isDefinitiveRejection(statusCode: httpResponse.statusCode, data: data) {
                throw GoogleTokenRefresherError.definitiveRejection
            }
            throw GoogleTokenRefresherError.transient(
                .serverError(httpResponse.statusCode, String(data: data, encoding: .utf8))
            )
        }

        let decoded: RefreshTokenResponse
        do {
            decoded = try JSONDecoder().decode(RefreshTokenResponse.self, from: data)
        } catch {
            throw GoogleTokenRefresherError.transient(.decodingError(error))
        }

        return GoogleTokenRefresherResult(
            accessToken: decoded.accessToken,
            refreshToken: decoded.refreshToken,
            expiration: Date().addingTimeInterval(TimeInterval(decoded.expiresIn))
        )
    }

    /// Only 400/401 responses whose body decodes to Google's `invalid_grant`
    /// or `invalid_client` OAuth error are definitive; everything else
    /// (including an undecodable 400/401 body) is treated as transient so a
    /// flaky proxy or gateway cannot destroy a valid refresh token.
    static func isDefinitiveRejection(statusCode: Int, data: Data) -> Bool {
        guard statusCode == 400 || statusCode == 401 else { return false }
        guard let tokenError = try? JSONDecoder().decode(RefreshTokenErrorResponse.self, from: data) else {
            return false
        }
        return tokenError.error == "invalid_grant" || tokenError.error == "invalid_client"
    }
}

private struct RefreshTokenResponse: Codable {
    let accessToken: String
    let refreshToken: String?
    let expiresIn: Int

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case expiresIn = "expires_in"
    }
}

private struct RefreshTokenErrorResponse: Codable {
    let error: String
}

private extension Dictionary where Key == String, Value == String {
    func formURLEncoded() -> String {
        map { key, value in
            let escapedKey = key.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? key
            let escapedValue = value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? value
            return "\(escapedKey)=\(escapedValue)"
        }.joined(separator: "&")
    }
}
