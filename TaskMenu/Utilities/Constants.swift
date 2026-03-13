import Foundation

enum Constants {
    static let googleClientId: String = {
        guard let id = Bundle.main.object(forInfoDictionaryKey: "GOOGLE_CLIENT_ID") as? String, !id.isEmpty else {
            fatalError("GOOGLE_CLIENT_ID not set. Copy Config.xcconfig.example to Config.xcconfig and add your credentials.")
        }
        return id
    }()
    static let googleClientSecret: String = {
        guard let secret = Bundle.main.object(forInfoDictionaryKey: "GOOGLE_CLIENT_SECRET") as? String, !secret.isEmpty else {
            fatalError("GOOGLE_CLIENT_SECRET not set. Copy Config.xcconfig.example to Config.xcconfig and add your credentials.")
        }
        return secret
    }()
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

    enum UserDefaults {
        static let dueDateNotificationsEnabledKey = "dueDateNotificationsEnabled"
    }

    enum Notifications {
        static let dueDateIdentifierPrefix = "com.taskmenu.dueDate"
    }
}
