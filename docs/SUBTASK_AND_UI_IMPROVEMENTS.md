# Subtask Management & UI Polish — Spec

## Overview

Four improvements to TaskMenu:
1. **Inline "Add subtask"** from the task list (no detail view required)
2. **Indent/Outdent** to convert tasks ↔ subtasks via context menu and keyboard
3. **Hover highlight** — subtle row highlight on mouse hover
4. **Completion animation** — satisfying visual feedback when checking off a task

---

## 1. Inline "Add Subtask"

### Behavior
- In the **context menu** for any root-level task (i.e. tasks where `parent == nil`), add an "Add Subtask" action
- Clicking it inserts a **temporary inline text field** directly below the task (indented to child level), with focus
- Pressing Enter creates the subtask via `appState.addSubtask(title:parentId:)` and dismisses the field
- Pressing Escape cancels and dismisses the field
- If the parent was collapsed, auto-expand it first

### Implementation

**TaskListView.swift:**
- Add `@State private var inlineSubtaskParentID: String?` to track which task is getting an inline subtask
- In the context menu for task rows where `task.parent == nil`, add:
  ```
  Button { inlineSubtaskParentID = task.id } label: {
      Label("Add Subtask", systemImage: "text.badge.plus")
  }
  ```
- When rendering the flattened task list, after a task whose `id == inlineSubtaskParentID`, insert an inline text field row at `indentLevel + 1`
- Auto-expand: if `inlineSubtaskParentID` is set and the task is collapsed, call `appState.toggleCollapsed(taskID)` to expand it

**New: InlineSubtaskField view (can be a private struct in TaskListView.swift):**
- Simple HStack: plus.circle icon + TextField
- `@FocusState` auto-focused on appear
- On submit: call `appState.addSubtask(title:parentId:)`, then keep the field open for rapid entry (clear text, stay focused)
- On Escape (via `.onExitCommand`): set `inlineSubtaskParentID = nil`
- On click outside / loss of focus: dismiss (set `inlineSubtaskParentID = nil`)
- Indented to match child level: `paddingLeading = (parentIndentLevel + 1) * 20`

---

## 2. Indent / Outdent

### Behavior
- **Indent** (Tab or context menu "Make Subtask"): Convert a root-level task into a subtask of the task directly above it in the list
  - Only available if the task above exists and is a root-level task (no nested subtask-of-subtask — Google Tasks only supports one level of nesting)
  - Uses the `moveTask` API with `parentId` set to the task above
- **Outdent** (Shift+Tab or context menu "Move to Top Level"): Convert a subtask back to a root-level task
  - Uses the `moveTask` API with `parentId` omitted (moves to top level)
  - Position: place it after its former parent in the root list

### Implementation

**AppState.swift — new methods:**
```swift
func indentTask(_ task: TaskItem) async {
    // Find the task directly above in the root tasks list
    // Call api.moveTask(listId:taskId:parentId:) to make it a child
    // Update local tasks array
}

func outdentTask(_ task: TaskItem) async {
    // Call api.moveTask(listId:taskId:previousId:) with no parent
    // previousId = the former parent's ID (to place it right after)
    // Update local tasks array
}
```

**Context menu additions (TaskListView.swift or TaskRowView.swift):**
- For root-level tasks that have a sibling above them: "Make Subtask" (indent)
- For subtasks (tasks with `parent != nil`): "Move to Top Level" (outdent)

**Keyboard shortcuts:** Deferred — context menu only for now.

### Constraints
- Google Tasks only supports **one level** of nesting. Do NOT allow indenting a subtask further (making a sub-subtask)
- Indent is only available for incomplete root-level tasks
- Outdent is only available for subtasks

---

## 3. Hover Highlight

### Current State
`TaskRowView` already has `@State private var isHovering` and applies a background:
```swift
.background(
    RoundedRectangle(cornerRadius: 6)
        .fill(isHovering ? Color.primary.opacity(0.05) : .clear)
)
```

### Changes
- Increase opacity slightly: `0.05` → `0.06` (subtle but more visible)
- Show context actions on hover: display a small trailing "..." button (or action icons) that appear on hover. This gives discoverability for the "Add Subtask" action without requiring right-click
  - The hover actions area appears at the trailing edge of the row
  - Contains: a `+` button (add subtask, only for root tasks) and optionally `⋯` for more actions
  - Fades in/out with the hover state

### Implementation
- In `TaskRowView`, add a trailing HStack that's only visible when `isHovering`
- Pass new callbacks: `onAddSubtask: (() -> Void)?` (nil for subtasks)
- The `+` button calls `onAddSubtask`
- Use `.opacity(isHovering ? 1 : 0)` with animation for smooth fade

---

## 4. Completion Animation

### Behavior
When a user checks off a task:
1. The circle fills with a **green checkmark** with a brief scale-up bounce (already partially there with `.contentTransition(.symbolEffect(.replace))`)
2. The title gets a **strikethrough that animates left-to-right** (or just appears)
3. After a **short delay (~600ms)**, the row **slides out to the right and fades**, then moves to the completed section
4. If the task has subtasks, they gray out together with the parent (already works)

### Implementation

**TaskRowView.swift:**
- Add `@State private var justCompleted = false`
- When `onToggle` is called and the task is going from incomplete → complete:
  - Set `justCompleted = true`
  - The checkmark circle gets a brief `.scaleEffect` pulse: scale to 1.2 then back to 1.0
- The existing `contentTransition(.symbolEffect(.replace))` on the checkmark icon handles the symbol swap animation already — keep that

**TaskListView.swift:**
- The transition is already defined:
  ```swift
  .transition(.asymmetric(
      insertion: .move(edge: .top).combined(with: .opacity),
      removal: .move(edge: .trailing).combined(with: .opacity)
  ))
  ```
  This should already animate the row sliding right when it moves from active to completed section. Verify this works correctly with the current animation block. If it doesn't trigger, we may need to add a brief delay before the optimistic update in `toggleTask` to let the animation play.

---

## Files to Modify

| File | Changes |
|------|---------|
| `TaskRowView.swift` | Hover action buttons, completion animation (scale pulse), add `onAddSubtask` callback |
| `TaskListView.swift` | Inline subtask field, context menu indent/outdent/add-subtask, keyboard shortcuts |
| `AppState.swift` | `indentTask()`, `outdentTask()` methods |

## Files to Create

None — all changes fit in existing files.

---

## Testing Notes

- Test indent when there's only one root task (should be disabled — no task above to become parent of)
- Test outdent places the task after its former parent
- Test that indenting a subtask is not possible (one-level limit)
- Test inline subtask field dismissal on Escape and focus loss
- Test completion animation plays before the row moves to completed section
- Test drag-and-drop still works with the new hover actions
