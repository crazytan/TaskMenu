# Views

Views render the AppKit menu-bar popover and settings UI. Keep business behavior in `AppState`; keep view files focused on presentation, local interaction state, and small pure helpers that can be unit-tested.

## Files

- `AppKitTaskUIHelpers.swift` - shared AppKit controls, SF Symbol helpers, layout pinning, hover handling, opt-in pointing-hand cursor, menu actions, and Observation glue.
- `TaskPopoverViewController.swift` - signed-out (Sign in with Google / Explore the Demo / Quit), initial-loading, signed-in task list, top demo banner, bottom error strip, popover sizing, settings handoff, and popover surface styling.
- `TaskListAppKitViewController.swift` - task-list/detail coordination with an animated push/pop slide between the list page and the edit screen (driven by `constraint.animator().constant` on a layer-backed container; `allowsImplicitAnimation` plus a plain `constant` assignment does not animate here and renders as an instant jump), list picker routing, search bar wiring, local list disclosure state, and `AppState` mutation wiring.
- `TaskListControlsAppKitViews.swift` - list picker (ending in "New List…") and the inline new-list field that replaces it while composing, refresh spinner, overflow menu (with its "Sort by" submenu; `overflowMenu()` is the testable factory behind the popup), search bar, and quick-add field AppKit views. Both text-entry views expose `focusField()` for the ⌘N/⌘F menu shortcuts.
- `TaskListContentAppKitView.swift` - task-list empty states, outline view, active/completed sections, subtask display, and row context menus. Renders through a keyed per-parent diff over stable outline nodes so task mutations animate (slide/fade rows, animated disclosures); list switches, search keystrokes, and empty-state swaps fall back to a plain reload, and Reduce Motion downgrades slides to fades.
- `TaskDetailAppKitViewController.swift` - task edit screen, title/notes fields, due-date state and calendar overlay, disabled list picker, delete action, and subtask add/toggle UI.
- `TaskPresentation.swift` - pure task-list, notes preview, and completed-subtask ordering helper logic.
- `TestingWindowController.swift` - opt-in testing-mode window that hosts the popover UI outside the status item.
- `SettingsView.swift` - AppKit settings window/controller with native grouped section boxes (switch rows, a pop-up row, update status row showing the version and build commit, account row), notification preference, menu-bar counter pop-up (Off / Open tasks / Due today) in General, launch-at-login, update checks, signed-in account email display, tips/support/about links, account disconnect confirmation, and quit controls.
- Under `APP_STORE_BUILD` the settings window drops the "Automatically check for updates" switch and the "Support TaskMenu" section, and Updates becomes a read-only "Version" section. Keep both variants building.
- Discord is an About-row link in both variants; "Support TaskMenu" holds only the tip button.
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
- Right-clicking a task row exposes Delete from the outline view context menu, plus "Add Subtask" on open top-level rows only (Google Tasks allows a single level of subtasks, matching the drag-and-drop nesting rule).
- "Add Subtask" opens an inline field directly under the parent row, matching where a new subtask lands: `tasks.insert` carries a `parent` and no `previous`, so the Tasks API makes it the first child, and `AppState.addSubtask` places the created task there locally regardless of the position the API returns. Dragging is disabled while the field is open, since the composer row sits among the parent's children without being one of its task siblings and would skew drop indices. It expands a collapsed parent, clears any active filter first, and closes on a list switch, a filter keystroke, or a push to the detail page, since all three rebuild the rows under it. Enter creates the subtask and re-focuses the field (an `NSTextField` resigns first responder on Return, and the outline would read the next Return as "open row"); an empty Enter or Escape closes it. The composer node's signature carries no task state, so sibling updates never reload the row out from under what is being typed.
- Active (incomplete) task rows support drag-and-drop reordering through `AppState.moveTask`: reorder top-level tasks, reorder subtasks within their parent, drop a leaf task onto a top-level row to nest it as its last subtask, and drag a subtask into a top-level gap to promote it. Dragging is disabled while searching, while sorted by due date, and for completed rows; the gap directly below an expanded parent resolves to the first-subtask position.
- The "…" menu's "Sort by" submenu (My order / Due date) sets `AppState.taskSortOrder`; a change closes the inline subtask field and re-renders through the plain-reload path (the sort is part of the content view's render context key). Dragging is disabled while sorted by due date (`AppState.canReorderTasks`), on top of the search and composer rules. The submenu is part of the same `NSMenu.popUp` tracking session, not a new window, so it does not close the transient popover.
- The list picker ends with a separator and "New List…", and it stays enabled with one list or none. Choosing it swaps the picker for an inline field in the header (never an alert, sheet, or nested popover — a separate window closes the transient popover). Enter with a title closes the field, resets the per-list UI like a list switch (`resetPerListUIState()`), and calls `AppState.createTaskList(title:)`, which selects the new list; an empty Enter or Escape restores the picker and hands focus to quick add. The field also closes on a list switch, a detail push, and in `viewDidDisappear`. `TaskListHeaderView` keeps the picker and the field in one container (so hiding one keeps the header height) and only toggles them on `isComposingNewList` transitions, so background re-renders never clear what is being typed; a low-priority width constraint activated while composing lets the field take the width the picker's title leaves. AppKit can dispatch "New List…" through the item's action, the popup's action, or both, so the controller's open path is idempotent.
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
- Animations must respect `NSWorkspace.accessibilityDisplayShouldReduceMotion`; new custom layer colors need refreshing in `viewDidChangeEffectiveAppearance()` so appearance switches don't leave stale CGColors (the header's new-list box does this like the quick-add and filter boxes).
