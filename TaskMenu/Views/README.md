# Views

Views render the AppKit menu-bar popover and settings UI. Keep business behavior in `AppState`; keep view files focused on presentation, local interaction state, and small pure helpers that can be unit-tested.

## Files

- `AppKitTaskUIHelpers.swift` - shared AppKit controls, SF Symbol helpers, layout pinning, hover handling, opt-in pointing-hand cursor, menu actions, and Observation glue.
- `TaskPopoverViewController.swift` - signed-out (Sign in with Google / Explore the Demo / Quit), initial-loading, signed-in task list, top demo banner, bottom error strip, popover sizing, settings handoff, and popover surface styling.
- `TaskListAppKitViewController.swift` - task-list/detail coordination with an animated push/pop slide between the list page and the edit screen (driven by `constraint.animator().constant` on a layer-backed container; `allowsImplicitAnimation` plus a plain `constant` assignment does not animate here and renders as an instant jump), list picker routing, search bar wiring, local list disclosure state, and `AppState` mutation wiring.
- `TaskListControlsAppKitViews.swift` - list picker, refresh spinner, overflow menu, search bar, and quick-add field AppKit views. Both text-entry views expose `focusField()` for the ⌘N/⌘F menu shortcuts.
- `TaskListContentAppKitView.swift` - task-list empty states, outline view, active/completed sections, subtask display, and row context menus. Renders through a keyed per-parent diff over stable outline nodes so task mutations animate (slide/fade rows, animated disclosures); list switches, search keystrokes, and empty-state swaps fall back to a plain reload, and Reduce Motion downgrades slides to fades.
- `TaskDetailAppKitViewController.swift` - task edit screen, title/notes fields, due-date state and calendar overlay, disabled list picker, delete action, and subtask add/toggle UI.
- `TaskPresentation.swift` - pure task-list, notes preview, and completed-subtask ordering helper logic.
- `TestingWindowController.swift` - opt-in testing-mode window that hosts the popover UI outside the status item.
- `SettingsView.swift` - AppKit settings window/controller with native grouped section boxes (switch rows, update status row showing the version and build commit, account row), notification preference, launch-at-login, update checks, signed-in account email display, tips/support/about links, account disconnect confirmation, and quit controls.
- `MenuBarWindowGlassSupport.swift` - macOS 26 Liquid Glass window-background support.

## UI Ownership

- AppKit popover and settings controllers hold the shared `AppState`, observe only the state they render, and call `AppState` methods for mutations.
- Keep network, keychain, OAuth, and notification calls out of views.
- `TaskPopoverViewController` owns the popover's fixed signed-in size. Avoid growing the popover dynamically unless all task-list states are checked. The demo banner and error strip take their height out of the task list rather than growing the popover.
- Demo mode is surfaced in three places, all routing to `AppState`: the signed-out "Explore the Demo" button, the banner's "Exit Demo" button, and the overflow menu's "Exit demo" item (retitled from "Sign out" via `TaskListHeaderView.isDemoMode`). Settings shows it in the account row.
- `TestingWindowController` is only for opt-in local testing mode; do not route normal launches through it.
- `SettingsWindowController` is a settings window, not the main task UI.

## Task List Interaction Rules

- Completed tasks are grouped into a disclosure section below the active tasks; subtasks render indented under their parent.
- Parent task rows can collapse or expand visible subtasks; search keeps parents visible when a subtask matches.
- Right-clicking a task row exposes Delete from the outline view context menu.
- Active (incomplete) task rows support drag-and-drop reordering through `AppState.moveTask`: reorder top-level tasks, reorder subtasks within their parent, drop a leaf task onto a top-level row to nest it as its last subtask, and drag a subtask into a top-level gap to promote it. Dragging is disabled while searching and for completed rows; the gap directly below an expanded parent resolves to the first-subtask position.
- ⌘N focuses the quick-add field and ⌘F focuses the filter field. Both come from the main menu (`TaskMenuMainMenu`) and reach `TaskListAppKitViewController` through the responder chain, so they work from any focused field on the list page. They are scoped to the list page by a guard in each action plus `validateMenuItem`, which greys them out while the detail page is pushed; the guard is the load-bearing half, since a disabled item can still claim its key equivalent.
- Keep helper functions pure when possible and cover interaction logic in `TaskListViewTests`.

## Task Detail Interaction Rules

- The due-date row pairs a text/stepper `NSDatePicker` with a calendar button. The calendar renders as an overlay inside the detail view, never an `NSPopover`: a nested popover gets its own window, which the status item's `.transient` popover and `StatusBarController`'s outside-click monitors both read as a click elsewhere and close the task detail mid-edit. Note the testing window hosts the detail view in a plain window, so it will not reproduce that failure.
- Picking a date writes into the existing picker instance rather than rebuilding the due-date row, preserving the guarantee that background refreshes never discard in-progress edits or steal focus.
- Escape closes an open calendar first and only dismisses the editor on a second press.

## Styling Notes

- Use SF Symbols for UI icons.
- Preserve the compact 320-point menu-bar popover design.
- Keep settings sections compact and scannable; the support callout is the only intentionally prominent element.
- macOS 26 Liquid Glass support is gated by availability and applied to the popover window from AppKit.
- Avoid adding instructional text to the UI; controls should be self-explanatory in context.
- Animations must respect `NSWorkspace.accessibilityDisplayShouldReduceMotion`; new custom layer colors need refreshing in `viewDidChangeEffectiveAppearance()` so appearance switches don't leave stale CGColors.
