# Models

Models hold the app's main state container and Google Tasks data shapes. Keep them small, Codable-compatible, and concurrency-safe.

## Files

- `AppState.swift` - `@MainActor @Observable` source of truth for auth state, signed-in Google account profile, task lists, selected list, visible tasks, caches, row disclosure, search, due-date notification preference, update-check state, build version identity, and task mutations.
- `TaskItem.swift` - Google Task model, completion helpers, parent/subtask fields, Google due-date conversion, and paged task-list response model.
- `TaskList.swift` - Google Task List model and collection response model.

## AppState Rules

- Treat `AppState` as the only view-facing mutation surface. Views call methods such as `loadTaskLists()`, `refreshTasks()`, `addTask(title:)`, `addSubtask(title:parentId:)`, `toggleTask(_:)`, `updateTask(_:)`, `deleteTask(_:)`, `moveTask(_:toParent:after:)`, and update-check helpers.
- Keep `AppState` `@MainActor`. Inject services through the initializer for tests instead of reaching for globals.
- Preserve `toggleTask(_:)` optimistic-update rollback behavior. If an optimistic API call fails, restore the prior local task state and set `errorMessage`.
- Keep the per-list cache in sync when adding, adding subtasks, completing, updating, deleting, or selecting lists.
- Use `taskLoadRequestID` guards when introducing async task-loading work so stale responses cannot overwrite the active list. Fetches also capture `taskStateGeneration`, which every committed mutation bumps, so a fetch snapshot taken before a local change is discarded rather than applied.
- Keep update checks comparing `currentAppVersion` (marketing version only). `currentBuildCommit` and `currentAppVersionDisplay` are display-only; the latter renders `1.3.0 (a1b2c3d)`, or `(dev)` when the build carries no commit stamp.
- Route post-await mutation writes through `commitTaskChange(to:_:)`: it re-checks the captured list against the current selection and writes to the live array or `taskCacheByListID` accordingly. Re-check `isSignedIn` after every await before touching state.

## Task Ordering And Search

- Use `tasksSortedByGooglePosition(_:)` for any Google-position-sensitive order. It preserves API order when positions are missing.
- Root tasks have `parent == nil`; subtasks use their parent's task ID.
- Drag-and-drop reordering goes through `moveTask(_:toParent:after:)`, which applies `tasksReorderedAfterMove(_:movedTaskID:newParentID:previousTaskID:)` optimistically (rewriting destination sibling positions locally), calls the move API, and rolls back on failure. Exact server positions reconcile on the next refresh.
- Search matches titles and notes, and it includes the parent of a matching subtask so the UI can preserve context.

## Due Dates

- Google Tasks due dates are date-only values encoded as midnight UTC strings.
- Use `TaskItem.dueDate(in:)`, `enableDueDate(defaultDate:)`, and `clearDueDate()` instead of parsing or formatting in views.
- Date formatting implementation details live in `TaskMenu/Utilities/README.md`.
