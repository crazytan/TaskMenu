# Changelog

## TODO

- macOS widgets (WidgetKit)
- Global keyboard shortcut (Cmd+Shift+T)
- Multiple Google accounts

## Unreleased

- Added MetricKit collection
- Use ASWebAuthenticationSession's modern callback API for Google OAuth, remove the local callback server, and drop the incoming network entitlement.
- Fix Google OAuth callback crash handling and surface token exchange configuration errors during sign-in.
- Show task notes previews in the main task list, including subtask notes.
- Moved settings into a dedicated native macOS Settings window.
- Place the inline add-subtask field before existing subtasks.
- Keep long subtask lists scrollable inside the task detail view.
- Cache tasks per list so switching lists shows cached tasks immediately and ignores stale refreshes.
- Bootstrap signed-in task loading at launch and show an initial loading state.
- Refresh the current task list each time the menu bar popover opens.
- Close the menu bar popover more reliably when clicking outside it.
- Verify Google Tasks due-date updates and clears sync through PATCH responses.
- Preserve Google Tasks due dates as local calendar days so web and app dates match across time zones.
- Hide completed subtasks under active parents by default with a per-parent reveal row.
- Match Google Tasks sibling ordering by task position, while keeping completed subtasks at the end when revealed.
- Show drag insertion indicators and keep drag moves constrained to same-level tasks.
- Declare the task drag-and-drop UTI in the app bundle to silence LaunchServices warnings.
- Updated launch-facing website, README, privacy, terms, and settings wording for public DMG distribution.
- Exclude folder-local agent README files from Xcode targets so documentation does not get copied into the app bundle.

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
