import Foundation

/// Constants safe to compile into the `TaskMenuWidget` extension target as
/// well as the main app: no AppKit, no OAuth browser flow, nothing that
/// pulls in app-only services. `Constants` (app-only) forwards to these
/// members so existing call sites and tests are unaffected.
enum SharedConstants {
    static let googleClientId: String = {
        guard let id = Bundle.main.object(forInfoDictionaryKey: "GOOGLE_CLIENT_ID") as? String, !id.isEmpty else {
            fatalError("GOOGLE_CLIENT_ID not set. Copy Config.xcconfig.example to Config.xcconfig and add your credentials.")
        }
        return id
    }()
    static let googleTokenURL = "https://oauth2.googleapis.com/token"
    static let googleTasksBaseURL = "https://tasks.googleapis.com/tasks/v1"
    static let googleTasksScope = "https://www.googleapis.com/auth/tasks"

    enum Keychain {
        static let service = "dev.crazytan.TaskMenu.oauth"
        static let accessTokenKey = "access_token"
        static let refreshTokenKey = "refresh_token"
        static let expirationKey = "token_expiration"
        static let accountProfileKey = "account_profile"
    }

    /// Resolved App Group container id (`$(DEVELOPMENT_TEAM).group.dev.crazytan.TaskMenu.shared`),
    /// or `nil` when the bundle has no App Group entitlement (unsigned
    /// development builds, or a target whose Info.plist omits the key).
    /// `Bundle.main` here is the extension's own bundle when this code runs
    /// inside `TaskMenuWidget`.
    static var appGroupIdentifier: String? {
        resolvedInfoPlistString(forKey: "APP_GROUP_IDENTIFIER")
    }

    /// Resolved shared Keychain access group
    /// (`$(DEVELOPMENT_TEAM).dev.crazytan.TaskMenu.shared`), or `nil` when
    /// unresolved/unsigned. See `appGroupIdentifier`.
    static var keychainAccessGroup: String? {
        resolvedInfoPlistString(forKey: "KEYCHAIN_ACCESS_GROUP")
    }

    /// Treats a missing, empty, or unexpanded (`$(...)`) build-setting value
    /// as absent rather than a literal string, since unsigned CI/dev builds
    /// resolve `$(DEVELOPMENT_TEAM)` to an empty prefix or leave the
    /// placeholder unexpanded depending on the build setting.
    private static func resolvedInfoPlistString(forKey key: String) -> String? {
        guard let value = Bundle.main.object(forInfoDictionaryKey: key) as? String,
              !value.isEmpty,
              !value.hasPrefix("$("),
              !value.hasPrefix(".") // empty $(DEVELOPMENT_TEAM) leaves a leading "."
        else {
            return nil
        }
        return value
    }
}
