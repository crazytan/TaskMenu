# Models

Models hold the app's main state container and Google Tasks data shapes. Keep them small, Codable-compatible, and concurrency-safe.

## Files

- `AppState.swift` - `@MainActor @Observable` source of truth for auth state, task lists, selected list, visible tasks, caches, search, due-date notification preference, and task mutations.
- `TaskItem.swift` - Google Task model, completion helpers, parent/subtask fields, Google due-date conversion, and paged task-list response model.
- `TaskList.swift` - Google Task List model and collection response model.

## AppState Rules

- Treat `AppState` as the only view-facing mutation surface. Views call methods such as `loadTaskLists()`, `refreshTasks()`, `addTask(title:)`, `toggleTask(_:)`, `updateTask(_:)`, `deleteTask(_:)`, `moveTask(_:toSiblingIndex:)`, `indentTask(_:)`, and `outdentTask(_:)`.
- Keep `AppState` `@MainActor`. Inject services through the initializer for tests instead of reaching for globals.
- Preserve optimistic-update rollback behavior for task mutations. If an API call fails, restore the prior local task state and set `errorMessage`.
- Keep the per-list caches in sync when adding, completing, deleting, moving, or selecting lists.
- Use `taskLoadRequestID` guards when introducing async task-loading work so stale responses cannot overwrite the active list.

## Task Ordering And Search

- Use `tasksSortedByGooglePosition(_:)` for any Google-position-sensitive order. It preserves API order when positions are missing.
- Root tasks have `parent == nil`; subtasks use their parent's task ID.
- Search matches titles and notes, and it includes the parent of a matching subtask so the UI can preserve context.

## Due Dates

- Google Tasks due dates are date-only values encoded as midnight UTC strings.
- Use `TaskItem.dueDate(in:)`, `enableDueDate(defaultDate:)`, and `clearDueDate()` instead of parsing or formatting in views.
- Date formatting implementation details live in `TaskMenu/Utilities/README.md`.
