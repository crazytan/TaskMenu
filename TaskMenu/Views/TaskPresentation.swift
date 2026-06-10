import CoreGraphics
import Foundation

enum TaskRowSection {
    case active
    case completed
}

enum TaskListLayout {
    static let completedHeaderTopPadding: CGFloat = 2
}

func shouldPlaceInlineSubtaskField(
    after task: TaskItem,
    parentID: String?,
    isSearching: Bool,
    section: TaskRowSection
) -> Bool {
    guard let parentID else { return false }
    guard !isSearching else { return false }
    guard section == .active else { return false }
    return task.id == parentID
}

func subtasksWithCompletedLast(_ subtasks: [TaskItem]) -> [TaskItem] {
    subtasks.filter { !$0.isCompleted } + subtasks.filter(\.isCompleted)
}

func visibleSubtasks(
    _ subtasks: [TaskItem],
    under parent: TaskItem,
    isSearching: Bool,
    completedSubtasksRevealed: Bool
) -> [TaskItem] {
    guard !isSearching, !parent.isCompleted, !completedSubtasksRevealed else {
        return subtasksWithCompletedLast(subtasks)
    }

    return subtasks.filter { !$0.isCompleted }
}

func completedSubtasksRevealCount(
    _ subtasks: [TaskItem],
    under parent: TaskItem,
    isSearching: Bool
) -> Int {
    guard !isSearching, !parent.isCompleted else { return 0 }
    return subtasks.filter(\.isCompleted).count
}

func completedSubtasksRevealTitle(count: Int, isRevealed: Bool) -> String {
    if isRevealed {
        return "Hide completed subtasks"
    }

    let label = count == 1 ? "completed subtask" : "completed subtasks"
    return "Show \(count) \(label)"
}

func taskNotesPreview(for task: TaskItem) -> String? {
    guard let notes = task.notes?.trimmingCharacters(in: .whitespacesAndNewlines),
          !notes.isEmpty
    else {
        return nil
    }

    return notes
}

struct TaskDetailDueDateState {
    var isEnabled: Bool
    var selection: Date

    init(task: TaskItem, defaultDate: @autoclosure () -> Date = Date()) {
        if let dueDate = task.dueDate {
            isEnabled = true
            selection = dueDate
        } else {
            isEnabled = false
            selection = defaultDate()
        }
    }

    mutating func enable(defaultDate: @autoclosure () -> Date = Date()) {
        guard !isEnabled else { return }
        isEnabled = true
        selection = defaultDate()
    }

    mutating func clear() {
        isEnabled = false
    }

    func applying(to task: TaskItem) -> TaskItem {
        var updatedTask = task
        if isEnabled {
            updatedTask.dueDate = selection
        } else {
            updatedTask.clearDueDate()
        }
        return updatedTask
    }
}

enum TaskDetailLayout {
    static let subtaskRowHeight: CGFloat = 24
    static let subtaskRowSpacing: CGFloat = 6
    static let subtaskListVerticalPadding: CGFloat = 1
    static let subtaskListMinimumVisibleRows = 3
    static let contentBottomPadding: CGFloat = 16

    static func subtaskListMinimumHeight(forCount count: Int) -> CGFloat {
        guard count > 0 else { return 0 }
        let visibleRowCount = min(count, subtaskListMinimumVisibleRows)
        let rowHeights = CGFloat(visibleRowCount) * subtaskRowHeight
        let rowSpacing = CGFloat(visibleRowCount - 1) * subtaskRowSpacing
        let verticalPadding = subtaskListVerticalPadding * 2
        return rowHeights + rowSpacing + verticalPadding
    }
}

struct TaskListTaskEntry {
    let task: TaskItem
    let indentLevel: Int
    let isParentCompleted: Bool
    let section: TaskRowSection
}

struct CompletedSubtasksRevealEntry {
    let parentID: String
    let count: Int
    let indentLevel: Int
    let isRevealed: Bool
    let section: TaskRowSection
}

enum TaskListEntry {
    case task(TaskListTaskEntry)
    case completedSubtasksReveal(CompletedSubtasksRevealEntry)
}

@MainActor
enum TaskListPresentation {
    static func displayRootTasks(from appState: AppState) -> [TaskItem] {
        appState.isSearching ? appState.searchFilteredRootTasks : appState.rootTasks
    }

    static func incompleteRootTasks(from appState: AppState) -> [TaskItem] {
        displayRootTasks(from: appState).filter { !$0.isCompleted }
    }

    static func completedRootTasks(from appState: AppState) -> [TaskItem] {
        displayRootTasks(from: appState).filter { $0.isCompleted }
    }

    static func searchResultCount(from appState: AppState) -> Int {
        appState.searchFilteredTasks.count
    }

    static func flattenedEntries(
        roots: [TaskItem],
        section: TaskRowSection,
        appState: AppState,
        revealedCompletedSubtaskParentIDs: Set<String>
    ) -> [TaskListEntry] {
        var result: [TaskListEntry] = []

        func walk(_ task: TaskItem, level: Int, parentCompleted: Bool) {
            result.append(.task(
                TaskListTaskEntry(
                    task: task,
                    indentLevel: level,
                    isParentCompleted: parentCompleted,
                    section: section
                )
            ))

            let isCollapsed = appState.collapsedTaskIDs.contains(task.id)
            guard !isCollapsed else { return }

            let allChildren = appState.isSearching
                ? appState.searchFilteredSubtasks(of: task.id)
                : appState.subtasks(of: task.id)
            let isRevealed = revealedCompletedSubtaskParentIDs.contains(task.id)
            let visibleChildren = visibleSubtasks(
                allChildren,
                under: task,
                isSearching: appState.isSearching,
                completedSubtasksRevealed: isRevealed
            )

            for child in visibleChildren {
                walk(child, level: level + 1, parentCompleted: parentCompleted || task.isCompleted)
            }

            let hiddenCompletedCount = completedSubtasksRevealCount(
                allChildren,
                under: task,
                isSearching: appState.isSearching
            )
            if hiddenCompletedCount > 0 {
                result.append(.completedSubtasksReveal(
                    CompletedSubtasksRevealEntry(
                        parentID: task.id,
                        count: hiddenCompletedCount,
                        indentLevel: level + 1,
                        isRevealed: isRevealed,
                        section: section
                    )
                ))
            }
        }

        for root in roots {
            walk(root, level: 0, parentCompleted: false)
        }
        return result
    }
}
