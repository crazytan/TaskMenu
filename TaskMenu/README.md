# TaskMenu App Target

This folder is the macOS application target. Launches install an `NSStatusItem`, show all task UI from an `NSPopover`, and present Settings from an AppKit window.

## Files

- `TaskMenuApp.swift` - `@main`, app delegate wiring, MetricKit startup, signed-in bootstrap, and settings window ownership.
- `StatusBarController.swift` - AppKit status item, popover presentation, right-click quit menu, outside-click closing, and menu-open refresh trigger.
- `Models/` - `@MainActor` app state and Google Tasks data models.
- `Services/` - OAuth, API, keychain, notification, metrics, and test/demo API implementations.
- `Views/` - AppKit popover/task UI, AppKit settings UI, and shared task presentation helpers.
- `Utilities/` - app constants and Google due-date formatting.
- `Resources/` - plist, entitlements, icons, and asset catalog.

## Lifecycle Notes

- `TaskMenuAppDelegate` owns the shared `AppState`. Pass that same instance into status-bar and settings UI.
- `applicationDidFinishLaunching` calls `bootstrapSignedInState()` asynchronously. Avoid blocking launch with network work.
- `StatusBarController` calls `refreshForMenuPresentation()` when the popover opens. Keep this fast and tolerant of cached data.

## AppKit Boundaries

- Keep status item, popover, settings-window ownership, event monitors, and activation-policy work in this folder.
- Views should not directly reach into `NSStatusItem` or own popover lifetime outside `StatusBarController`.
- Any new normal-launch window is a product decision. The current app is menu-bar-only.
