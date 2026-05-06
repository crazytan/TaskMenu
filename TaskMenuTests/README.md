# TaskMenuTests

Unit tests cover model behavior, app state, services, pure view helpers, and app lifecycle seams. Prefer small focused test slices while iterating.

## Test Map

- `AppStateTests.swift` - initial state, preferences, selected list helpers, ordering, sign-out reset, and basic guarded actions.
- `AppStateBehaviorTests.swift` - async task loading, caching, stale response protection, task mutations, selection changes, refresh behavior, errors, and notification sync.
- `SearchFilterTests.swift` - title/notes search, parent context inclusion, and root/subtask filtered accessors.
- `TaskItemModelTests.swift` and `GoogleTasksAPITests.swift` - model Codable round trips, completion helpers, parent/subtask fields, and due-date accessors.
- `GoogleTasksAPIBehaviorTests.swift` - REST request methods, query parameters, pagination, auth headers, update bodies, move calls, and error mapping.
- `GoogleAuthServiceTests.swift` - token loading, refresh/sign-in callback behavior, token exchange errors, revocation, and web-auth test doubles.
- `KeychainServiceTests.swift` - production wrapper behavior and XCTest in-memory isolation.
- `DueDateNotificationServiceTests.swift` - authorization, scheduling, stale-removal, and identifier targeting.
- `DateFormattingTests.swift` - RFC 3339, Google due-date, display, and relative-date behavior.
- `TaskListViewTests.swift`, `TaskDetailViewTests.swift`, and `MenuBarWindowChromeTests.swift` - pure view helpers and AppKit glass/window behavior.
- `MetricKitPayloadStoreTests.swift` - local payload persistence.
- `TaskMenuAppTests.swift` - app/app-delegate construction seams.

## Test Doubles

- `MockURLProtocol.swift` provides a URLSession that records requests and returns stubbed responses.
- `InMemoryKeychainService.swift` provides keychain success/failure doubles.
- `TestDueDateNotificationService.swift` records notification sync and removal calls for `AppState`.
- `MockTasksAPI` in the app target is used by UI-testing app state and can be reused for deterministic app flows.

## Running Focused Tests

```bash
xcodebuild test -project TaskMenu.xcodeproj -scheme TaskMenu \
  -configuration Debug \
  -only-testing:TaskMenuTests/GoogleTasksAPIBehaviorTests
```

- Use `-only-testing:` for the nearest suite first.
- Mark test classes `@MainActor` when they touch `AppState`, `GoogleAuthService`, AppKit, or SwiftUI main-actor helpers.
- Keychain tests must use unique service names or the in-memory XCTest path to avoid cross-test contamination.
- When changing source file membership, regenerate with `xcodegen generate` before running tests.
