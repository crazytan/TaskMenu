import Foundation

/// Narrow async token contract consumed by `GoogleTasksAPI`. Foundation-only
/// so it compiles into both the containing app and the `TaskMenuWidget`
/// extension.
///
/// Two conformers exist:
/// - `GoogleAuthService` (app, `@MainActor`) — interactive PKCE sign-in,
///   revocation, and account profile, in addition to satisfying this
///   protocol for refresh.
/// - `WidgetGoogleAccessTokenProvider` (extension, `actor`) — refresh-only,
///   reads the shared Keychain access group, never presents UI.
///
/// `GoogleTasksAPI` depends on this protocol rather than either concrete
/// type, so the same REST client works unmodified in both processes.
protocol AccessTokenProviding: Sendable {
    /// Returns a non-expired Google OAuth access token, refreshing first if
    /// necessary. Throws `APIError.unauthorized` when no credentials are
    /// available or refresh is definitively rejected.
    func validAccessToken() async throws -> String
}
