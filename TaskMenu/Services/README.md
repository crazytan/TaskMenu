# Services

Services isolate external systems and side effects from views. Keep protocols narrow and inject concrete implementations through `AppState` or service initializers.

## Files

- `GoogleAuthService.swift` - `@MainActor` OAuth 2.0 PKCE flow, web-auth callback parsing, token exchange/refresh/revocation, Keychain-backed token loading, and signed-in account email loading.
- `GoogleTasksAPI.swift` - `actor` REST client for Google Tasks lists, tasks, updates, deletes, pagination, and moves.
- `TasksAPIProtocol.swift` - async API contract used by `AppState`, production API code, and unit-test doubles.
- `GitHubUpdateChecker.swift` - GitHub Releases latest-version lookup, semantic-version comparison, and update-check protocol.
- `KeychainService.swift` - Sendable wrapper around Security framework item CRUD.
- `DueDateNotificationService.swift` - UserNotifications abstraction and due-date reminder syncing.
- `MetricKitService.swift` - local persistence of delivered and past MetricKit payloads.

## OAuth And Token Handling

- `GoogleAuthService` stays on the main actor because `ASWebAuthenticationSession` and presentation context are UI-facing.
- Store access tokens, refresh tokens, expiration, and signed-in account display metadata in Keychain through `KeychainServiceProtocol`.
- `validAccessToken()` is the gateway for API calls. Do not let API clients read token properties directly.
- Load the signed-in account email through Google's OpenID Connect userinfo endpoint after requesting `openid email`.
- Callback parsing must validate scheme, path, state, Google error responses, and non-empty authorization code.

## Google Tasks API

- Keep `GoogleTasksAPI` actor-isolated and conforming to `TasksAPIProtocol`.
- Use typed model decoding for responses. Avoid hand-parsing JSON except for small request bodies where the current code already uses dictionaries.
- Preserve pagination for `listTasks`.
- For task updates, send nullable `notes` and `due` values when clearing fields.
- Move requests use Google's `previous` and `parent` query parameters; keep AppState ordering tests in sync with any changes.

## Notifications And Metrics

- Due-date notifications are list-scoped using `DueDateNotificationService.identifier(forTaskID:listID:)`.
- Notification sync should remove stale pending and delivered notifications for the active list.
- Reminder timing is 9 AM local time for future due dates, or an immediate short interval when today's 9 AM has passed.
- MetricKit payloads are written under Application Support. Leave upload behavior unimplemented unless privacy and consent are explicitly handled.

## Update Checks

- `GitHubUpdateChecker` checks the public latest GitHub release endpoint and returns an update only when the release tag is valid `x.y.z` semver and newer than the bundle short version.
- Keep update checks read-only and unauthenticated. Opening the GitHub release page is user-initiated from settings or the launch alert.

## Testing Hooks

- Prefer protocol injection over conditional production logic.
- Use test doubles for keychain, web authentication, URL loading, update checking, and notification center behavior.
