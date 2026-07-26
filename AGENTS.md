# AGENTS.md

Entry point for coding agents working on TaskMenu. Keep this file short and repo-wide; put folder-specific implementation notes in the nearest `README.md`.

## Project Snapshot

- Native macOS menu bar app for Google Tasks.
- Swift 6, AppKit UI, macOS 14.4+, `@Observable`, strict concurrency.
- XcodeGen build graph targeting Xcode 26.4 project settings: edit `project.yml`, then regenerate `TaskMenu.xcodeproj`.
- Targets: `TaskMenu` and `TaskMenuTests`.
- App shape: no Dock icon and no main app window; UI is presented from an AppKit status item popover.
- External surface area: Google OAuth 2.0 with PKCE, Google Tasks REST API, Keychain token storage, UserNotifications for due-date reminders, GitHub release update checks, MetricKit payload persistence.

## Open The Local Doc First

- `TaskMenu/README.md` - app-target map, lifecycle, and state flow.
- `TaskMenu/Models/README.md` - app state, Google models, ordering, search, and mutation rules.
- `TaskMenu/Services/README.md` - OAuth, Google Tasks API, keychain, notification, MetricKit, update checks, and service-injection guidance.
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
- Do not commit `Config.xcconfig`; it contains local OAuth and signing values. `BuildConfig.xcconfig` is the committed entry point that includes it, plus the generated `BuildMetadata.xcconfig` git-commit stamp.
- Preserve the menu-bar-only behavior for app launches.
- Update `CHANGELOG.md` before committing feature or bug-fix work, under `## Unreleased` when present.

### Version Control Notes

- Default to the current branch. When explicitly asked to commit/push, commit a focused logical change and push directly to `main`.
- Do not create a feature branch or pull request unless the user asks.

## Build And Test

```bash
xcodegen generate

xcodebuild build -project TaskMenu.xcodeproj -scheme TaskMenu \
  -configuration Debug \
  -destination "platform=macOS"

xcodebuild test -project TaskMenu.xcodeproj -scheme TaskMenu \
  -configuration Debug \
  -destination "platform=macOS" \
  -only-testing:TaskMenuTests/AppStateTests
```

- When verifying a fix or new feature, run only the minimal relevant `-only-testing:` slice.
- OAuth-enabled app launches require a local `Config.xcconfig` copied from `Config.xcconfig.example` with `GOOGLE_CLIENT_ID` and `GOOGLE_REDIRECT_SCHEME`.

## UI Tasks (Agent Self-Verification)

To see and verify UI changes without credentials, launch the app with `--testing-window` argument.
Remember to always run the full UI verification loop first before working on any changes to discover
any issues early (e.g., macOS permission issues).

- The task UI opens in a regular window (signed-in state, seeded fake tasks) instead of the menu bar popover.
- Seeded data covers four lists: "Seeded Tasks" (subtasks, completed section, delete target), "Due Dates" (overdue/today/tomorrow/future due dates on parents and subtasks), "Long Subtasks" (a parent with 12 subtasks for scroll behavior), and "Empty List" (empty state). Switch lists with the picker at the top.
- Everything is in memory: no Keychain access, no Google credentials, no network, no notifications, no update checks, no persisted defaults. Task mutations (add, add subtask, edit, complete, delete) work against the fake API and reset on relaunch.
- Take screenshots with `screencapture` to inspect rendering, then kill the process when done.
- Fakes live at the bottom of `TaskMenu/TaskMenuApp.swift` (`TestingWindowTasksAPI` and friends); extend the seeded data there if a UI state you need is missing.

## Security And Privacy Reminders

- OAuth refresh/access tokens belong in Keychain only.
- Keep sandbox and hardened-runtime settings intact.
- Network access should stay limited to explicit product features: Google OAuth, Google Tasks, token revocation, and GitHub release update checks.
- MetricKit payloads are currently persisted locally; do not add upload behavior without explicit opt-in and a reviewed privacy path.
