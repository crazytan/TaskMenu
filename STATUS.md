# STATUS.md — TaskMenu Build Progress

## Current Phase: Phase 1 (MVP) — COMPLETE

### Completed
- [x] Project setup (XcodeGen project.yml, directory structure, entitlements, Info.plist)
- [x] Menu bar shell (MenuBarExtra with .window style popover, SF Symbol 'checklist' icon)
- [x] OAuth 2.0 with PKCE (GoogleAuthService — loopback server, code exchange, token refresh)
- [x] Keychain token storage (KeychainService — save/read/delete via Security framework)
- [x] Google Tasks API client (GoogleTasksAPI — list lists, list/create/update/delete/move tasks)
- [x] Task list view (TaskListView — show tasks, check/uncheck, completed section)
- [x] List picker (ListPickerView — dropdown to switch between task lists)
- [x] Quick add task (QuickAddView — inline text field at top of popover)
- [x] Edit task (TaskDetailView — title, notes, due date picker, delete)
- [x] Delete task (context menu + detail view)
- [x] Error handling (APIError enum — unauthorized, network, server, decoding)
- [x] Settings (SettingsView — sign out, launch at login, quit, version info)
- [x] Unit tests (23 tests — KeychainService, GoogleTasksAPI models, DateFormatting)

### Build Status
- `xcodebuild build` — SUCCEEDED (0 errors, 0 warnings)
- `xcodebuild test` — SUCCEEDED (23/23 tests pass)

### Architecture
- Swift 6 strict concurrency (complete checking)
- SwiftUI MenuBarExtra with .window style
- LSUIElement = YES (no dock icon)
- App Sandbox with network client + server entitlements
- No SPM dependencies — Apple frameworks only
- macOS 14.0+ (Sonoma) target

### Blockers
- None

### Notes
- Using placeholder `YOUR_GOOGLE_CLIENT_ID` in Constants.swift — real credentials need Google Cloud project setup
- OAuth redirect uses loopback server on random ephemeral port (127.0.0.1)
- Hardened runtime disabled for ad-hoc signing during development
