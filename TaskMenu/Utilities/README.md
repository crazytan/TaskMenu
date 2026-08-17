# Utilities

Utilities are shared low-level helpers. Keep this folder dependency-light and avoid adding app-state or UI ownership here.

## Files

- `Constants.swift` - Google OAuth/API/userinfo URLs and scopes, GitHub release URL, Keychain keys, UserDefaults keys, notification identifier prefix, and plist-backed OAuth config.
- `DateFormatting.swift` - RFC 3339 parsing, Google Tasks due-date formatting, display strings, and relative date labels.

## Constants

- `GOOGLE_CLIENT_ID` and `GOOGLE_REDIRECT_SCHEME` come from `Info.plist`, which gets values from `Config.xcconfig`.
- `googleRedirectScheme` can derive the custom scheme from an iOS OAuth client ID ending in `.apps.googleusercontent.com`.
- `googleAuthScopes` includes OpenID Connect email scope plus Google Tasks access so settings can show the signed-in Google account email.
- `githubLatestReleaseURL` is the unauthenticated GitHub Releases endpoint used by the lightweight update checker. It is compiled out under `APP_STORE_BUILD`, so guard new references with `#if !APP_STORE_BUILD`.
- Keep Keychain service/key names stable unless you are intentionally migrating stored credentials or signed-in account display metadata.
- Add new UserDefaults keys under `Constants.UserDefaults` and cover default behavior in `AppStateTests` or the nearest behavior suite.
- Update-check defaults use `automaticUpdateChecksEnabledKey`, `lastUpdateCheckDateKey`, and `lastAlertedUpdateVersionKey`; keep Settings and launch-alert behavior in sync with any changes.
- Preference defaults also use `dueDateNotificationsEnabledKey` and the per-pane sort keys `taskSortOrderKey` (primary, named without a prefix because it predates panes) and `secondaryTaskSortOrderKey` (raw `TaskSortOrder` string, defaults to `myOrder`; unknown values fall back to it).
- `menuBarCounterModeKey` stores `MenuBarCounterMode.rawValue` (`off` / `openTasks` / `dueToday`); unknown values fall back to Off.
- `sideBySideListsEnabledKey` backs the two-pane popover preference (`AppState.sideBySideListsEnabled`, off by default); covered in `SideBySidePanesTests`.
- `primarySelectedListIdKey` and `secondarySelectedListIdKey` remember the list each pane showed. They are restored in `AppState.init` and validated by `reconcilePaneSelections()` once the account's lists load, so an id for a deleted list is dropped rather than shown.

## Date Formatting

- Google Tasks due dates represent calendar days, not user-visible times.
- Encode due dates as `yyyy-MM-ddT00:00:00.000Z`.
- Parse Google due dates in UTC, then return the matching local calendar start-of-day.
- Keep tests for timezone-sensitive and relative-date behavior whenever changing this file.
