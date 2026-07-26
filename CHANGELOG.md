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
- OAuth tokens are now stored in the data-protection keychain with a device-only accessibility class, with transparent one-time migration of existing tokens from the legacy login-keychain location.
- MetricKit diagnostic payloads are now deduplicated by content and pruned on launch (30-day retention, 200-file cap) instead of accumulating duplicates indefinitely.
- Hardened the release pipeline: manual release runs are now bound to the existing tag's commit, published release assets can no longer be overwritten in place, workflow inputs are injection-safe, key-derived data is no longer logged, the CI token is scoped read-only, notarization rejections now print the actual notarytool log instead of an opaque stapler error, and the Gatekeeper assessment now runs as a real gate after stapling instead of a no-op.
- Redesigned the Settings window with native macOS grouped sections: rounded setting boxes with switch rows, a single Updates row combining version and check status, a compact Account row, side-by-side tips/Discord buttons with one prominent call to action, link-style About buttons, and a standard (non-red) Quit button. Destructive actions now use red text instead of filled red buttons, single-color button icons render as templates, and the group backgrounds follow light/dark appearance changes.
- Refreshed Markdown documentation for current Xcode project settings, release workflow, testing-window behavior, and Google Tasks API boundaries.
- Simplified task caching to a single per-list cache after removing the unused first-load/completed-task cache path.

### Removed
- Removed dead code left over from the SwiftUI-to-AppKit migration: the unused `TaskRowAppKitView`, task indent/outdent support, the never-called `loadTasks` first-load path, the unused `moveTask` API, and obsolete presentation/layout helpers and their tests.

### Fixed
- Clicking a parent task's subtask chevron now actually expands and collapses its subtasks. The arrow flipped direction but the subtask rows never hid or reappeared, because suppressing the outline view's built-in disclosure cell through the delegate also made it reject programmatic expand/collapse for those rows.
- Google Tasks due dates are no longer corrupted for users whose system calendar is not Gregorian (for example Buddhist or Japanese): dates read from and written to the Google Tasks API now always use Gregorian years on the wire, instead of rendering other clients' tasks centuries off and sending era years (like 2569) to Google.
- A transient Google token-endpoint failure (5xx or rate limit) during token refresh no longer silently signs the user out and deletes the stored refresh token; only a definitive `invalid_grant`/`invalid_client` rejection does.
- Concurrent API calls with an expired access token now share a single token refresh request instead of each firing their own.
- A task quick-added while the popover's refresh was still in flight no longer vanishes when the stale fetch lands; fetched snapshots are discarded whenever a local change committed during the fetch.
- Tasks added while switching lists now land in the list they were created in instead of the list being displayed when the request finished.
- Signing out while a list load, task mutation, or notification sync is in flight no longer repopulates the signed-out state, leaks the previous account's tasks into the next session, or re-schedules notifications after they were cleared.
- Failed toggle and move requests now roll back only the affected task, preserving edits committed while the request was in flight.
- Deleting a parent task now removes all nested subtask descendants from the local list, not just direct children.
- Dismissing the 9 AM "Due today" reminder no longer produces a duplicate notification at the next sync that day.
- The overnight notification sync no longer clears delivered reminders for overdue tasks that are still incomplete.
- Notification scheduling now stays under the system's 64-pending-request limit, prioritizing the soonest due dates.
- Rapidly toggling the due-date notifications preference now always converges on the last chosen state.
- The search result count no longer counts non-matching parent rows shown for context ("2 results" instead of "3" when two tasks match).
- The signed-out popover now updates in place: cancelling or failing the Google sign-in flow restores the sign-in button and shows the error, instead of leaving a stale in-progress button with no feedback.
- Arrow keys now browse the task list without immediately opening the edit screen; Return/Enter opens the selected task.
- Control-clicking the menu bar icon now opens the same context menu as right-clicking.
- Failures toggling "Launch at login" now show an alert with the error and a shortcut to Login Items settings instead of silently snapping the switch back, including when macOS holds the registration pending user approval.
- The task edit screen no longer rebuilds the due-date picker or steals focus into the add-subtask field when a background refresh lands mid-edit; uncommitted typing and keyboard focus survive.
- The task edit screen's metadata group and footer now follow light/dark appearance changes instead of keeping stale colors.
- Disconnecting now reports when Google-side revocation failed (with a pointer to myaccount.google.com/permissions) instead of silently pretending access was revoked.
- Automatic update checks now re-run every 24 hours while the app stays running instead of only once at launch; "Later" on the update alert re-alerts at the next cycle, and a new "Skip This Version" button provides the permanent dismissal that "Later" previously (and silently) was.
- An unrecognizable GitHub release tag now surfaces as a failed update check in Settings instead of a false "Up to date".
- Task lists beyond the API's first page are now fetched via pagination.
- Sign-in now aborts if the system random generator fails instead of proceeding with a predictable PKCE verifier and state value.
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
