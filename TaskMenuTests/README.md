# TaskMenuTests

Unit tests cover model behavior, app state, services, pure view helpers, and app lifecycle seams. Prefer small focused test slices while iterating.

## Test Map

- `AppStateTests.swift` - initial state, preferences, version/build-commit display, selected list helpers, ordering, created-task placement (`tasksWithCreatedTask`), sign-out/disconnect reset, and basic guarded actions.
- `AppStateBehaviorTests.swift` - task mutations (including subtask creation landing first despite stale sibling positions), caching, stale response protection, selection changes, refresh behavior, errors, and notification sync.
- `DemoModeTests.swift` - entering/leaving demo mode, sample-list seeding without network access, suppressed notification syncing, credential-preserving sign-out, and restoration of the account-backed API on exit.
- `SearchFilterTests.swift` - title/notes search, parent context inclusion, and root/subtask filtered accessors.
- `TaskItemModelTests.swift` and `GoogleTasksAPITests.swift` - model Codable round trips, completion helpers, parent/subtask fields, and due-date accessors.
- `GoogleTasksAPIBehaviorTests.swift` - REST request methods, query parameters, pagination, auth headers, create/update bodies, and error mapping.
- `GoogleTasksAPILiveTests.swift` - opt-in contract checks against the real Google Tasks API: the first-child insert semantics `AppState.addSubtask` relies on (positions come back `00000000000000000000` and siblings are renumbered), and `AppState.addSubtask` itself showing the server's order before any refresh. Skipped unless `TASKMENU_LIVE_GOOGLE_TESTS=1` is set (pass it as `TEST_RUNNER_TASKMENU_LIVE_GOOGLE_TESTS=1` to `xcodebuild`) and the test host can read a sign-in, which means signing in once from a Debug run of the app; it works in a throwaway task list that it deletes afterwards, or inside `TASKMENU_LIVE_GOOGLE_LIST_ID` (tasks left in place) for comparing with the Google Tasks website.
- `GoogleAuthServiceTests.swift` - token loading, refresh/sign-in callback behavior, token exchange errors, revocation, and web-auth test doubles.
- `KeychainServiceTests.swift` - production wrapper behavior and XCTest in-memory isolation.
- `DueDateNotificationServiceTests.swift` - authorization, scheduling, stale-removal, and identifier targeting.
- `GitHubUpdateCheckerTests.swift` - semantic-version parsing, GitHub release decoding, update-check persistence, throttling, launch-alert suppression, and AppState update outcomes.
- `DateFormattingTests.swift` - RFC 3339, Google due-date, display, and relative-date behavior.
- `TaskListViewTests.swift`, `TaskDetailViewTests.swift`, and `MenuBarWindowChromeTests.swift` - shared task presentation helpers, the inline add-subtask field and where a committed subtask renders (end to end through `AppState` and `DemoTasksAPI`), and AppKit glass/window behavior.
- `TaskMenuActionButtonTests.swift` - pointing-hand cursor opt-in on `TaskMenuActionButton` (cursor tracking areas and `cursorUpdate` behavior).
- `MetricKitPayloadStoreTests.swift` - local payload persistence.
- `TaskMenuAppTests.swift` - app/app-delegate construction seams, launch UI mode parsing, the automatic update-check loop, and update-alert choice mapping.
- `TaskMenuMainMenuTests.swift` - main-menu structure and ordering, first-responder selectors and nil targets, key-equivalent resolution for every shortcut, autoenabling, responder-chain resolution of ⌘N/⌘F from a focused text field, and the unconditional launch install. Never performs a real `copy:` — that would clobber the developer's clipboard.
- `SettingsLaunchAtLoginTests.swift` - the pure launch-at-login status decision (`requiresApproval` notice) behind the Settings toggle.
- `SettingsVersionRowTests.swift` - the rendered Settings version row, covering the `Version <version> (<commit>)` text and the `dev` fallback for unstamped builds.

## Test Doubles

- `MockURLProtocol.swift` provides a URLSession that records requests and returns stubbed responses.
- `InMemoryKeychainService.swift` provides keychain success/failure doubles.
- `TestDueDateNotificationService.swift` records notification sync and removal calls for `AppState`.

## Running Focused Tests

```bash
xcodebuild test -project TaskMenu.xcodeproj -scheme TaskMenu \
  -configuration Debug \
  -only-testing:TaskMenuTests/GoogleTasksAPIBehaviorTests
```

- Use `-only-testing:` for the nearest suite first.
- Mark test classes `@MainActor` when they touch `AppState`, `GoogleAuthService`, AppKit, or other main-actor helpers.
- Keychain tests must use unique service names or the in-memory XCTest path to avoid cross-test contamination.
- When changing source file membership, regenerate with `xcodegen generate` before running tests.
