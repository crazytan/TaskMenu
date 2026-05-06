# Resources

Resources define bundle metadata, security settings, and visual assets. Keep generated project references in `project.yml`; do not hand-edit `TaskMenu.xcodeproj`.

## Files

- `Info.plist` - bundle metadata, OAuth URL scheme registration, Google config placeholders, menu-bar-only launch flag, and exported drag type.
- `TaskMenu.entitlements` - app sandbox and outbound network entitlement.
- `Assets.xcassets` - compiled asset catalog, including app icon membership.
- `AppIcon.svg` - source artwork for the app icon.
- `MenuBarIcon.svg` - template status-bar icon source.

## Info.plist Rules

- Preserve `LSUIElement = true` for normal launches.
- Keep `CFBundleURLTypes` aligned with `GOOGLE_REDIRECT_SCHEME` for OAuth callbacks.
- Keep `GOOGLE_CLIENT_ID` and `GOOGLE_REDIRECT_SCHEME` as build-setting placeholders; local values belong in `Config.xcconfig`.
- `UTExportedTypeDeclarations` must stay aligned with the drag type in `TaskListView`.

## Entitlements

- Keep sandboxing and hardened runtime enabled through `project.yml`.
- The app needs outbound network access for Google OAuth, Google Tasks, and token revocation.
- Add entitlements only when a feature requires them and include a short rationale in the change.

## Assets

- Menu bar artwork should be template-compatible.
- Prefer SF Symbols in SwiftUI for in-app controls; use custom assets only for app identity or status-bar needs.
