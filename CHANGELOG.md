# Changelog

## TODO

- macOS widgets (WidgetKit)
- Global keyboard shortcut (Cmd+Shift+T)
- Multiple Google accounts

## Unreleased

### Changed
- **Discord is now an About link** in Settings, next to GitHub, Support, and Privacy.
- **Mac App Store builds** come from a separate `AppStore` configuration that leaves out the update checker and the tips link, since the App Store delivers its own updates and requires In-App Purchase for donations. Settings there shows a plain version row. Direct-download builds are unchanged.

### Fixed
- **A subtask added from the right-click menu could show up in the wrong slot** — it landed below an older subtask until the next refresh moved it to the top, where Google actually puts it. The list now shows it at the top right away, matching the order on the Google Tasks website.
- **"Explore the Demo" did nothing if you had started a Google sign-in and backed out of it** — the demo now takes over from the abandoned attempt instead of waiting for it.

### Added
- **Create a task list from the popover** — the list picker now ends with "New List…". Choose it, type a name in the header, and press Enter; the new list is created in Google Tasks and opened right away. Escape or an empty Enter puts the picker back. Works in demo mode too (the list lasts for the demo session).
- **Pending-task count in the menu bar** — Settings → General → "Show in menu bar" can put the number of open tasks, or of tasks due today (overdue included), next to the menu bar icon. It counts every list in your account (or every demo list), drops as soon as you complete a task, and refreshes in the background every five minutes. Off by default.
- **Sort by due date** — the "…" menu has a "Sort by" submenu with "My order" (Google's order, the default) and "Due date", which lists overdue tasks first, then today, tomorrow, and later, with undated tasks at the end. Subtasks stay under their parent in their usual order. Drag-and-drop reordering pauses while sorted by due date, since the list no longer shows Google's positions.
- **Add a subtask straight from the list** — right-click a task and choose "Add Subtask" to get an inline field under it. Enter creates the subtask and keeps the field open for the next one; an empty Enter or Escape closes it.
- **Demo mode** — an "Explore the Demo" button on the sign-in screen opens the app on sample task lists, so you can try everything without connecting a Google account. Nothing leaves your Mac: no sign-in, no network, no reminders, and the sample edits are discarded when you leave. A banner above the list marks the session and exits back to sign-in, as do "Exit demo" in the "…" menu and Settings.

## v1.4.0 (2026-08-03)

### Added
- **Calendar picker for due dates** — the task editor's due-date row now has a calendar button that opens a month view, so you can pick a date instead of only typing or stepping it. Escape or clicking elsewhere dismisses it without discarding your edit.
- **Keyboard shortcuts** — ⌘N and ⌘F jump to the "Add a task" and "Filter tasks" fields, ⌘, opens Settings, and ⌘Q quits from the popover or Settings.
- **Settings… in the menu bar icon's right-click menu**, above Quit TaskMenu.
- Settings now shows the git commit a build came from next to the version number, e.g. `Version 1.4.0 (a1b2c3d)`.

### Changed
- The task editor's "Add subtask" row now sits above the subtask list, so it stays in place as subtasks are added, and its icon and label line up with the subtasks below.
- The popover's "…" overflow menu no longer draws separators between its items.

### Fixed
- **Copy, Cut, Paste, Select All, and Undo now work in every text field** — filter, quick add, task title, notes, and add subtask. These shortcuts were previously dropped.
- **Opening a task now actually slides in** instead of jumping in a single frame, with the list parallaxing behind it.

## v1.3.0 (2026-07-25)

### Added
- **Drag-and-drop task reordering**, synced to Google Tasks: reorder top-level tasks, reorder subtasks within a parent, drop a task onto another to nest it as a subtask, and drag a subtask back out to the top level. A parent moves together with its subtasks, and a failed sync rolls the order back.
- **Task search** returns to the popover: real-time title and notes filtering, a result count, matching subtasks shown with their parents, and an auto-expanded Completed section while searching.
- **Right-click Delete** on task rows in the popover list.
- **Animated task-list updates** — completing, adding, deleting, and reordering slide and fade into place, including the Completed section and completed-subtask disclosures. The task list and edit screen now transition with a slide (and parallax on return), and the list and empty state crossfade. All animations respect Reduce Motion; list switches and search keystrokes stay instant.
- **Accessibility improvements** — task checkboxes and subtask chevrons include the task title in their VoiceOver labels, refresh and loading spinners are labeled, and the notes field has a placeholder and label.
- **"Skip This Version"** in the update alert, for permanently dismissing a release.
- The cursor now shows a pointing hand over task completion circles.

### Changed
- **Redesigned Settings window** with native macOS grouped sections: rounded setting boxes, a combined Updates row, a compact Account row, side-by-side tips and Discord buttons, link-style About buttons, and a standard Quit button. Destructive actions now use red text instead of filled red buttons, and group backgrounds follow light/dark appearance changes.
- **Completing a parent task now also completes its open subtasks**, matching Google Tasks. Incomplete subtasks under completed parents stay visible in the Completed section.
- **Automatic update checks re-run every 24 hours** while the app is running instead of only at launch; "Later" now re-alerts on the next cycle.
- Diagnostic reports are deduplicated and pruned on launch (30-day retention, 200-file cap) instead of accumulating indefinitely.

### Fixed
- **Due dates were corrupted for non-Gregorian system calendars** (for example Buddhist or Japanese) — dates now always use Gregorian years on the wire, instead of showing other clients' tasks centuries off and sending era years to Google.
- **A temporary Google outage no longer signs you out** — only a definitive credential rejection clears the stored login.
- Signing out while a load, edit, or notification sync was in flight no longer leaks the previous account's tasks into the next session or re-schedules cleared notifications.
- A task quick-added during a refresh no longer vanishes when the stale fetch lands, and tasks added while switching lists now land in the list they were created in.
- Failed completion and reorder requests now roll back only the affected task, preserving edits made while the request was in flight.
- Deleting a parent task removes all nested subtask descendants, not just direct children.
- Concurrent requests with an expired session now share a single token refresh instead of each firing their own.
- Clicking a parent's chevron now actually expands and collapses its subtasks.
- **Notifications** — dismissing the 9 AM "Due today" reminder no longer produces a duplicate later that day or re-fires on every refresh; the overnight sync no longer clears reminders for still-overdue tasks; scheduling stays under the system's 64-request limit by prioritizing the soonest due dates; and rapidly toggling the notifications preference now settles on the last chosen state.
- **Task editor** — an empty title no longer overwrites the existing title, notes save trimmed, a due date typed into the picker saves on Done, the subtask list keeps its scroll position, and a background refresh mid-edit no longer discards uncommitted typing or steals keyboard focus.
- **Keyboard** — arrow keys browse the task list without opening the edit screen (Return opens it), and Escape reaches the quick-add and add-subtask fields to clear text, dismiss the field, or close the popover.
- Control-clicking the menu bar icon now opens the same context menu as right-clicking.
- A failed "Launch at login" toggle now shows an alert with the error and a shortcut to Login Items settings, including when macOS holds registration pending approval.
- Disconnecting now reports when Google-side revocation failed, with a pointer to myaccount.google.com/permissions, instead of silently claiming access was revoked.
- The signed-out popover updates in place — a cancelled or failed sign-in restores the button and shows the error.
- The search result count no longer counts non-matching parent rows shown for context.
- Task lists beyond the API's first page are now fetched.
- An unrecognizable GitHub release tag now surfaces as a failed update check instead of a false "Up to date".
- The Completed section stays reachable when every task is done; "No open tasks" appears only when the list is truly empty.
- **Visual polish** — quick-add and search backgrounds, the edit screen's metadata group, and the footer now refresh correctly on light/dark appearance changes; the "Delete Task" button renders in red; long list names no longer collide with the centered "Edit Task" title; completed-section and subtask rows are aligned with the main list; long subtask lists scroll again and no longer clip; the new-task flash highlight tracks the created task instead of matching by title; and labels consistently use a typographic ellipsis.

### Security
- OAuth tokens now live in the data-protection keychain with a device-only accessibility class, with transparent one-time migration of existing tokens.
- Sign-in aborts if the system random generator fails, instead of proceeding with a predictable PKCE verifier and state value.
- OAuth error redirects surface the real error (for example `access_denied`) instead of a misleading state-mismatch message, and empty access tokens are no longer written to the Keychain.

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
