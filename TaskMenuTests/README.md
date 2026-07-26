# TaskMenuTests

Unit tests cover model behavior, app state, services, pure view helpers, and app lifecycle seams. Prefer small focused test slices while iterating.

## Test Map

- `AppStateTests.swift` - initial state, preferences, selected list helpers, ordering, sign-out/disconnect reset, and basic guarded actions.
- `AppStateBehaviorTests.swift` - task mutations, caching, stale response protection, selection changes, refresh behavior, errors, and notification sync.
- `SearchFilterTests.swift` - title/notes search, parent context inclusion, and root/subtask filtered accessors.
- `TaskItemModelTests.swift` and `GoogleTasksAPITests.swift` - model Codable round trips, completion helpers, parent/subtask fields, and due-date accessors.
- `GoogleTasksAPIBehaviorTests.swift` - REST request methods, query parameters, pagination, auth headers, create/update bodies, and error mapping.
- `GoogleAuthServiceTests.swift` - token loading, refresh/sign-in callback behavior, token exchange errors, revocation, and web-auth test doubles.
- `KeychainServiceTests.swift` - production wrapper behavior and XCTest in-memory isolation.
- `DueDateNotificationServiceTests.swift` - authorization, scheduling, stale-removal, and identifier targeting.
- `GitHubUpdateCheckerTests.swift` - semantic-version parsing, GitHub release decoding, update-check persistence, throttling, launch-alert suppression, and AppState update outcomes.
- `DateFormattingTests.swift` - RFC 3339, Google due-date, display, and relative-date behavior.
- `TaskListViewTests.swift`, `TaskDetailViewTests.swift`, and `MenuBarWindowChromeTests.swift` - shared task presentation helpers and AppKit glass/window behavior.
- `TaskMenuActionButtonTests.swift` - pointing-hand cursor opt-in on `TaskMenuActionButton` (cursor tracking areas and `cursorUpdate` behavior).
- `MetricKitPayloadStoreTests.swift` - local payload persistence.
- `TaskMenuAppTests.swift` - app/app-delegate construction seams, launch UI mode parsing, the automatic update-check loop, and update-alert choice mapping.
- `SettingsLaunchAtLoginTests.swift` - the pure launch-at-login status decision (`requiresApproval` notice) behind the Settings toggle.

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
