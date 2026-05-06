# Views

Views render the menu-bar popover and settings UI. Keep business behavior in `AppState`; keep view files focused on presentation, local interaction state, and small pure helpers that can be unit-tested.

## Files

- `MenuBarPopover.swift` - signed-out, initial-loading, signed-in task list, bottom error strip, settings button, and popover surface styling.
- `TaskListView.swift` - list picker, search, quick add, active/completed sections, subtask display, inline subtasks, drag-and-drop reordering, and drop delegates.
- `TaskRowView.swift` - row layout, completion toggle, notes preview, due-date label coloring, collapse and add-subtask actions.
- `TaskDetailView.swift` - edit sheet, due-date state, notes, delete action, and child task preview.
- `QuickAddView.swift` - inline root-task creation.
- `ListPickerView.swift` - selected Google task-list picker.
- `SignInView.swift` - OAuth entry screen.
- `SettingsView.swift` - notification preference, experimental glass toggle, launch-at-login, account disconnect, and quit controls.
- `MenuBarWindowGlassSupport.swift` - macOS 26 full-window Liquid Glass AppKit bridge.

## UI Ownership

- Views receive `@Bindable var appState: AppState` and call `AppState` methods for mutations.
- Keep network, keychain, OAuth, and notification calls out of views.
- `MenuBarPopover` owns the popover's fixed signed-in size. Avoid growing the popover dynamically unless all task-list states are checked.
- `SettingsView` is a settings scene, not the main task UI.

## Task List Interaction Rules

- Active and completed rows use different identities so completion transitions do not confuse SwiftUI diffing.
- Drag-and-drop only reorders active tasks among siblings with the same parent.
- Inline subtask creation appears immediately after the selected parent and hides during search.
- Completed subtasks under active parents are hidden until explicitly revealed; search reveals matching context.
- Keep helper functions pure when possible and cover interaction logic in `TaskListViewTests`.

## Styling Notes

- Use SF Symbols for UI icons.
- Preserve the compact 320-point menu-bar popover design.
- macOS 26 Liquid Glass support is gated by availability and the experimental user default.
- Avoid adding instructional text to the UI; controls should be self-explanatory in context.
