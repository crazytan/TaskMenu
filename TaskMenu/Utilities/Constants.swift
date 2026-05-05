import Foundation

enum Constants {
    static let googleClientId: String = {
        guard let id = Bundle.main.object(forInfoDictionaryKey: "GOOGLE_CLIENT_ID") as? String, !id.isEmpty else {
            fatalError("GOOGLE_CLIENT_ID not set. Copy Config.xcconfig.example to Config.xcconfig and add your credentials.")
        }
        return id
    }()
    static let googleRedirectScheme: String = {
        if let scheme = Bundle.main.object(forInfoDictionaryKey: "GOOGLE_REDIRECT_SCHEME") as? String,
           !scheme.isEmpty,
           !scheme.hasPrefix("$(") {
            return scheme
        }

        let suffix = ".apps.googleusercontent.com"
        guard googleClientId.hasSuffix(suffix) else {
            fatalError("GOOGLE_REDIRECT_SCHEME not set. Add it to Config.xcconfig or use a Google OAuth client ID ending in .apps.googleusercontent.com.")
        }
        return "com.googleusercontent.apps.\(googleClientId.dropLast(suffix.count))"
    }()
    static let googleAuthURL = "https://accounts.google.com/o/oauth2/v2/auth"
    static let googleTokenURL = "https://oauth2.googleapis.com/token"
    static let googleRevocationURL = "https://oauth2.googleapis.com/revoke"
    static let googleTasksBaseURL = "https://tasks.googleapis.com/tasks/v1"
    static let googleTasksScope = "https://www.googleapis.com/auth/tasks"
    static let googleRedirectPath = "/oauth2redirect"
    static let googleRedirectURI = "\(googleRedirectScheme):\(googleRedirectPath)"

    enum Keychain {
        static let service = "dev.crazytan.TaskMenu.oauth"
        static let accessTokenKey = "access_token"
        static let refreshTokenKey = "refresh_token"
        static let expirationKey = "token_expiration"
    }

    enum UserDefaults {
        static let dueDateNotificationsEnabledKey = "dueDateNotificationsEnabled"
        static let experimentalFullWindowLiquidGlassEnabledKey = "experimentalFullWindowLiquidGlassEnabled"
    }

    enum Notifications {
        static let dueDateIdentifierPrefix = "dev.crazytan.TaskMenu.dueDate"
    }
}
