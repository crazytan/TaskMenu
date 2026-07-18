# Services

Services isolate external systems and side effects from views. Keep protocols narrow and inject concrete implementations through `AppState` or service initializers.

## Files

- `GoogleAuthService.swift` - `@MainActor` OAuth 2.0 PKCE flow, web-auth callback parsing, token exchange/refresh/revocation, Keychain-backed token loading, and signed-in account email loading.
- `GoogleTasksAPI.swift` - `actor` REST client for Google Tasks lists, tasks, subtask creation, updates, deletes, and pagination.
- `TasksAPIProtocol.swift` - async API contract used by `AppState`, production API code, and unit-test doubles.
- `GitHubUpdateChecker.swift` - GitHub Releases latest-version lookup, semantic-version comparison, and update-check protocol used by Settings and launch alerts.
- `KeychainService.swift` - Sendable wrapper around Security framework item CRUD; stores items in the data-protection keychain (device-only accessibility) with transparent migration from the legacy login-keychain location and a fallback for unsigned builds.
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
- Preserve pagination for `listTasks` and `listTaskLists`; both loop on `nextPageToken` with `maxResults=100`.
- `listTasks` does not request assigned tasks with `showAssigned` today. Add that intentionally if assigned Workspace tasks become product scope.
- Subtask creation uses the optional `parent` query parameter on `createTask`; the API layer does not expose moving tasks between lists.
- `moveTask` posts to the `/move` endpoint with optional `parent` and `previous` query parameters; omitting `parent` moves the task to the top level and omitting `previous` places it first among its siblings.
- For task updates, send nullable `notes` and `due` values when clearing fields.

## Notifications And Metrics

- Due-date notifications are list-scoped using `DueDateNotificationService.identifier(forTaskID:listID:)`.
- Notification sync removes stale pending notifications for the active list; delivered notifications are removed only for tasks that are completed, gone, or no longer dated — never for still-incomplete overdue tasks. Sync work is serialized internally (FIFO), and at most 60 requests are scheduled per sync (soonest fire dates first) to stay under the system's 64-pending cap.
- Reminder timing is 9 AM local time for future due dates, or an immediate short interval when today's 9 AM has passed.
- MetricKit payloads are written under Application Support. Leave upload behavior unimplemented unless privacy and consent are explicitly handled.

## Update Checks

- `GitHubUpdateChecker` checks the public latest GitHub release endpoint and returns an update only when the release tag is valid `x.y.z` semver and newer than the bundle short version. An unparseable release tag throws (surfaced as a failed check); an unparseable current version returns nil so dev builds do not show a permanent failure. The app re-checks on a 24-hour loop while running.
- `AppState` owns the automatic-check preference, 24-hour throttle, last-check timestamp, and last-alerted version.
- Keep update checks read-only and unauthenticated. Opening the GitHub release page is user-initiated from settings or the launch alert.

## Testing Hooks

- Prefer protocol injection over conditional production logic.
- Use test doubles for keychain, web authentication, URL loading, update checking, and notification center behavior.
- The `--testing-window` fake Tasks API lives in `TaskMenuApp.swift`; keep production services injectable instead of adding testing-window branches here.
