import Foundation

enum Constants {
    static let googleClientId = "YOUR_CLIENT_ID.apps.googleusercontent.com"
    static let googleAuthURL = "https://accounts.google.com/o/oauth2/v2/auth"
    static let googleTokenURL = "https://oauth2.googleapis.com/token"
    static let googleTasksBaseURL = "https://tasks.googleapis.com/tasks/v1"
    static let googleTasksScope = "https://www.googleapis.com/auth/tasks"
    static let redirectHost = "127.0.0.1"

    enum Keychain {
        static let service = "com.taskmenu.oauth"
        static let accessTokenKey = "access_token"
        static let refreshTokenKey = "refresh_token"
        static let expirationKey = "token_expiration"
    }
}
