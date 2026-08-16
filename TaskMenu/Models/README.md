# Models

Models hold the app's main state container and Google Tasks data shapes. Keep them small, Codable-compatible, and concurrency-safe.

## Files

- `AppState.swift` - `@MainActor @Observable` source of truth for auth state, demo mode, signed-in Google account profile, task lists, selected list, visible tasks, caches, row disclosure, search, root-task sort preference (`taskSortOrder`), menu-bar counter preference and count (`menuBarCounterMode`, `menuBarPendingCount`), due-date notification preference, update-check state, build version identity, and task mutations.
- `TaskItem.swift` - Google Task model, completion helpers, parent/subtask fields, Google due-date conversion, and paged task-list response model.
- `TaskList.swift` - Google Task List model and collection response model.
- `MenuBarCounter.swift` - `MenuBarCounterMode` (Off / Open tasks / Due today) and the pure `pendingTaskCount(in:mode:now:calendar:)` used for the menu-bar counter.
- `TaskSortOrder.swift` - root-task sort preference (`myOrder`/`dueDate`) and the pure `tasksSortedByDueDate(_:calendar:)` / `tasksSorted(_:by:calendar:)` sorters.

## AppState Rules

- Treat `AppState` as the only view-facing mutation surface. Views call methods such as `loadTaskLists()`, `createTaskList(title:)`, `refreshTasks()`, `addTask(title:)`, `addSubtask(title:parentId:)`, `toggleTask(_:)`, `updateTask(_:)`, `deleteTask(_:)`, `moveTask(_:toParent:after:)`, `expandTask(_:)`, and update-check helpers. `addTask(title:)` and `addSubtask(title:parentId:)` return the created task so a view can flash the new row.
- Keep `AppState` `@MainActor`. Inject services through the initializer for tests instead of reaching for globals.
- `createTaskList(title:)` is the only list-creating surface: it trims the title, ignores blanks, posts through the API, appends the returned list to `taskLists`, and selects it through `selectList(_:)`; nothing is added optimistically, so a failure only sets `errorMessage`. It re-checks `isSignedIn` after the await like every other mutation, so a sign-out or demo exit mid-request drops the result.
- Preserve `toggleTask(_:)` optimistic-update rollback behavior. If an optimistic API call fails, restore the prior local task state and set `errorMessage`.
- Keep the per-list cache in sync when adding, adding subtasks, completing, updating, deleting, or selecting lists.
- Use `taskLoadRequestID` guards when introducing async task-loading work so stale responses cannot overwrite the active list. Fetches also capture `taskStateGeneration`, which every committed mutation bumps, so a fetch snapshot taken before a local change is discarded rather than applied.
- `AppState.defaultUpdateChecker()` returns `GitHubUpdateChecker` normally and `DisabledUpdateChecker` under `APP_STORE_BUILD`.
- Sign-in attempts carry a `signInGeneration`, and `enterDemoMode()` retires the current one so an abandoned sign-in cannot block the demo or write back over it later. Guard any new sign-in completion path on the generation it started with.
- Keep update checks comparing `currentAppVersion` (marketing version only). `currentBuildCommit` and `currentAppVersionDisplay` are display-only; the latter renders `1.3.0 (a1b2c3d)`, or `(dev)` when the build carries no commit stamp.
- `enterDemoMode()`/`exitDemoMode()` swap the injected `api` between the account-backed client and `DemoTasksAPI`, leaving `authService` untouched. `signOut()` and `disconnectGoogleAccount()` route to `exitDemoMode()` while demo mode is active, so neither discards real credentials. Guard any new account-facing work with `!isDemoMode`.
- Menu-bar counter: `menuBarCounterMode` is persisted under `Constants.UserDefaults.menuBarCounterModeKey`. `menuBarPendingCount` sums every known list from `taskCacheByListID`, with the selected list read from the live `tasks`, so `commitTaskChange` keeps it current. `refreshMenuBarCounts(includingSelectedList:)` is the only path allowed to fetch lists other than the selected one; it runs off the visible load path (no `isLoading`, no `errorMessage`, no `taskLoadRequestID`, no `handleError`, so a background 401 never signs the user out), captures `taskStateGeneration` per list and discards stale snapshots, fetches sequentially, and only replaces the selected list's `tasks` on a periodic tick when no newer foreground load exists. The loop (`menuBarCountRefreshInterval`, 5 minutes; injectable for tests) starts from `loadTaskLists` or from enabling the setting and stops from the Off setting and `clearSignedInState()`. Only one sweep runs at a time: the slot is owned by a sweep ID, so a sweep cancelled by Off/sign-out cannot free the slot of the replacement that started before it unwound (`isMenuBarCountRefreshLoopRunning` / `isMenuBarCountSweepInFlight` are test probes). Do not add error UI or notification syncing to that path, and never mark `taskCacheByListID` `@ObservationIgnored` (the status item observes it through `menuBarPendingCount`).
- Route post-await mutation writes through `commitTaskChange(to:_:)`: it re-checks the captured list against the current selection and writes to the live array or `taskCacheByListID` accordingly. Re-check `isSignedIn` after every await before touching state.

## Task Ordering And Search

- Use `tasksSortedByGooglePosition(_:)` for any Google-position-sensitive order. It preserves API order when positions are missing.
- Root tasks have `parent == nil`; subtasks use their parent's task ID.
- `rootTasks` and `searchFilteredRootTasks` follow `taskSortOrder`; `.dueDate` orders by local due day ascending, undated last, ties by Google position. `subtasks(of:)`, `searchFilteredSubtasks(of:)`, and the completed section always use Google order. `moveTask(_:toParent:after:)` is a no-op unless `canReorderTasks` (`.myOrder`); the preference persists across sign-out, disconnect, and demo exit. Sorting is a pure read over `tasks`; never sort the stored array in place.
- `addSubtask(title:parentId:)` commits the created task through `tasksWithCreatedTask(_:in:)`, which places it first among its siblings and rewrites the sibling group's positions like a move would. `tasks.insert` with a `parent` and no `previous` makes the new task the first child and renumbers the existing children server-side (verified live: every created child comes back as `00000000000000000000` and the former children shift up), so the created task's returned position ties with the former first child's stale local position; never place a created subtask by comparing positions. `addTask(title:)` inserts at index 0, where the position tie-break already lands the new root task first.
- Drag-and-drop reordering goes through `moveTask(_:toParent:after:)`, which applies `tasksReorderedAfterMove(_:movedTaskID:newParentID:previousTaskID:)` optimistically (rewriting destination sibling positions locally), calls the move API, and rolls back on failure. Exact server positions reconcile on the next refresh.
- Search matches titles and notes, and it includes the parent of a matching subtask so the UI can preserve context.

## Due Dates

- Google Tasks due dates are date-only values encoded as midnight UTC strings.
- Use `TaskItem.dueDate(in:)`, `enableDueDate(defaultDate:)`, and `clearDueDate()` instead of parsing or formatting in views.
- Date formatting implementation details live in `TaskMenu/Utilities/README.md`.
