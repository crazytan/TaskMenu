# Utilities

Utilities are shared low-level helpers. Keep this folder dependency-light and avoid adding app-state or UI ownership here.

## Files

- `Constants.swift` - Google OAuth/API URLs, Keychain keys, UserDefaults keys, notification identifier prefix, and plist-backed OAuth config.
- `DateFormatting.swift` - RFC 3339 parsing, Google Tasks due-date formatting, display strings, and relative date labels.

## Constants

- `GOOGLE_CLIENT_ID` and `GOOGLE_REDIRECT_SCHEME` come from `Info.plist`, which gets values from `Config.xcconfig`.
- `googleRedirectScheme` can derive the custom scheme from an iOS OAuth client ID ending in `.apps.googleusercontent.com`.
- Keep Keychain service/key names stable unless you are intentionally migrating stored credentials.
- Add new UserDefaults keys under `Constants.UserDefaults` and cover default behavior in `AppStateTests`.

## Date Formatting

- Google Tasks due dates represent calendar days, not user-visible times.
- Encode due dates as `yyyy-MM-ddT00:00:00.000Z`.
- Parse Google due dates in UTC, then return the matching local calendar start-of-day.
- Keep tests for timezone-sensitive and relative-date behavior whenever changing this file.
