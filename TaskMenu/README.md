# TaskMenu App Target

This folder is the macOS application target. Launches install an `NSStatusItem`, show all task UI from an `NSPopover`, and present Settings from an AppKit window.

## Files

- `TaskMenuApp.swift` - `@main`, app delegate wiring, UI mode selection, MetricKit startup, signed-in bootstrap, settings window ownership, cold-start "Get URL" Apple Event registration/buffering for widget deep links, and the running-app Darwin-notification listener that reconciles state after a widget completion.
- `StatusBarController.swift` - AppKit status item, popover presentation (including the idempotent `showPopover()` widget deep links present through), right-click menu (Settings, Quit), outside-click closing, menu-open refresh trigger, and the pending-task count title next to the icon (driven by `AppState.menuBarPendingCount` through the Observation glue; icon only when the count is 0, the setting is Off, or the app is signed out). `MenuBarCounterPresentation` is the pure title/imagePosition/length helper.
- `TaskWidgetDeepLinkRouting.swift` - pure widget deep-link routing: `TaskWidgetDeepLinkRouter` (the routing decision — activate, sign-in gate, bootstrap, select list, present popover — against the small `DeepLinkAppStateRouting`/`DeepLinkPopoverPresenting` protocols `AppState`/`StatusBarController` conform to) and `DeepLinkColdStartBuffer` (holds at most one pending link until the app is ready). No `NSAppleEventManager`, AppKit event plumbing, or live status item — unit-testable with fakes.
- `TaskMenuMainMenu.swift` - `NSApplication.mainMenu` factory (application/File/Edit menus) and its install helper.
- `Models/` - `@MainActor` app state and Google Tasks data models.
- `Services/` - OAuth, API, keychain, notification, metrics, and update-check services.
- `Views/` - AppKit popover/task UI, AppKit settings UI, and shared task presentation helpers.
- `Utilities/` - app constants and Google due-date formatting.
- `Resources/` - plist, entitlements, icons, and asset catalog.
- `WidgetSupport/` - Foundation/Security-only DTOs, App Group snapshot store, projection, and deep-link code shared with the `TaskMenuWidget` extension target (see its own `README.md` and `TaskMenuWidget/README.md`). Never import AppKit, SwiftUI, WidgetKit, or AppIntents here.

## Lifecycle Notes

- `TaskMenuAppDelegate` owns the shared `AppState`. Pass that same instance into status-bar and settings UI.
- `applicationDidFinishLaunching` installs the main menu unconditionally, before the UI-mode branch, so every mode (popover, Settings, `--testing-window`) gets it.
- `applicationDidFinishLaunching` calls `bootstrapSignedInState()` asynchronously. Avoid blocking launch with network work.
- `StatusBarController` calls `refreshForMenuPresentation()` when the popover opens. Keep this fast and tolerant of cached data.
- `TaskMenuAppDelegate.applicationWillFinishLaunching` registers the `kAEGetURL` Apple Event handler as early as possible, so a `taskmenu://widget/list?id=...` link that cold-launches the app is not missed — this only happens for a real `.menuBar` launch (`!TaskMenuApp.isUnitTesting`), so `--testing-window` and `TaskMenuAppTests` never register a handler. Every received link goes through `DeepLinkColdStartBuffer`, which holds at most one URL (a second link before the buffer is ready replaces it, never queues) until `configureUserInterface(for: .menuBar)` finishes constructing `statusBarController` and calls `flushBufferedDeepLink()`. From there `TaskWidgetDeepLinkRouter.route(url:activate:appState:popover:)` makes the routing decision; `TaskMenuAppDelegate` supplies `NSApp.activate`, the real `AppState`, and `statusBarController` (as `DeepLinkPopoverPresenting`) as the only AppKit-touching glue.
- `TaskMenuAppDelegate` also observes `TaskWidgetChangeSignal` (the Darwin notification the widget posts after `CompleteTaskIntent` commits) while running as `.menuBar`, debounces a burst of notifications by ~500ms, and then calls `AppState.refreshTasks()` for the visible pane(s) — never a blocking alert on failure, same as any other background refresh.
- The status item's count re-renders on every observed `AppState` change (plus `NSCalendarDayChanged` for the midnight rollover of "Due today"); the count itself is kept fresh by `AppState`'s background sweep and 5-minute loop, not by the status bar. Nothing about the counter animates.
- `--testing-window` launches the same task UI in a regular AppKit window with a fully in-memory `AppState`: seeded fake tasks, an in-memory keychain (no real Keychain access), no Google credentials or network, no notifications, no update checks, and throwaway UserDefaults. The fakes live in `TaskMenuApp.swift`; their `createTask` mirrors the real API (new task first among siblings, siblings renumbered, 20-digit positions) so add-task and add-subtask ordering behaves as it does on a Google account, and their `moveTask` moves a task tree between the seeded lists when given a destination list. `--list <id>` (e.g. `seeded-due-dates`) switches to that seeded list once the first load lands, `--sort-due-date` starts sorted by due date, and the "Due Dates" list carries dated and undated roots so the two sort orders visibly differ. Adding `--side-by-side` starts with the two-pane layout on (`Seeded Tasks` | `Due Dates`, or `Today` | `Work` with `--demo`), `--secondary-list <id>` puts that seeded list in the right pane (so both panes on one list needs no clicking), and the Settings window inside the testing window can toggle the layout live. Normal launches remain menu-bar-only.

## AppKit Boundaries

- Keep status item, popover, settings-window ownership, event monitors, and activation-policy work in this folder.
- The main menu exists only to route key equivalents to the first responder; an accessory app never draws it, so it is not a discovery surface. User-visible affordances belong in the popover, Settings, or the status item's right-click menu. Its items must keep a `nil` target so they dispatch through the responder chain.
- Views should not directly reach into `NSStatusItem` or own popover lifetime outside `StatusBarController`.
- Any new normal-launch window is a product decision. The current app is menu-bar-only.
