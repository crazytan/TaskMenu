# Views

Views render the AppKit menu-bar popover and settings UI. Keep business behavior in `AppState`; keep view files focused on presentation, local interaction state, and small pure helpers that can be unit-tested.

## Files

- `AppKitTaskUIHelpers.swift` - shared AppKit controls, SF Symbol helpers, layout pinning, hover handling, menu actions, and Observation glue.
- `TaskPopoverViewController.swift` - signed-out, initial-loading, signed-in task list, bottom error strip, popover sizing, settings handoff, and popover surface styling.
- `TaskListAppKitViewController.swift` - task-list/detail coordination, list picker routing, local list disclosure state, and `AppState` mutation wiring.
- `TaskListControlsAppKitViews.swift` - list header and quick-add field AppKit views.
- `TaskListContentAppKitView.swift` - task-list empty states, scroll view, active/completed sections, and subtask display.
- `TaskDetailAppKitViewController.swift` - task edit screen, due-date state, notes, delete action, and child task preview.
- `TaskPresentation.swift` - pure task-list, notes preview, and completed-subtask ordering helper logic.
- `TestingWindowController.swift` - opt-in testing-mode window that hosts the popover UI outside the status item.
- `SettingsView.swift` - AppKit settings window/controller, notification preference, launch-at-login, update checks, signed-in account email display, account disconnect confirmation, support links, and quit controls.
- `MenuBarWindowGlassSupport.swift` - macOS 26 Liquid Glass window-background support.

## UI Ownership

- AppKit popover and settings controllers hold the shared `AppState`, observe only the state they render, and call `AppState` methods for mutations.
- Keep network, keychain, OAuth, and notification calls out of views.
- `TaskPopoverViewController` owns the popover's fixed signed-in size. Avoid growing the popover dynamically unless all task-list states are checked.
- `TestingWindowController` is only for opt-in local testing mode; do not route normal launches through it.
- `SettingsWindowController` is a settings window, not the main task UI.

## Task List Interaction Rules

- Completed tasks are grouped into a disclosure section below the active tasks; subtasks render indented under their parent.
- Keep helper functions pure when possible and cover interaction logic in `TaskListViewTests`.

## Styling Notes

- Use SF Symbols for UI icons.
- Preserve the compact 320-point menu-bar popover design.
- Keep settings sections compact and scannable; the support callout is the only intentionally prominent element.
- macOS 26 Liquid Glass support is gated by availability and applied to the popover window from AppKit.
- Avoid adding instructional text to the UI; controls should be self-explanatory in context.
