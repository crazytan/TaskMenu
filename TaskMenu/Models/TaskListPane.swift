import Foundation
import Observation

enum TaskListPaneID: String, Sendable {
    case primary
    case secondary
}

/// Per-pane task-list state: the list a pane shows, that list's tasks as the
/// pane sees them, its filter text, and its disclosure state. `AppState` owns
/// exactly two (`primaryPane`, `secondaryPane`) and is the only mutation path
/// for `selectedListId`/`tasks`; views may write `searchText` and the
/// disclosure state directly, as they did on `AppState` before.
@MainActor
@Observable
final class TaskListPane: Identifiable {
    let id: TaskListPaneID
    var selectedListId: String?
    var tasks: [TaskItem] = []
    var searchText: String = ""
    var collapsedTaskIDs: Set<String> = []
    /// True while a task load for this pane is in flight; drives this pane's
    /// header spinner and empty-state spinner only.
    var isLoading = false
    /// `AppState` bookkeeping: monotonic token for this pane's task loads so
    /// a stale response cannot overwrite a newer selection. Not for views.
    @ObservationIgnored var taskLoadRequestID = 0

    init(id: TaskListPaneID) {
        self.id = id
    }

    /// Whether this pane's filter is active.
    var isSearching: Bool {
        !searchText.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// Expands a parent task so its subtasks are visible. Used when a new
    /// subtask row has to be shown under a collapsed parent.
    func expandTask(_ taskID: String) {
        collapsedTaskIDs.remove(taskID)
    }

    /// Toggle collapse state for a parent task.
    func toggleCollapsed(_ taskID: String) {
        if collapsedTaskIDs.contains(taskID) {
            collapsedTaskIDs.remove(taskID)
        } else {
            collapsedTaskIDs.insert(taskID)
        }
    }

    /// The list the secondary pane starts on: the one after `primaryListID`
    /// in `taskLists` order, wrapping to the first (so a single list is
    /// shown twice). Falls back to the first list when the primary has no
    /// (known) selection; nil when there are no lists.
    static func defaultSecondaryListID(in taskLists: [TaskList], after primaryListID: String?) -> String? {
        guard !taskLists.isEmpty else { return nil }
        guard let primaryListID,
              let index = taskLists.firstIndex(where: { $0.id == primaryListID })
        else {
            return taskLists.first?.id
        }
        return taskLists[(index + 1) % taskLists.count].id
    }
}
