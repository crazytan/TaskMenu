# Changelog

## TODO

- macOS widgets (WidgetKit)
- Global keyboard shortcut (Cmd+Shift+T)
- Multiple Google accounts

## Unreleased

### Added
- Animated task-list updates: completing, adding, deleting, and reordering tasks now slide/fade rows into place instead of snapping, including the Completed section and completed-subtasks disclosures. Row animations respect the system Reduce Motion setting, and list switches or search keystrokes still render instantly without animation.
- A navigation slide transition between the task list and the task edit screen (with a parallax return), also honoring Reduce Motion.
- The list and the empty state now crossfade instead of swapping abruptly.
- A "Notes" placeholder in the task edit screen's notes field, plus an accessibility label for VoiceOver.
- Task checkboxes and subtask disclosure chevrons now include the task title in their accessibility labels, and the refresh/loading spinners are labeled for VoiceOver.
- Drag-and-drop task reordering in the popover task list, synced to Google Tasks via the move API: reorder top-level tasks, reorder subtasks within their parent, drop a task onto a top-level task to nest it as a subtask, and drag a subtask out to the top level. A parent dragged with its subtasks moves as a family; the new order is applied optimistically and rolled back if the sync fails.
- Restored the task search/filter bar in the popover, lost in the AppKit rewrite: real-time title/notes filtering, result count, matching subtasks shown with their parents, and an auto-expanded Completed section during search.
- Added Homebrew tap installation instructions and release maintenance notes.
- Added an opt-in testing window UI mode for local AppKit interaction outside the menu bar popover.
- Added a right-click Delete action for task rows in the popover task list.
- Added seeded task data for testing-window verification.
- Added a Long Subtasks testing-window list with a parent task containing 12 subtasks, including several completed subtasks.

### Changed
- Redesigned the Settings window with native macOS grouped sections: rounded setting boxes with switch rows, a single Updates row combining version and check status, a compact Account row, side-by-side tips/Discord buttons with one prominent call to action, link-style About buttons, and a standard (non-red) Quit button. Destructive actions now use red text instead of filled red buttons, single-color button icons render as templates, and the group backgrounds follow light/dark appearance changes.
- Refreshed Markdown documentation for current Xcode project settings, release workflow, testing-window behavior, and Google Tasks API boundaries.
- Simplified task caching to a single per-list cache after removing the unused first-load/completed-task cache path.

### Removed
- Removed dead code left over from the SwiftUI-to-AppKit migration: the unused `TaskRowAppKitView`, task indent/outdent support, the never-called `loadTasks` first-load path, the unused `moveTask` API, and obsolete presentation/layout helpers and their tests.

### Fixed
- The "Delete Task" button in the edit screen now renders in red; its destructive tint was silently ignored on bordered buttons.
- Quick-add and search bar backgrounds now refresh their layer colors when the system appearance changes instead of keeping stale light/dark colors.
- Long list names no longer collide with the centered "Edit Task" title; the back button truncates.
- Menu and status labels consistently use the typographic ellipsis (…) instead of three periods.
- Completing a parent task now also completes its open subtasks (matching Google Tasks behavior), and incomplete subtasks under completed parents stay visible in the Completed section instead of disappearing from the list.
- Kept the Completed section reachable when every task is done; the "No open tasks" empty state now appears only when the list is truly empty.
- Escape now reaches the quick-add and add-subtask fields (clearing text, dismissing the inline field, or closing the popover) instead of being swallowed by the field editor.
- Task detail editor: an empty title no longer overwrites the existing title, notes are saved trimmed, the subtask list keeps its scroll position when toggling subtasks, and due dates typed into the picker are saved on Done even without committing the field.
- Due-today notifications no longer re-fire on every task refresh after being dismissed.
- The new-task flash highlight now tracks the created task's ID instead of matching rows by title.
- OAuth error redirects now surface the real error (for example `access_denied`) instead of a misleading state-mismatch message, and empty access tokens are no longer written to the Keychain.
- Aligned the completed-section divider, disclosure chevron, completed task check icons, and subtask rows with the main task list rows.
- Restored per-parent completed-subtask disclosure rows for open tasks, tightened their spacing, and kept those subtasks out of the global Completed section.
- Kept the task detail metadata group at its compact two-row height and hid the unset due-date picker until Set is clicked.
- Restored scrolling for long subtask lists in the task detail editor.
- Fixed clipping of completed subtask rows in the task detail editor when several completed subtasks are visible.
- Centered the task detail title in the edit header.
- Fixed the right-click Delete menu on task rows, which never appeared because the cell-level context menu was bypassed by the outline view.
- Fixed the completed-section header so clicking anywhere on the row reliably expands or collapses it.
- Replaced the built-in outline disclosure triangle (which overlapped the completion circle) with a dedicated chevron column that is vertically aligned across task rows and the completed-section header, and indented subtask rows under their parents.
- Left-aligned the Subtasks header, subtask rows, and Add subtask control in the task detail view.

