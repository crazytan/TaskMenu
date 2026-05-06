# TaskMenu App Target

This folder is the macOS application target. Normal launches install an `NSStatusItem` and show all UI from an `NSPopover`; the `Settings` scene is the only SwiftUI scene in `TaskMenuApp`.

## Files

- `TaskMenuApp.swift` - `@main`, app delegate wiring, MetricKit startup, signed-in bootstrap, and the UI-testing window path.
- `StatusBarController.swift` - AppKit status item, popover presentation, right-click quit menu, outside-click closing, and menu-open refresh trigger.
- `Models/` - `@MainActor` app state and Google Tasks data models.
- `Services/` - OAuth, API, keychain, notification, metrics, and test/demo API implementations.
- `Views/` - SwiftUI popover, settings, task list, row, detail, quick-add, and sign-in UI.
- `Utilities/` - app constants and Google due-date formatting.
- `Resources/` - plist, entitlements, icons, and asset catalog.

## Lifecycle Notes

- `TaskMenuAppDelegate` owns the shared `AppState`. Pass that same instance into status-bar, settings, and UI-test windows.
- `TaskMenuApp.makeAppState()` injects `MockTasksAPI` only for `-ui-testing`; production and unit-test defaults should keep real construction paths lightweight.
- `applicationDidFinishLaunching` calls `bootstrapSignedInState()` asynchronously. Avoid blocking launch with network work.
- `StatusBarController` calls `refreshForMenuPresentation()` when the popover opens. Keep this fast and tolerant of cached data.

## AppKit Boundaries

- Keep status item, popover, event monitors, and activation-policy work in this folder.
- SwiftUI views should not directly reach into `NSStatusItem` or own popover lifetime.
- Any new normal-launch window is a product decision. The current app is menu-bar-only.
