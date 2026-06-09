# Changelog

## TODO

- macOS widgets (WidgetKit)
- Global keyboard shortcut (Cmd+Shift+T)
- Multiple Google accounts

## Unreleased

### Added
- Added Homebrew tap installation instructions and release maintenance notes.

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
