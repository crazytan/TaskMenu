# TaskMenu

## Project Overview

TaskMenu is a lightweight, native macOS menu bar application for quick access to Google Tasks. It is a free and open-source (GPLv3) SwiftUI app targeting macOS 14+ (Sonoma). The app lives entirely in the menu bar (no dock icon, no main window).

**Current status:** Phase 1 MVP complete (v0.1.0). Phase 2 features (widgets, notifications, multiple accounts) are planned but not yet started.

## Tech Stack

- **Language:** Swift 6 with strict concurrency (`SWIFT_STRICT_CONCURRENCY: complete`)
- **UI:** SwiftUI — MenuBarExtra with `.window` style
- **Build system:** XcodeGen (`project.yml`) + Xcode 16.0
- **Auth:** OAuth 2.0 with PKCE (loopback redirect to `127.0.0.1`)
- **Networking:** URLSession with async/await
- **Token storage:** macOS Keychain via Security framework
- **Dependencies:** Zero — Apple frameworks only
- **Min deployment target:** macOS 14.0

## Project Structure

```
TaskMenu/
├── project.yml                    # XcodeGen project definition (source of truth)
├── Config.xcconfig.example        # OAuth credential template
├── AGENTS.md                      # Architecture & phase plan
├── TaskMenu/
│   ├── TaskMenuApp.swift          # @main entry point, MenuBarExtra setup
│   ├── Models/
│   │   ├── AppState.swift         # @Observable centralized app state (@MainActor)
│   │   ├── TaskItem.swift         # Google Task model (Codable, Sendable)
│   │   └── TaskList.swift         # Google Task List model (Codable, Sendable)
│   ├── Services/
│   │   ├── GoogleAuthService.swift    # OAuth 2.0 + PKCE flow (@MainActor)
│   │   ├── GoogleTasksAPI.swift       # Google Tasks REST client (actor)
│   │   └── KeychainService.swift      # Keychain CRUD wrapper (Sendable)
│   ├── Views/
│   │   ├── MenuBarPopover.swift       # Main popover container
│   │   ├── TaskListView.swift         # Task list with completed section
│   │   ├── TaskRowView.swift          # Single task row with toggle
│   │   ├── TaskDetailView.swift       # Edit task sheet
│   │   ├── QuickAddView.swift         # Inline task creation
│   │   ├── ListPickerView.swift       # Task list switcher
│   │   ├── SignInView.swift           # OAuth sign-in screen
│   │   └── SettingsView.swift         # Settings & sign out
│   ├── Utilities/
│   │   ├── Constants.swift            # API URLs, OAuth config, keychain keys
│   │   └── DateFormatting.swift       # RFC 3339 parsing/formatting
│   └── Resources/
│       ├── Info.plist                 # LSUIElement=YES, version, OAuth vars
│       ├── TaskMenu.entitlements
│       └── Assets.xcassets
├── TaskMenuTests/
│   ├── KeychainServiceTests.swift     # Keychain CRUD tests
│   ├── DateFormattingTests.swift      # Date parsing/formatting tests
│   └── GoogleTasksAPITests.swift      # Model decoding/encoding tests
└── TaskMenu.xcodeproj/               # Generated — do not edit directly
```

## Build & Test Commands

```bash
# Generate Xcode project from project.yml (run after changing project.yml)
xcodegen generate

# Build
xcodebuild -scheme TaskMenu -configuration Debug build

# Run tests
xcodebuild -scheme TaskMenu -configuration Debug test
```

**OAuth setup:** Copy `Config.xcconfig.example` to `Config.xcconfig` and fill in `GOOGLE_CLIENT_ID` and `GOOGLE_CLIENT_SECRET`. This file is gitignored.

## Architecture & Patterns

### Concurrency Model (Swift 6 strict)
- **AppState:** `@MainActor`, `@Observable` — centralized state management
- **GoogleAuthService:** `@MainActor`, `Sendable` — auth operations
- **GoogleTasksAPI:** `actor` — network-isolated API client
- **KeychainService:** `struct`, `Sendable` — thread-safe keychain access
- **All models:** `Sendable`, `Codable`, `Identifiable`

### State Management
- `AppState` is the single source of truth, injected via SwiftUI environment
- Views use `@Bindable` for two-way binding, `@State` for local state
- Auth state, task lists, selected list, tasks, and errors flow from AppState

### Service Layer
- `GoogleAuthService` handles the full OAuth 2.0 PKCE flow including token refresh
- `GoogleTasksAPI` wraps all Google Tasks REST endpoints with typed errors
- `KeychainService` abstracts macOS Keychain (SecItem APIs)

### Error Handling
- `APIError` enum: unauthorized, networkError, serverError, decodingError
- `KeychainError` enum for storage failures
- Errors surface to UI via `AppState.errorMessage`
- No force unwraps on network data

## Code Conventions

- **Zero dependencies:** Prefer Apple frameworks. Do not add SPM packages unless absolutely necessary.
- **Binary size:** Keep under 10MB.
- **Strict concurrency:** All new code must compile with `SWIFT_STRICT_CONCURRENCY: complete`. Use `@Sendable`, actors, and `@MainActor` as appropriate.
- **No force unwraps** on network/external data. Use proper error handling.
- **System icons:** Use SF Symbols — no custom image assets for UI icons.
- **Menu bar only:** The app has no main window (`LSUIElement = YES`). All UI is in the MenuBarExtra popover.
- **Commit discipline:** Each commit should be a logical unit of work with a descriptive message.

## Git Workflow

- **Default workflow:** Commit and push directly to `main` when working in the primary checkout.
- **No separate PR/branch by default:** Do not create feature branches or pull requests unless explicitly requested.
- **Worktree exception:** When working from a git worktree, use a separate branch for that worktree. Open a PR only if that worktree-based flow needs one.

## Testing Guidelines

- **Always update or add tests when modifying code.** Any change to models, services, or utilities must include corresponding test updates in `TaskMenuTests/`.
- Test files follow the naming convention `<SourceFile>Tests.swift`.
- Use a unique keychain service name in test setUp to avoid cross-test contamination (e.g., `KeychainService(service: "com.taskmenu.test.\(UUID().uuidString)")`).
- Mark test classes that touch `@MainActor` types with `@MainActor`.

## Important Files

| File | Purpose |
|------|---------|
| `project.yml` | XcodeGen config — regenerate `.xcodeproj` after edits |
| `Config.xcconfig` | OAuth credentials (gitignored) |
| `Constants.swift` | All API URLs, OAuth endpoints, keychain keys |
| `AppState.swift` | Central state — entry point for understanding app logic |
| `AGENTS.md` | Full architecture doc and phase plan |

## Things to Avoid

- Do not edit `TaskMenu.xcodeproj` directly — it is generated from `project.yml` via XcodeGen
- Do not commit `Config.xcconfig` — it contains OAuth secrets
- Do not add SPM dependencies without strong justification
- Do not add a dock icon or main window — this is a menu-bar-only app
- Do not use force unwraps (`!`) on data from network or external sources
