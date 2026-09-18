# TaskMenuWidget

The macOS WidgetKit `app-extension` target that shows a Google Tasks list on
the desktop or in Notification Center. Embedded and codesigned into
`TaskMenu.app/Contents/PlugIns/TaskMenuWidget.appex`. See
`scratch/issue-11-desktop-widget/CONTRACT.md` and `implementation-spec.md`
for the full design; this file tracks what actually exists in this folder.

## Files

- `TaskMenuWidgetBundle.swift` - `@main` `WidgetBundle` entry point; body is
  just `TaskListWidget()`.
- `TaskListWidget.swift` - the `Widget` itself: `AppIntentConfiguration`
  wiring `TaskListWidgetConfigurationIntent` to `TaskListWidgetProvider` and
  `TaskListWidgetView`, `.supportedFamilies([.systemSmall, .systemMedium, .systemLarge])`.
- `TaskListWidgetConfiguration.swift` - `TaskListEntity` (`AppEntity`,
  identity is the Google list id, display representation is title-only),
  `TaskListEntityQuery` (`EntityQuery`, thin wrapper around
  `TaskWidgetListCatalog` in `TaskMenu/WidgetSupport/`), `TaskWidgetSortOrderOption`
  (`AppEnum` mapping onto `TaskSortOrder`), and
  `TaskListWidgetConfigurationIntent` (`WidgetConfigurationIntent`: required
  `list`, `sortOrder` defaulting to `.myOrder`).
- `TaskListWidgetProvider.swift` - `AppIntentTimelineProvider`. Wires
  `TaskWidgetTimelineLoader` (`TaskMenu/WidgetSupport/`, Foundation-only) to
  WidgetKit's `Context`/`Timeline`, and is the one place that maps
  `WidgetFamily` to a row budget (`TaskWidgetProjectionConstants.{small,medium,large}RowBudget`)
  so `TaskWidgetProjection` never has to import WidgetKit. `placeholder(in:)`
  and `snapshot(for:in:)` in preview context never touch I/O; `snapshot`
  otherwise reads the cache only; `timeline(for:in:)` is live-first with
  cache fallback and always schedules `.after(now + 30 minutes)`.
- `TaskListWidgetEntry.swift` - the `TimelineEntry`: `date`, `family`, and a
  `TaskWidgetEntryContent` (pure data, `TaskMenu/WidgetSupport/`).
  `.placeholder(family:)` builds fictional sample content faithful to the
  family with zero I/O.
- `TaskListWidgetView.swift` - pure SwiftUI rendering of one
  `TaskListWidgetEntry`: no file/Keychain/network access, only `Link`s (via
  `TaskWidgetDeepLink.url(forListID:)`) and `Button(intent:)`s backed by
  `CompleteTaskIntent`. Covers every required state (placeholder/sample,
  signed out, first-run/no cache, configured list unavailable, empty list,
  populated, populated stale/offline) and carries `#Preview` fixtures for
  signed-out, empty, offline-cache, overdue, subtasks, truncated,
  list-unavailable, and no-cache, across all three families.
- `CompleteTaskIntent.swift` - the interactive completion `AppIntent`
  (`openAppWhenRun = false`). Carries `listID`/`taskID` (untrusted, used only
  for API path/query construction) and a display-only `taskTitle`. All
  verification/cascade/refetch/publish logic lives in
  `TaskWidgetCompletionCoordinator` (`TaskMenu/WidgetSupport/`); this file
  only wires that coordinator to `AppIntent` and calls
  `WidgetCenter.shared.reloadTimelines(ofKind:)`/`TaskWidgetChangeSignal().post()`
  after (and only after) the coordinator reports `sharedStateChanged`.
- `Info.plist` - `NSExtensionPointIdentifier` = `com.apple.widgetkit-extension`,
  plus `APP_GROUP_IDENTIFIER`, `KEYCHAIN_ACCESS_GROUP`, and
  `GOOGLE_CLIENT_ID` build-setting placeholders. Deliberately carries no
  `CFBundleURLTypes` / Google redirect scheme — the extension never runs the
  OAuth browser flow.
- `TaskMenuWidget.entitlements` - App Sandbox, outbound network client, the
  shared App Group, and the shared Keychain access group. Nothing else; no
  temporary exceptions, incoming network, or Apple Events.

## Testability boundary

This target hosts `AppIntentTimelineProvider`/`EntityQuery`/`AppIntent`/
SwiftUI types that require `AppIntents`/`WidgetKit`/`SwiftUI`. `TaskMenuTests`
hosts the `TaskMenu` app, not this extension, so nothing declared only here
is visible to a unit test. Every piece of decision logic that needs coverage
therefore lives in a Foundation-only file under `TaskMenu/WidgetSupport/`
(compiled into **both** `TaskMenu` and `TaskMenuWidget`, per `project.yml`'s
directory-glob source entries) and this target's types are thin wrappers
around it:

- `TaskListWidgetProvider` → `TaskWidgetTimelineLoader` (cache read, live
  fetch, error handling) — tested by `TaskMenuTests/TaskWidgetProviderTests.swift`.
- `TaskListEntityQuery` → `TaskWidgetListCatalog` (identity/order/default
  resolution) — also covered by `TaskWidgetProviderTests.swift`.
- `CompleteTaskIntent` → `TaskWidgetCompletionCoordinator` (cache-membership
  verification, completion, child cascade, authoritative refetch/publish) —
  tested by `TaskMenuTests/CompleteTaskIntentTests.swift`.

## Target Boundaries

- `APPLICATION_EXTENSION_API_ONLY: YES`. Only Foundation / Security /
  SwiftUI / WidgetKit / AppIntents-safe code may compile into this target.
- Shared sources come from `TaskMenu/WidgetSupport/` (Foundation/Security
  only — see that folder's `README.md`) plus the individual allow-listed
  files in `scratch/issue-11-desktop-widget/CONTRACT.md`'s "Target
  membership" section: `TaskItem.swift`, `TaskList.swift`,
  `TaskSortOrder.swift`, `TaskOrdering.swift`, `DateFormatting.swift`,
  `SharedConstants.swift`, `KeychainService.swift`, `TasksAPIProtocol.swift`,
  `GoogleTasksAPI.swift`, `AccessTokenProviding.swift`,
  `GoogleTokenRefresher.swift`, `WidgetGoogleAccessTokenProvider.swift` — all
  already declared in `project.yml`'s `TaskMenuWidget` target sources.
- Never import `AppState`, anything in `TaskMenu/Views/`,
  `GoogleAuthService`, `DemoTasksAPI`, `DueDateNotificationService`,
  `MetricKitService`, `GitHubUpdateChecker`, `StatusBarController`,
  `TaskMenuApp`, `TaskMenuMainMenu`, `Constants`, `MenuBarCounter`, or
  `TaskListPane` into this target.
- The widget UI (`TaskListWidgetView`) never reads Keychain, the App Group
  container, or the network directly — all of that goes through
  `TaskMenu/WidgetSupport/` (`TaskWidgetSnapshotStore`, `TaskWidgetProjection`,
  `TaskWidgetTimelineLoader`, `TaskWidgetCompletionCoordinator`) and the
  Slice 2 token-provider seam.
