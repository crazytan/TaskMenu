import Foundation

enum Constants {
    /// Forwards to `SharedConstants`, which is extension-safe and shared
    /// with `TaskMenuWidget`. Kept here so existing call sites and tests
    /// referencing `Constants.googleClientId` are unaffected.
    static let googleClientId = SharedConstants.googleClientId
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
    static let googleTokenURL = SharedConstants.googleTokenURL
    static let googleRevocationURL = "https://oauth2.googleapis.com/revoke"
    static let googleUserInfoURL = "https://openidconnect.googleapis.com/v1/userinfo"
    static let googleTasksBaseURL = SharedConstants.googleTasksBaseURL
    // Guideline 2.4.5(vii): not compiled into Mac App Store builds.
    #if !APP_STORE_BUILD
    static let githubLatestReleaseURL = "https://api.github.com/repos/crazytan/TaskMenu/releases/latest"
    #endif
    static let googleTasksScope = SharedConstants.googleTasksScope
    static let googleAuthScopes = [
        "openid",
        "email",
        googleTasksScope,
    ].joined(separator: " ")
    static let googleRedirectPath = "/oauth2redirect"
    static let googleRedirectURI = "\(googleRedirectScheme):\(googleRedirectPath)"

    enum Keychain {
        static let service = SharedConstants.Keychain.service
        static let accessTokenKey = SharedConstants.Keychain.accessTokenKey
        static let refreshTokenKey = SharedConstants.Keychain.refreshTokenKey
        static let expirationKey = SharedConstants.Keychain.expirationKey
        static let accountProfileKey = SharedConstants.Keychain.accountProfileKey
    }

    enum UserDefaults {
        static let dueDateNotificationsEnabledKey = "dueDateNotificationsEnabled"
        static let automaticUpdateChecksEnabledKey = "automaticUpdateChecksEnabled"
        static let lastUpdateCheckDateKey = "lastUpdateCheckDate"
        static let lastAlertedUpdateVersionKey = "lastAlertedUpdateVersion"
        /// Primary pane's sort order. Named without a pane prefix because it
        /// predates panes, so an existing preference keeps working.
        static let taskSortOrderKey = "taskSortOrder"
        static let secondaryTaskSortOrderKey = "secondaryTaskSortOrder"
        static let menuBarCounterModeKey = "menuBarCounterMode"
        static let sideBySideListsEnabledKey = "sideBySideListsEnabled"
        /// Last list each pane showed, restored on launch when it still exists.
        static let primarySelectedListIdKey = "primarySelectedListId"
        static let secondarySelectedListIdKey = "secondarySelectedListId"
    }

    enum Notifications {
        static let dueDateIdentifierPrefix = "dev.crazytan.TaskMenu.dueDate"
    }
}