## v1.2.0 (2026-05-16)

### Added
- Added a Support section in Settings with a Discord invite for bugs and feature requests.
- Added GitHub release update checks, including a Settings toggle, manual check button, and launch alert for new versions.

### Changed
- Reworked Settings into clearer General, Account, Support, and About sections.
- Added signed-in account details and clearer support options in Settings.
- Improved task list, task row, subtask, and task detail controls for better spacing, placement, scrolling, and animation.
- Made destructive Settings actions clearer and added confirmation before disconnecting.

### Fixed
- Added a visible Quit TaskMenu control to the signed-out view.
- Kept the menu bar icon highlighted while the popover is open.

## v1.1.0 (2026-05-08)

### Added
- Task notes previews in the main task list, including subtask notes.
- A per-parent reveal row for completed subtasks under active parents.

### Changed
- Moved settings into a dedicated native macOS Settings window.
- Placed the inline add-subtask field before existing subtasks.
- Kept long subtask lists scrollable inside the task detail view.
- Improved task loading by showing cached lists immediately, refreshing the current list when the popover opens, and showing an initial loading state at launch.
- Matched Google Tasks sibling ordering by task position, while keeping completed subtasks at the end when revealed.
- Updated public website, privacy, terms, and settings wording for DMG distribution.

### Fixed
- Improved Google sign-in reliability and error handling.
- Closed the menu bar popover more reliably when clicking outside it.
- Synced Google Tasks due-date updates and clears more reliably.
- Preserved Google Tasks due dates as local calendar days so web and app dates match across time zones.

### Removed
- The experimental full-window Liquid Glass setting.

## v1.0.1 (2026-05-04)

### Added
- Added a right-click menu on the menu bar icon with a Quit action

### Fixed
- Made the task completion checkbox hover target more reliable and preview the checkmark before clicking
- Removed the unstable global keyboard shortcut implementation that interfered with the menu bar window opening
- Removed the shortcut toggle and private AppKit menu bar click simulation, restoring default `MenuBarExtra` behavior

## v1.0.0 (2026-03-08)

Initial release — menu bar app for Google Tasks.

### Features
- **Menu bar app** — lives in the system tray, no dock icon
- **Google OAuth 2.0** — sign in with PKCE + client secret, loopback redirect
- **Task lists** — switch between Google Tasks lists via dropdown
- **Task management** — view, create, edit, delete, and complete tasks
- **Quick add** — inline text field for fast task creation
- **Due dates** — date picker in task detail view
- **Keychain storage** — OAuth tokens stored securely in macOS Keychain
- **Launch at login** — optional setting
- **23 unit tests** — models, keychain, date formatting

### Technical
- Swift 6, strict concurrency
- SwiftUI MenuBarExtra (.window style)
- macOS 14+ (Sonoma)
- No SPM dependencies — Apple frameworks only
