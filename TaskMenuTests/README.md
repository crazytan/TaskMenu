# TaskMenuTests

Unit tests cover model behavior, app state, services, pure view helpers, and app lifecycle seams. Prefer small focused test slices while iterating.

## Test Map

- `AppStateTests.swift` - initial state, preferences (including the sort-order and menu-bar counter preferences and their persistence across sign-out), `menuBarPendingCount` guards (signed out, Off, live selected-list tasks), version/build-commit display, selected list helpers, ordering (Google position and due-date sort), created-task placement (`tasksWithCreatedTask`), sign-out/disconnect reset, and basic guarded actions.
- `AppStateBehaviorTests.swift` - task mutations (including subtask creation landing first despite stale sibling positions, and drag moves being ignored while sorted by due date), caching, stale response protection, selection changes, refresh behavior, errors, notification sync, task-list creation (append/select, blank titles, failure, sign-out during the request), cross-list `moveTask(_:toList:)` optimistic updates, rollback, subtask/same-list guards, reminder removal and per-list syncs, and the menu-bar counter's background count sweep, periodic refresh, stale-snapshot discard, and error swallowing (`DelayedTasksAPI` records `listTasks` calls per list, can throw per list, and with `setMoveTaskSuccess()` applies same-list and cross-list moves to its own lists while logging `moveCalls`).
- `DemoModeTests.swift` - entering/leaving demo mode, sample-list seeding without network access, suppressed notification syncing, credential-preserving sign-out, restoration of the account-backed API on exit, account-wide demo counts for the menu-bar counter, and creating a demo list in memory.
- `MenuBarCounterTests.swift` - pure menu-bar counting (open vs due-today, day boundaries, subtasks) and the status item title/length presentation helper.
- `SideBySidePanesTests.swift` - two-pane state: preference persistence, secondary default list, per-pane loads and stale-load protection, per-list refresh dedupe, mutation fan-out to every pane showing a list, per-pane mutation targeting, hidden-pane re-seeding, sign-out/demo reset, notification sync per visible list (and never from a pane's empty placeholder before its first fetch lands), the primary-pane forwarders, and moving a task into the other pane's list (uses a recording wrapper around `DemoTasksAPI`).
- `SearchFilterTests.swift` - title/notes search, parent context inclusion, root/subtask filtered accessors, and the sort order of filtered roots.
- `TaskItemModelTests.swift` and `GoogleTasksAPITests.swift` - model Codable round trips, completion helpers, parent/subtask fields, and due-date accessors.
- `GoogleTasksAPIBehaviorTests.swift` - REST request methods, query parameters (including the move endpoint's `destinationTasklist`), pagination, auth headers, create/update bodies, the task-list creation request, and error mapping.
- `GoogleTasksAPILiveTests.swift` - opt-in contract checks against the real Google Tasks API: the first-child insert semantics `AppState.addSubtask` relies on (positions come back `00000000000000000000` and siblings are renumbered), `AppState.addSubtask` itself showing the server's order before any refresh, and whether `tasks.move` with `destinationTasklist` carries a parent's subtasks along (the assumption behind `AppState.moveTask(_:toList:)`). Skipped unless `TASKMENU_LIVE_GOOGLE_TESTS=1` is set (pass it as `TEST_RUNNER_TASKMENU_LIVE_GOOGLE_TESTS=1` to `xcodebuild`) and the test host can read a sign-in, which means signing in once from a Debug run of the app; it works in a throwaway task list that it deletes afterwards, or inside `TASKMENU_LIVE_GOOGLE_LIST_ID` (tasks left in place) for comparing with the Google Tasks website.
- `GoogleAuthServiceTests.swift` - token loading, refresh/sign-in callback behavior, token exchange errors, revocation, and web-auth test doubles.
- `KeychainServiceTests.swift` - production wrapper behavior and XCTest in-memory isolation.
- `DueDateNotificationServiceTests.swift` - authorization, scheduling, stale-removal, and identifier targeting.
- `GitHubUpdateCheckerTests.swift` - semantic-version parsing, GitHub release decoding, update-check persistence, throttling, launch-alert suppression, and AppState update outcomes.
- `DateFormattingTests.swift` - RFC 3339, Google due-date, display, and relative-date behavior.
- `TaskListViewTests.swift`, `TaskDetailViewTests.swift`, and `MenuBarWindowChromeTests.swift` - shared task presentation helpers (including the pane-aware `TaskListPresentation` variants), the inline add-subtask field and where a committed subtask renders (end to end through `AppState` and `DemoTasksAPI`), the overflow menu's sort submenu and side-by-side item, drag gating under a due-date sort, the list picker's "New List…" item and inline field, the "Move to" context submenu, the content view rendering the pane it is handed, the task editor's list picker (ID-based selection, enabled/disabled rules, and a move that saves pending edits first), the signed-in popover rendering one or two pane controllers at 320 or 641 wide with the hairline divider, and AppKit glass/window behavior.
- `TaskMenuActionButtonTests.swift` - pointing-hand cursor opt-in on `TaskMenuActionButton` (cursor tracking areas and `cursorUpdate` behavior).
- `MetricKitPayloadStoreTests.swift` - local payload persistence.
- `TaskMenuAppTests.swift` - app/app-delegate construction seams, launch UI mode parsing, the automatic update-check loop, and update-alert choice mapping.
- `TaskMenuMainMenuTests.swift` - main-menu structure and ordering, first-responder selectors and nil targets, key-equivalent resolution for every shortcut, autoenabling, responder-chain resolution of ⌘N/⌘F from a focused text field, and the unconditional launch install. Never performs a real `copy:` — that would clobber the developer's clipboard.
- `SettingsLaunchAtLoginTests.swift` - the pure launch-at-login status decision (`requiresApproval` notice) behind the Settings toggle.
- `SettingsVersionRowTests.swift` - the rendered Settings version row, covering the `Version <version> (<commit>)` text and the `dev` fallback for unstamped builds.
- `SettingsSideBySideRowTests.swift` - the "Show two lists side by side" switch in Settings › General: present, mirrors `AppState.sideBySideListsEnabled`, and writes it back.

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
