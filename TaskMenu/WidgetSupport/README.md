# WidgetSupport

Foundation/Security-only code shared between the `TaskMenu` app target and
the `TaskMenuWidget` extension target. See
`scratch/issue-11-desktop-widget/CONTRACT.md` and `implementation-spec.md`
for the full product/architecture context; this file covers the local
security boundary and invariants agents must preserve.

## Files

- `TaskWidgetConstants.swift` - widget kind, snapshot file name, deep-link
  scheme, Darwin change-notification name, and current schema version.
- `TaskWidgetSnapshot.swift` - versioned, minimized DTOs written to the App
  Group container: `TaskWidgetSnapshot`, `TaskWidgetAuthenticationState`,
  `TaskWidgetListSnapshot`, `TaskWidgetTaskSnapshot`.
- `TaskWidgetSnapshotStore.swift` - `NSFileCoordinator`-coordinated,
  atomic-replace reads/writes of the snapshot file, including the
  stale-write-protected `replaceList(_:requestStartedAt:)`.
- `TaskWidgetProjection.swift` - open-task filtering, root ordering (reusing
  `tasksSorted(_:by:calendar:)`), direct-subtask flattening/indentation, row
  budgets, and `+N more` remainder counting.
- `TaskWidgetDeepLink.swift` - strict `taskmenu://widget/list?id=...`
  construction and parsing only. It has no side effects and does not touch
  `AppState`, `StatusBarController`, or `NSAppleEventManager` — app-side
  routing is owned elsewhere (see `AGENTS.md`'s target-membership notes).
- `TaskWidgetChangeSignal.swift` - Darwin notification wrapper used after a
  widget-originated mutation so a running TaskMenu process can reconcile.
- `TaskWidgetSnapshotPublisher.swift` - `TaskWidgetSnapshotPublishing`, the
  narrow protocol `AppState` depends on to keep the shared snapshot current,
  plus `NoOpTaskWidgetSnapshotPublisher` (test/default-safe) and
  `TaskWidgetSnapshotPublisher` (production: writes through an injected
  `TaskWidgetSnapshotStore` and calls `WidgetCenter.reloadTimelines(ofKind:)`
  after a meaningful, accepted change). It exists to keep `import WidgetKit`
  out of `AppState.swift`, which stays app-only; only the app side
  (`AppState`, `TaskMenuApp.swift`'s `--testing-window` setup) constructs it.
  `TaskMenuWidget`'s own timeline provider (added separately) is not this
  file's caller.
- `TaskWidgetEntryContent.swift` - `TaskWidgetTimelineStatus` (the coarse
  state one widget rendering is in: `signedOut`, `listUnavailable`,
  `noCache`, `live`, `stale(lastUpdated:)`) and `TaskWidgetEntryContent`
  (status + list identity/title/sort order + an optional
  `TaskWidgetProjectedList`) — everything one widget rendering needs, with
  zero WidgetKit/SwiftUI dependency so it stays constructible and comparable
  from plain unit tests. Also owns `placeholderSample(rowBudget:now:calendar:)`,
  the fictional, zero-I/O sample content for the widget placeholder and
  gallery/preview rendering; its `listID` is always `nil` so a sample
  `Button`/`Link` can never address a real list or task.
- `TaskWidgetTimelineLoader.swift` - the decision path behind the widget's
  timeline provider: `cachedContent(...)` (cache-only, used for the
  gallery/preview snapshot and as the fallback below) and
  `loadLive(...)` (live-first, cache-fallback — reads the shared snapshot,
  attempts a live `listTasks` call, and on success publishes the result
  through `TaskWidgetSnapshotStore.replaceList(_:requestStartedAt:)` using
  the request's *start* time so the stale-write protection in "Timestamp
  Precision" below actually applies). Maps `APIError.unauthorized` to a
  credential/snapshot clear, `APIError.serverError(404, _)` to
  `.listUnavailable` (never a silent fallback to another list), and every
  other failure (offline, other server errors, decode errors, cancellation)
  to the cached fallback. `minimize(_:)` is the single place that turns
  fetched `TaskItem`s into open-only `TaskWidgetTaskSnapshot`s, shared with
  `TaskWidgetCompletionCoordinator`'s post-completion refetch below.
- `TaskWidgetListCatalog.swift` - `TaskWidgetListCatalogEntry` (id + title)
  and the pure decision logic behind the widget configuration's list
  picker: `entries(for:in:)` (only ids that still exist, in the order
  requested), `suggestedEntries(in:)` (every list, snapshot/Google order),
  and `defaultEntry(in:)` (`snapshot.defaultListID` if it still exists, else
  the first list, else `nil`). Reads the shared snapshot only — never a live
  Google fetch, and never a fabricated list when the snapshot is missing or
  empty.
- `TaskWidgetCompletionCoordinator.swift` - `TaskWidgetCompletionResult`
  (`success` / `partialFailure` / `transientFailure` / `authFailure` /
  `taskNotInList`) and `TaskWidgetCompletionOutcome` (that result plus
  `sharedStateChanged: Bool`, the only signal `CompleteTaskIntent` may use
  to decide whether to call `WidgetCenter.reloadTimelines`/post the Darwin
  change signal — never `result` alone, since a `.partialFailure`'s refetch
  can itself fail to publish, and a `.success` can still leave
  `sharedStateChanged == false` if `store.replaceList` rejects it as stale).
  `complete(listID:taskID:store:keychain:api:)` verifies `taskID` is present
  in the cached list before mutating anything (untrusted persisted input —
  see `taskNotInList`), completes the task, then bounded-sequentially
  completes every open direct child, and always attempts the authoritative
  refetch/publish regardless of child outcome so the shared cache never
  claims a completion Google did not record.

## Target Membership

Every file here except this `README.md` compiles into **both** `TaskMenu`
and `TaskMenuWidget` (per `project.yml`, owned outside this file's scope).
Consequences:

- No SwiftUI, AppIntents, or AppKit imports here. Those belong in
  `TaskMenuWidget/` (extension-only UI/intents) or `TaskMenu/Views/`
  (app-only UI). `TaskWidgetSnapshotPublisher.swift` is the sole, deliberate
  exception: it `import WidgetKit` to call
  `WidgetCenter.shared.reloadTimelines(ofKind:)`, confined to that one file
  precisely so `AppState.swift` (app-only) never needs to. This does not
  widen the target's capabilities — `TaskMenuWidget` links WidgetKit
  inherently as a widget extension, and the app target already needs it for
  the same `WidgetCenter` call — but keep any *new* WidgetKit/SwiftUI/
  AppIntents usage in `TaskMenuWidget/` rather than adding a second
  exception here.
- Every type here must be `Codable` (where persisted) and `Sendable`, and
  must compile clean under `SWIFT_STRICT_CONCURRENCY: complete`.
- Keep dependencies limited to Foundation, plus the specific existing files
  the CONTRACT allow-lists for the widget target: the models `TaskItem`,
  `TaskList`, `TaskSortOrder`, `TaskOrdering`, `DateFormatting`,
  `SharedConstants`, and — now that the Slice 2 token-provider refactor has
  landed — the services `KeychainService.swift` (`KeychainServiceProtocol`),
  `TasksAPIProtocol.swift` (`TasksAPIProtocol`, `APIError`),
  `GoogleTasksAPI.swift`, `AccessTokenProviding.swift`,
  `GoogleTokenRefresher.swift`, and `WidgetGoogleAccessTokenProvider.swift`.
  `TaskWidgetTimelineLoader` and `TaskWidgetCompletionCoordinator` take
  `any KeychainServiceProtocol` / `any TasksAPIProtocol` as parameters
  rather than importing a concrete implementation, so their tests can pass
  fakes; production callers in `TaskMenuWidget` wire up the real
  `GoogleTasksAPI(tokenProvider: WidgetGoogleAccessTokenProvider())` and
  `KeychainService`. Do not reach into `AppState` or any `Views/` type from
  here.

## Snapshot Invariants

- The snapshot is a deliberately narrow projection of live app data, never
  `AppState`, `TaskItem`, or `TaskList` encoded directly.
- Store only **open** (`needsAction`) tasks. A completed task (parent or
  subtask) is removed from the shared cache, not marked completed in place.
- Never write task notes, account email, OAuth access/refresh tokens, token
  expirations, raw Google API response bodies, or notification identifiers
  into the snapshot. `TaskWidgetTaskSnapshot` intentionally has no `notes`
  field; do not add one. `TaskWidgetTimelineLoader.minimize(_:)` is the one
  place fetched `TaskItem`s become `TaskWidgetTaskSnapshot`s (shared by the
  live timeline load and `TaskWidgetCompletionCoordinator`'s post-completion
  refetch) — extend that boundary, do not add a second, looser mapping
  elsewhere.
- `TaskWidgetSnapshot.schemaVersion` starts at `1`. A stored snapshot whose
  version is greater than `TaskWidgetConstants.currentSchemaVersion` (or
  whose JSON is otherwise unreadable) must decode to
  `TaskWidgetSnapshot.empty()`, never throw into a caller. Bump
  `currentSchemaVersion` only alongside a compatible-decode/migration plan
  for the new shape.
- All cross-process reads/writes go through `TaskWidgetSnapshotStore`, which
  coordinates with `NSFileCoordinator` and replaces the file atomically. Do
  not read or write the snapshot file directly anywhere else.
- `TaskWidgetSnapshotStore.replaceList(_:requestStartedAt:)` is the only
  supported way to publish one list's fresh tasks; it rejects a write whose
  `requestStartedAt` predates the stored list's last refresh, so a slow
  request that started before a widget completion cannot overwrite it just
  by finishing later. Whole-snapshot writes (`write(_:)`, `clear()`,
  `pruneLists(keeping:)`, `setDefaultListID(_:)`,
  `setAuthentication(_:)`) do not carry that protection and should only be
  used for catalog-level/sign-out changes, not per-list task refreshes.
- Never log serialized snapshot contents. Metadata-only logging (operation
  name, error) is fine.
- Tests must construct `TaskWidgetSnapshotStore(directoryURL:)` with an
  injected temporary directory. Never point a test at the real App Group
  container.

## Timestamp Precision

`TaskWidgetSnapshotStore`'s encoder/decoder use `.secondsSince1970` (a JSON
`Double`) for every `Date` in `TaskWidgetSnapshot`, so `generatedAt`,
`refreshedAt`, and `refreshStartedAt` round-trip through disk with
sub-second precision intact. This is load-bearing for
`replaceList(_:requestStartedAt:)`'s stale-write protection: the app and the
widget extension are different processes racing the network and can start
and finish requests for the same list less than a second apart, so a
whole-second-only encoding (e.g. `.iso8601` with its default, non-fractional
formatter) would make same-second writes compare as equal and let a stale
one win. Do not switch the date strategy to anything that truncates
fractional seconds; if you must change it, add a regression test asserting
a timestamp round-trips exactly and that two writes milliseconds apart
still resolve correctly through `replaceList(_:requestStartedAt:)`.

A snapshot written by an older build with a different (lossy) date encoding
fails the full `TaskWidgetSnapshot` decode — its `Date` fields no longer
match the expected JSON shape — and falls back to `.empty()` like any other
corrupt file. That degrades safely: `schemaVersion` did not need to change
for this fix, since the field names are unchanged and an undecodable old
snapshot is disposable cache, not data that needs a migration path.
