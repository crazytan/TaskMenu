import Foundation

/// How root tasks are ordered in the task list. Subtasks always keep Google's
/// sibling order under their parent, and the completed section is unaffected.
enum TaskSortOrder: String, Codable, Sendable, CaseIterable {
    /// Google's `position` order — the order shown on the Google Tasks website.
    case myOrder
    /// Ascending due date, undated tasks last, ties broken by Google position.
    case dueDate

    /// Menu title shown in the "Sort by" submenu.
    var displayName: String {
        switch self {
        case .myOrder: "My order"
        case .dueDate: "Due date"
        }
    }
}

/// Orders tasks by due date ascending (overdue first), all dated tasks before
/// undated ones, and falls back to Google position (`tasksSortedByGooglePosition`)
/// for tasks due on the same day and for the undated tail. Due dates are
/// compared as the local calendar day `TaskItem.dueDate(in:)` resolves them to.
func tasksSortedByDueDate(_ tasks: [TaskItem], calendar: Calendar = .current) -> [TaskItem] {
    // Position order first so the due-date sort only has to decide ties. The
    // key is precomputed so the comparator never re-parses a due string.
    let positioned = tasksSortedByGooglePosition(tasks)
    let keyed = positioned.enumerated().map { offset, task in
        (offset: offset, task: task, dueDate: task.dueDate(in: calendar))
    }
    return keyed
        .sorted { left, right in
            switch (left.dueDate, right.dueDate) {
            case let (leftDue?, rightDue?) where leftDue != rightDue:
                return leftDue < rightDue
            case (_?, nil):
                return true
            case (nil, _?):
                return false
            default:
                return left.offset < right.offset
            }
        }
        .map(\.task)
}

/// Dispatches to the sorter for `order`.
func tasksSorted(_ tasks: [TaskItem], by order: TaskSortOrder, calendar: Calendar = .current) -> [TaskItem] {
    switch order {
    case .myOrder: tasksSortedByGooglePosition(tasks)
    case .dueDate: tasksSortedByDueDate(tasks, calendar: calendar)
    }
}
