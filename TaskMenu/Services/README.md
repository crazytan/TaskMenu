# Services

Services isolate external systems and side effects from views. Keep protocols narrow and inject concrete implementations through `AppState` or service initializers.

## Files

- `GoogleAuthService.swift` - `@MainActor` OAuth 2.0 PKCE flow, web-auth callback parsing, token exchange/revocation, Keychain-backed token loading, and signed-in account email loading. Conforms to `AccessTokenProviding`. On `init`, runs `KeychainMigration` to move any legacy-location tokens into the shared Keychain access group (a safe no-op when unsigned/no group is resolved), and holds both the current-location `keychain` (shared group when resolved) and the always-legacy `legacyKeychain` so `signOut()`/`disconnect()` clear both locations.
- `GoogleTasksAPI.swift` - `actor` REST client for Google Tasks lists, tasks, subtask creation, updates, deletes, pagination, and status-only completion (`setTaskCompleted`). Depends on `any AccessTokenProviding` rather than the concrete `GoogleAuthService`; a convenience `init(authService:)` keeps existing call sites (e.g. `AppState`) compiling.
- `TasksAPIProtocol.swift` - async API contract used by `AppState`, production API code, demo/testing fakes, and unit-test doubles. `setTaskCompleted(listId:taskId:)` has a default implementation (fetch, mark completed, `updateTask`) so conformers that don't override it — `DemoTasksAPI`, the `--testing-window` fake, and test doubles — keep compiling and behaving correctly unmodified; `GoogleTasksAPI` overrides it with a real status-only PATCH.
- `AccessTokenProviding.swift` - narrow `Sendable` async token protocol (`func validAccessToken() async throws -> String`) consumed by `GoogleTasksAPI`. Foundation-only so it compiles into `TaskMenuWidget`. `GoogleAuthService` (interactive, app) and `WidgetGoogleAccessTokenProvider` (refresh-only, extension) both conform.
- `GoogleTokenRefresher.swift` - extension-safe (Foundation only) refresh-token request building and response/error policy shared by `GoogleAuthService` and `WidgetGoogleAccessTokenProvider`, so the "definitive rejection" rule (`invalid_grant`/`invalid_client` on 400/401 clears credentials; 429/5xx/decode/network failures preserve them) lives in exactly one place.
- `WidgetGoogleAccessTokenProvider.swift` - `actor`, refresh-only `AccessTokenProviding` for `TaskMenuWidget`. Reads/writes the shared Keychain access group only (never the legacy location — migration is the containing app's job), coalesces concurrent same-process refreshes, preserves the existing refresh token when Google omits a replacement, and never presents UI.
- `KeychainMigration.swift` - one-time coordinator that copies OAuth Keychain items from the app's legacy default location to the shared access group, with explicit per-key states (`KeychainItemMigrationState`) rather than logic buried in query construction. Verifies each shared write by reading it back before deleting the legacy copy; shared copies always win when both exist. Not part of the `TaskMenuWidget` target — migration is exclusively the containing app's responsibility.
- `DemoTasksAPI.swift` - `actor` in-memory sample data (Today/Work/Personal) backing demo mode; no network, no credentials, and mutations are discarded when the demo ends; `createTaskList` appends an in-memory list that lasts for the demo session, and `moveTask` honors `destinationListId` by moving the task tree between its in-memory lists (`tasksMovingTaskTree`), first among the destination's root tasks. Seeded positions use Google's 20-digit zero-padded format, and `createTask` mirrors the real API by storing the new task first among its siblings with the group renumbered (`tasksWithCreatedTask(_:in:)`), so demo mode reproduces the stale-position ordering the live account shows.
- `GitHubUpdateChecker.swift` - GitHub Releases latest-version lookup, semantic-version comparison, and the update-check protocol used by Settings and launch alerts. Also holds `DisabledUpdateChecker` for Mac App Store builds and the `--testing-window` fakes. `GitHubUpdateChecker` is wrapped in `#if !APP_STORE_BUILD`.
- `KeychainService.swift` - Sendable wrapper around Security framework item CRUD; stores items in the data-protection keychain (device-only accessibility) with transparent migration from the legacy login-keychain location and a fallback for unsigned builds. Accepts an optional explicit `accessGroup`; when set, `kSecAttrAccessGroup` is included in every query and the instance operates *only* on that shared, data-protection-keychain location (no login-keychain fallback, no dual-location delete), so a shared instance and a legacy (no-group) instance can never accidentally touch each other's records. Shared to `TaskMenuWidget`.
- `DueDateNotificationService.swift` - UserNotifications abstraction and due-date reminder syncing.
- `MetricKitService.swift` - local persistence of delivered and past MetricKit payloads.

## OAuth And Token Handling

- `GoogleAuthService` stays on the main actor because `ASWebAuthenticationSession` and presentation context are UI-facing.
- Store access tokens, refresh tokens, expiration, and signed-in account display metadata in Keychain through `KeychainServiceProtocol`. New writes always go to the current-location `keychain` (the shared access group in signed builds).
- `validAccessToken()` is the gateway for API calls, declared by `AccessTokenProviding`. Do not let API clients read token properties directly.
- Refresh-token request building and the definitive-rejection policy live in `GoogleTokenRefresher`, not in `GoogleAuthService` itself, so `WidgetGoogleAccessTokenProvider` shares the identical policy.
- Load the signed-in account email through Google's OpenID Connect userinfo endpoint after requesting `openid email`.
- Callback parsing must validate scheme, path, state, Google error responses, and non-empty authorization code.

## Shared Keychain And Migration

- The shipped (pre-widget) app has no `application-identifier` entitlement, so every existing install's OAuth items live in the *legacy* location: the data-protection keychain with no explicit access group, falling back to the file-based login keychain for unsigned builds. There is no "old team-prefixed access group" to migrate from.
- `KeychainMigration` copies each known key (access token, refresh token, expiration, account profile) from that legacy location to the shared access group resolved from `SharedConstants.keychainAccessGroup`, verifying with a read-back before deleting the legacy copy. It is a safe no-op whenever the shared group is unresolved (unsigned dev/CI builds), and idempotent/resumable across a crash between any two item writes.
- `GoogleAuthService.init` runs migration automatically before loading tokens. `signOut()`/`disconnect()` clear both the current (`keychain`) and `legacyKeychain` locations so an old token can never resurrect a session.
- `WidgetGoogleAccessTokenProvider` only ever reads/writes the shared group; it has no reference to a legacy-location `KeychainServiceProtocol` at all.

## Google Tasks API

- Keep `GoogleTasksAPI` actor-isolated and conforming to `TasksAPIProtocol`.
- Use typed model decoding for responses. Avoid hand-parsing JSON except for small request bodies where the current code already uses dictionaries.
- Preserve pagination for `listTasks` and `listTaskLists`; both loop on `nextPageToken` with `maxResults=100`.
- `createTaskList(title:)` posts `{"title": …}` to `/users/@me/lists` and decodes the returned `TaskList`.
- `listTasks` does not request assigned tasks with `showAssigned` today. Add that intentionally if assigned Workspace tasks become product scope.
- Subtask creation uses the optional `parent` query parameter on `createTask`.
- `moveTask` posts to the `/move` endpoint with optional `parent` and `previous` query parameters; omitting `parent` moves the task to the top level and omitting `previous` places it first among its siblings. The optional `destinationListId` becomes the `destinationTasklist` query parameter, moving the task out of `listId`; `parent`/`previous` then refer to the destination list. Google rejects moving recurring tasks between lists; that error surfaces through `errorMessage`. The four-argument overload in the protocol extension is the same-list move.
- For task updates, send nullable `notes` and `due` values when clearing fields.
- `setTaskCompleted(listId:taskId:)` sends a PATCH whose body contains only `{"status": "completed"}` and returns the decoded, authoritative `TaskItem` — used by the widget's completion intent so it never needs notes or a full task payload.

## Notifications And Metrics

- Due-date notifications are list-scoped using `DueDateNotificationService.identifier(forTaskID:listID:)`.
- Notification sync removes stale pending notifications for the active list; delivered notifications are removed only for tasks that are completed, gone, or no longer dated — never for still-incomplete overdue tasks. Sync work is serialized internally (FIFO), and at most 60 requests are scheduled per sync (soonest fire dates first) to stay under the system's 64-pending cap.
- Reminder timing is 9 AM local time for future due dates, or an immediate short interval when today's 9 AM has passed.
- MetricKit payloads are written under Application Support. Leave upload behavior unimplemented unless privacy and consent are explicitly handled.

## Update Checks

- `GitHubUpdateChecker` checks the public latest GitHub release endpoint and returns an update only when the release tag is valid `x.y.z` semver and newer than the bundle short version. An unparseable release tag throws (surfaced as a failed check); an unparseable current version returns nil so dev builds do not show a permanent failure. The app re-checks on a 24-hour loop while running.
- `AppState` owns the automatic-check preference, 24-hour throttle, last-check timestamp, and last-alerted version.
- Keep update checks read-only and unauthenticated. Opening the GitHub release page is user-initiated from settings or the launch alert.
- The `AppStore` configuration defines `APP_STORE_BUILD`, which compiles out `GitHubUpdateChecker` and `Constants.githubLatestReleaseURL`; `AppState` falls back to `DisabledUpdateChecker` there.

## Demo Mode

- `AppState.enterDemoMode()` swaps `api` from the account-backed client to `DemoTasksAPI` and marks the session signed in; `exitDemoMode()` restores the live client. `authService` is never touched, so stored credentials survive a demo session.
- Demo mode is entered only from the signed-out screen. Stored tokens make `authService.isSignedIn` true, which blocks entry by design.
- Notification syncing is suppressed while in demo mode, so sample due dates never schedule real reminders.

## Testing Hooks

- Prefer protocol injection over conditional production logic.
- Use test doubles for keychain, web authentication, URL loading, update checking, and notification center behavior.
- The `--testing-window` fake Tasks API lives in `TaskMenuApp.swift` and implements `createTaskList` and cross-list `moveTask` in memory like `DemoTasksAPI`; keep production services injectable instead of adding testing-window branches here.
