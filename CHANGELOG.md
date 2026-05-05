# Changelog

## TODO

- macOS widgets (WidgetKit)
- Global keyboard shortcut (Cmd+Shift+T)
- Multiple Google accounts

## Unreleased

- Added MetricKit collection

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

### Known Issues
- Google Cloud project in "Testing" mode — OAuth consent limited to test users
