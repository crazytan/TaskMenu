# UI Tests with Mock Mode — Spec

## Overview

Add UI tests for TaskMenu's core user workflows using a mock API layer and a regular window (instead of the menu bar popover) for test stability.

## Mock Mode Architecture

### Launch Detection
When `-ui-testing` is in launch arguments:
1. Host `MenuBarPopover` in a regular `Window` instead of `MenuBarExtra`
2. Inject a `MockGoogleTasksAPI` instead of the real API
3. Skip real OAuth — set `isSignedIn = true` automatically

### MockGoogleTasksAPI
Create a mock that conforms to the same interface as `GoogleTasksAPI`. Since `GoogleTasksAPI` is a concrete actor (not a protocol), you need to:

1. **Extract a protocol** from `GoogleTasksAPI`:
```swift
protocol TasksAPIProtocol: Sendable {
    func listTaskLists() async throws -> [TaskList]
    func listTasks(listId: String, showCompleted: Bool, showHidden: Bool) async throws -> [TaskItem]
    func createTask(listId: String, title: String, notes: String?, due: String?, parentId: String?) async throws -> TaskItem
    func updateTask(listId: String, taskId: String, task: TaskItem) async throws -> TaskItem
    func deleteTask(listId: String, taskId: String) async throws
    func moveTask(listId: String, taskId: String, previousId: String?, parentId: String?) async throws -> TaskItem
}
```

2. Make `GoogleTasksAPI` conform to `TasksAPIProtocol`
3. Update `AppState` to accept `any TasksAPIProtocol` instead of `GoogleTasksAPI`
4. Create `MockTasksAPI` actor that implements `TasksAPIProtocol` with in-memory storage

### MockTasksAPI Behavior
- `listTaskLists()` → returns 2 lists: "My Tasks" (id: "list1") and "Work" (id: "list2")
- `listTasks()` → returns mock tasks from in-memory array (see fixture data below)
- `createTask()` → creates task with generated UUID id, adds to in-memory array, returns it
- `updateTask()` → updates in-memory task, returns it
- `deleteTask()` → removes from in-memory array
- `moveTask()` → updates parent/position in-memory, returns updated task

### Fixture Data (for "My Tasks" / list1)
```
1. "Buy groceries" (id: "task1", root, incomplete)
2. "Read chapter 5" (id: "task2", root, incomplete)
   - "Take notes" (id: "task3", parent: "task2", incomplete)
3. "Schedule dentist" (id: "task4", root, incomplete, due: today)
4. "File taxes" (id: "task5", root, completed)
```

### Window Mode for UI Testing

In `TaskMenuApp.swift`, when `-ui-testing` is detected:
```swift
if isUITesting {
    Window("TaskMenu", id: "testing") {
        MenuBarPopover(appState: appState)
            .frame(width: 320, height: 480)
    }
    .windowResizability(.contentSize)
} else {
    MenuBarExtra { ... }
}
```

The `AppState` init needs to accept the mock API and pre-set `isSignedIn = true`.

### Accessibility Identifiers

Add these to the relevant views (some may already exist):
- `"quickadd.field"` — the quick-add text field
- `"task.row.\(task.id)"` — each task row
- `"task.checkbox.\(task.id)"` — the completion checkbox
- `"task.title.\(task.id)"` — the task title text
- `"detail.title.field"` — title field in detail view
- `"detail.done.button"` — Done button in detail view
- `"detail.back.button"` — back chevron in detail view
- `"completed.toggle"` — the "Completed (N)" disclosure button
- `"inline.subtask.field"` — the inline subtask text field
- `"list.picker"` — the list picker button
- `"search.field"` — the search/filter field

## UI Test Cases

### File: `TaskMenuUITests/TaskMenuUITests.swift`

All tests share a common setUp that launches the app with `-ui-testing`.

#### 1. testTaskListLoadsOnLaunch
- Assert "Buy groceries", "Read chapter 5", "Schedule dentist" are visible
- Assert "File taxes" is NOT visible (completed, section collapsed)

#### 2. testAddTask
- Click the quick-add field
- Type "New test task" + Enter
- Assert "New test task" appears in the list

#### 3. testCompleteTask
- Click the checkbox for "Buy groceries"
- Assert the task moves out of the active section (disappears or moves to completed)

#### 4. testDeleteTask
- Right-click "Buy groceries"
- Click "Delete" in context menu
- Assert "Buy groceries" is no longer visible

#### 5. testEditTaskDetails
- Click on "Buy groceries" (not the checkbox)
- Assert detail view appears with title field containing "Buy groceries"
- Clear and type "Buy organic groceries"
- Click Done
- Assert back in list view, "Buy organic groceries" is visible

#### 6. testAddSubtaskInline
- Right-click "Buy groceries"
- Click "Add Subtask"
- Assert inline field appears
- Type "Get milk" + Enter
- Assert "Get milk" appears indented under "Buy groceries"

#### 7. testIndentTask
- Right-click "Read chapter 5" (2nd root task)
- Click "Make Subtask"
- Assert "Read chapter 5" is now indented under "Buy groceries"

#### 8. testOutdentTask
- Right-click "Take notes" (subtask of "Read chapter 5")
- Click "Move to Top Level"
- Assert "Take notes" is now at root level (no indent)

#### 9. testCompletedSectionToggle
- Find and click the "Completed" disclosure button
- Assert "File taxes" becomes visible
- Click the disclosure button again
- Assert "File taxes" is no longer visible

#### 10. testSearchFiltersTasks
- Click the search/filter field
- Type "chapter"
- Assert "Read chapter 5" is visible
- Assert "Buy groceries" is NOT visible
- Clear the search field
- Assert all tasks visible again

## Build & Test Commands
- Build: `xcodebuild build -project TaskMenu.xcodeproj -scheme TaskMenu -destination 'platform=macOS'`
- Unit tests: `xcodebuild test -project TaskMenu.xcodeproj -scheme TaskMenu -destination 'platform=macOS' -only-testing:TaskMenuTests`
- UI tests: `xcodebuild test -project TaskMenu.xcodeproj -scheme TaskMenu -destination 'platform=macOS' -only-testing:TaskMenuUITests`
- Run all tests after implementing to make sure nothing is broken
- **IMPORTANT**: xcodegen is NOT used in this project. Edit `TaskMenu.xcodeproj` manually or use Xcode's "Add Files" for new targets/files.

## Files to Create
- `TaskMenu/Services/TasksAPIProtocol.swift` — protocol extraction
- `TaskMenu/Services/MockTasksAPI.swift` — mock implementation
- `TaskMenuUITests/TaskMenuUITests.swift` — all UI test cases

## Files to Modify
- `TaskMenu/Services/GoogleTasksAPI.swift` — conform to `TasksAPIProtocol`
- `TaskMenu/Models/AppState.swift` — accept `any TasksAPIProtocol`; add `isUITesting` convenience init
- `TaskMenuApp.swift` — window mode for UI testing, mock injection
- Various views — add accessibility identifiers listed above

## Project Setup Notes
- The UI test target `TaskMenuUITests` needs to be added to the Xcode project
- It should be a "UI Testing Bundle" target that depends on the main `TaskMenu` app target
- The mock API files go in the main app target (not the test target) since the app needs to use them at runtime when launched with `-ui-testing`
