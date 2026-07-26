# Resources

Resources define bundle metadata, security settings, and visual assets. Keep generated project references in `project.yml`; do not hand-edit `TaskMenu.xcodeproj`.

## Files

- `Info.plist` - bundle metadata, OAuth URL scheme registration, Google config placeholders, the build's git commit stamp, and menu-bar-only launch flag.
- `TaskMenu.entitlements` - app sandbox and outbound network entitlement.
- `Assets.xcassets` - compiled asset catalog, including app icon, menu bar icon, and Discord support-link image membership.
- `AppIcon.svg` - source artwork for the app icon.
- `MenuBarIcon.svg` - template status-bar icon source.

## Info.plist Rules

- Preserve `LSUIElement = true` for normal launches.
- Testing-window launches switch activation policy at runtime; keep `LSUIElement = true` in the bundle plist.
- Keep `CFBundleURLTypes` aligned with `GOOGLE_REDIRECT_SCHEME` for OAuth callbacks.
- Keep `GOOGLE_CLIENT_ID` and `GOOGLE_REDIRECT_SCHEME` as build-setting placeholders; local values belong in `Config.xcconfig`.
- `GITCommitHash` comes from `$(GIT_COMMIT_HASH)`, which `scripts/stamp_build_metadata.sh` writes into the untracked `BuildMetadata.xcconfig` (included from `BuildConfig.xcconfig`). It is empty when the build is not made from a git checkout, and `AppState` then shows `dev`.

## Entitlements

- Keep sandboxing and hardened runtime enabled through `project.yml`.
- The app needs outbound network access for Google OAuth, Google Tasks, token revocation, and GitHub release update checks.
- Add entitlements only when a feature requires them and include a short rationale in the change.

## Assets

- Menu bar artwork should be template-compatible.
- Prefer SF Symbols in AppKit controls; use custom assets only for app identity, status-bar needs, or brand-specific support links.
- `DiscordIcon` is the official Discord symbol used for the settings support link.
