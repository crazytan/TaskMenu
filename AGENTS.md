# TaskMenu — macOS Menu Bar App for Google Tasks

> **Working title.** Final name TBD.

## Overview
A lightweight, native macOS menu bar app that provides quick access to Google Tasks. Built with SwiftUI, targeting macOS 14+. Free and open source (GPLv3).

## Architecture

### Tech Stack
- **Language:** Swift 6 (strict concurrency)
- **UI:** SwiftUI (menu bar popover via MenuBarExtra)
- **Build:** Xcode project via XcodeGen (`project.yml`)
- **Auth:** OAuth 2.0 with PKCE via ASWebAuthenticationSession
- **Networking:** URLSession + async/await
- **Storage:** Keychain (tokens), UserDefaults/SwiftData (local cache)
- **Min target:** macOS 14.0 (Sonoma)

### Project Structure
```
TaskMenu/
├── project.yml              # XcodeGen project definition
├── TaskMenu/
│   ├── TaskMenuApp.swift     # @main, MenuBarExtra setup
│   ├── Views/
│   │   ├── MenuBarPopover.swift    # Main popover view
│   │   ├── TaskListView.swift      # List of tasks
│   │   ├── TaskRowView.swift       # Individual task row
│   │   ├── TaskDetailView.swift    # Edit/view task details
│   │   ├── QuickAddView.swift      # Inline quick-add field
│   │   ├── ListPickerView.swift    # Switch between task lists
│   │   └── SignInView.swift        # OAuth sign-in prompt
│   ├── Models/
│   │   ├── TaskItem.swift          # Google Task model
│   │   ├── TaskList.swift          # Google Task List model
│   │   └── AppState.swift          # Observable app state
│   ├── Services/
│   │   ├── GoogleAuthService.swift     # OAuth 2.0 + PKCE + token refresh
│   │   ├── GoogleTasksAPI.swift        # Google Tasks REST API client
│   │   ├── KeychainService.swift       # Secure token storage
│   │   └── NotificationService.swift   # Due date notifications (phase 2)
│   ├── Utilities/
│   │   ├── Constants.swift         # API URLs, client ID placeholder
│   │   └── DateFormatting.swift    # RFC 3339 date helpers
│   └── Resources/
│       ├── Assets.xcassets         # Menu bar icon, app icon
│       └── Info.plist
├── TaskMenuTests/
│   └── ...
├── LICENSE                  # GPLv3
├── README.md
└── STATUS.md                # Build progress tracking
```

### Google Tasks API
- **Base URL:** `https://tasks.googleapis.com/tasks/v1`
- **Endpoints needed:**
  - `GET /users/@me/lists` — list all task lists
  - `GET /lists/{tasklistId}/tasks` — list tasks in a list
  - `POST /lists/{tasklistId}/tasks` — create task
  - `PATCH /lists/{tasklistId}/tasks/{taskId}` — update task (title, notes, due, status)
  - `DELETE /lists/{tasklistId}/tasks/{taskId}` — delete task
  - `POST /lists/{tasklistId}/tasks/{taskId}/move` — reorder task
- **Scopes:** `https://www.googleapis.com/auth/tasks`
- **Auth:** OAuth 2.0 with PKCE (desktop app flow)
  - Use `ASWebAuthenticationSession` to open Google sign-in
  - Loopback redirect to `http://127.0.0.1:{port}/callback`
  - Exchange auth code for access + refresh tokens
  - Store tokens in Keychain
  - Auto-refresh access token when expired

### OAuth 2.0 Flow (Desktop App with PKCE)
1. Generate random `code_verifier` (43-128 chars, URL-safe)
2. Compute `code_challenge` = Base64URL(SHA256(code_verifier))
3. Open browser: `https://accounts.google.com/o/oauth2/v2/auth?client_id=...&redirect_uri=http://127.0.0.1:{port}/callback&response_type=code&scope=...&code_challenge=...&code_challenge_method=S256`
4. Start local HTTP server on `127.0.0.1:{port}` to catch redirect
5. Exchange code at `https://oauth2.googleapis.com/token` with code_verifier
6. Receive `access_token` + `refresh_token`
7. Store in Keychain, refresh when access_token expires

### Key Design Decisions
- **MenuBarExtra with `.window` style** — gives us a proper popover panel
- **No Electron** — pure SwiftUI, <10MB binary
- **Offline-friendly** — cache tasks locally, sync on reconnect
- **Client ID placeholder** — use `YOUR_CLIENT_ID` in Constants.swift; users/dev must provide their own Google Cloud credentials until OAuth verification is complete
- **No app window** — menu bar only (LSUIElement = YES in Info.plist)
- **Global keyboard shortcut** — Cmd+Shift+T to open popover (phase 2)

## Build Phases

### Phase 1: Core (MVP) ← BUILD THIS
1. **Project setup** — XcodeGen project.yml, app structure, entitlements
2. **Menu bar shell** — MenuBarExtra with empty popover, app icon
3. **OAuth flow** — GoogleAuthService with PKCE, token storage in Keychain
4. **API client** — GoogleTasksAPI with all CRUD endpoints
5. **Task list view** — show tasks from default list, check/uncheck
6. **List picker** — switch between task lists
7. **Quick add** — text field at top of popover to create tasks
8. **Edit task** — tap to edit title, notes, due date
9. **Delete task** — swipe or context menu to delete
10. **Pull to refresh** — refresh tasks from API
11. **Error handling** — sign-in expired, network errors, API errors
12. **Settings** — sign out, about, launch at login

### Phase 2: Polish (later)
- macOS widgets (WidgetKit)
- Global keyboard shortcut (Cmd+Shift+T)
- Due date notifications
- Multiple Google accounts
- Drag-and-drop reordering
- Subtask support (indent/outdent)
- Search/filter tasks

## Build Instructions
```bash
# Generate Xcode project
xcodegen generate

# Build
xcodebuild -scheme TaskMenu -configuration Debug build

# Run tests
xcodebuild -scheme TaskMenu -configuration Debug test
```

## Conventions
- Update STATUS.md after completing each phase/milestone
- Commit after each logical unit of work with descriptive messages
- Use Swift strict concurrency (@Sendable, actors where needed)
- All API calls must handle errors gracefully (no force unwraps on network data)
- Keep the binary small — no SPM dependencies unless absolutely necessary
