# AGENTS.md

Entry point for coding agents working on TaskMenu. Keep this file short and repo-wide; put folder-specific implementation notes in the nearest `README.md`.

## Project Snapshot

- Native macOS menu bar app for Google Tasks.
- Swift 6, SwiftUI, macOS 14.4+, `@Observable`, strict concurrency.
- XcodeGen build graph: edit `project.yml`, then regenerate `TaskMenu.xcodeproj`.
- Targets: `TaskMenu` and `TaskMenuTests`.
- App shape: no Dock icon and no main app window in normal launches; UI is presented from an AppKit status item popover, with a test-only window for UI automation.
- External surface area: Google OAuth 2.0 with PKCE, Google Tasks REST API, Keychain token storage, UserNotifications for due-date reminders, MetricKit payload persistence.

## Open The Local Doc First

- `TaskMenu/README.md` - app-target map, lifecycle, and state flow.
- `TaskMenu/Models/README.md` - app state, Google models, ordering, search, and mutation rules.
- `TaskMenu/Services/README.md` - OAuth, Google Tasks API, keychain, notification, MetricKit, and mock-service guidance.
- `TaskMenu/Views/README.md` - popover UI ownership, task-list interactions, settings, and view-testable helpers.
- `TaskMenu/Utilities/README.md` - constants, OAuth config values, and date formatting expectations.
- `TaskMenu/Resources/README.md` - Info.plist, entitlements, URL schemes, app icons, and generated asset notes.
- `TaskMenuTests/README.md` - unit-test map, test doubles, and focused test selection.
- `AppStorePreviews/README.md` - generated marketing/App Store preview assets.

## Repo-Wide Rules

### Coding Style

- Use Swift concurrency APIs that compile with `SWIFT_STRICT_CONCURRENCY: complete`.
- Keep `AppState` on the main actor and make view-facing mutations flow through it unless a folder README names a narrower owner.
- Keep network and token operations in services; views should call `AppState` methods, not Google APIs directly.
- Keep models `Codable` and `Sendable`.
- Prefer Apple frameworks and SF Symbols. Do not add package dependencies without a strong reason.
- Avoid force unwraps on network, OAuth, keychain, notification, or plist-derived data.

### Workflows

- If you add, remove, rename, or retarget source files, update `project.yml` and run `xcodegen generate`.
- When files are added or deleted, update the corresponding folder-local `README.md` in the same change so its file map and ownership notes stay current.
- Keep `TaskMenu.xcodeproj` generated; do not hand-edit it.
- Do not commit `Config.xcconfig`; it contains local OAuth values.
- Preserve the menu-bar-only behavior for normal app launches. `TaskMenuApp.isUITesting` is the exception that creates a regular window for automation.
- Update `CHANGELOG.md` before committing feature or bug-fix work, under `## Unreleased` when present.

### Version Control Notes

- Default to the current branch. When explicitly asked to commit/push, commit a focused logical change and push directly to `main` if that is the current flow.
- Do not create a feature branch or pull request unless the user asks, or unless working from a separate worktree requires it.

## Build And Test

```bash
xcodegen generate

xcodebuild build -project TaskMenu.xcodeproj -scheme TaskMenu \
  -configuration Debug

xcodebuild test -project TaskMenu.xcodeproj -scheme TaskMenu \
  -configuration Debug \
  -only-testing:TaskMenuTests/AppStateTests
```

- Prefer the smallest relevant `-only-testing:` slice.
- Run the broader test target when a change touches shared app state, service protocols, Google API encoding/decoding, or date handling.
- OAuth-enabled app launches require a local `Config.xcconfig` copied from `Config.xcconfig.example` with `GOOGLE_CLIENT_ID` and `GOOGLE_REDIRECT_SCHEME`.

## Security And Privacy Reminders

- OAuth refresh/access tokens belong in Keychain only.
- Keep sandbox and hardened-runtime settings intact.
- Network access should stay limited to explicit product features: Google OAuth, Google Tasks, and token revocation.
- MetricKit payloads are currently persisted locally; do not add upload behavior without explicit opt-in and a reviewed privacy path.
