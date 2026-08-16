# TaskMenu App Target

This folder is the macOS application target. Launches install an `NSStatusItem`, show all task UI from an `NSPopover`, and present Settings from an AppKit window.

## Files

- `TaskMenuApp.swift` - `@main`, app delegate wiring, UI mode selection, MetricKit startup, signed-in bootstrap, and settings window ownership.
- `StatusBarController.swift` - AppKit status item, popover presentation, right-click menu (Settings, Quit), outside-click closing, menu-open refresh trigger, and the pending-task count title next to the icon (driven by `AppState.menuBarPendingCount` through the Observation glue; icon only when the count is 0, the setting is Off, or the app is signed out). `MenuBarCounterPresentation` is the pure title/imagePosition/length helper.
- `TaskMenuMainMenu.swift` - `NSApplication.mainMenu` factory (application/File/Edit menus) and its install helper.
- `Models/` - `@MainActor` app state and Google Tasks data models.
- `Services/` - OAuth, API, keychain, notification, metrics, and update-check services.
- `Views/` - AppKit popover/task UI, AppKit settings UI, and shared task presentation helpers.
- `Utilities/` - app constants and Google due-date formatting.
- `Resources/` - plist, entitlements, icons, and asset catalog.

## Lifecycle Notes

- `TaskMenuAppDelegate` owns the shared `AppState`. Pass that same instance into status-bar and settings UI.
- `applicationDidFinishLaunching` installs the main menu unconditionally, before the UI-mode branch, so every mode (popover, Settings, `--testing-window`) gets it.
- `applicationDidFinishLaunching` calls `bootstrapSignedInState()` asynchronously. Avoid blocking launch with network work.
- `StatusBarController` calls `refreshForMenuPresentation()` when the popover opens. Keep this fast and tolerant of cached data.
- The status item's count re-renders on every observed `AppState` change (plus `NSCalendarDayChanged` for the midnight rollover of "Due today"); the count itself is kept fresh by `AppState`'s background sweep and 5-minute loop, not by the status bar. Nothing about the counter animates.
- `--testing-window` launches the same task UI in a regular AppKit window with a fully in-memory `AppState`: seeded fake tasks, an in-memory keychain (no real Keychain access), no Google credentials or network, no notifications, no update checks, and throwaway UserDefaults. The fakes live in `TaskMenuApp.swift`; their `createTask` mirrors the real API (new task first among siblings, siblings renumbered, 20-digit positions) so add-task and add-subtask ordering behaves as it does on a Google account, and their `moveTask` moves a task tree between the seeded lists when given a destination list. `--list <id>` (e.g. `seeded-due-dates`) switches to that seeded list once the first load lands, `--sort-due-date` starts sorted by due date, and the "Due Dates" list carries dated and undated roots so the two sort orders visibly differ. Normal launches remain menu-bar-only.

## AppKit Boundaries

- Keep status item, popover, settings-window ownership, event monitors, and activation-policy work in this folder.
- The main menu exists only to route key equivalents to the first responder; an accessory app never draws it, so it is not a discovery surface. User-visible affordances belong in the popover, Settings, or the status item's right-click menu. Its items must keep a `nil` target so they dispatch through the responder chain.
- Views should not directly reach into `NSStatusItem` or own popover lifetime outside `StatusBarController`.
- Any new normal-launch window is a product decision. The current app is menu-bar-only.
