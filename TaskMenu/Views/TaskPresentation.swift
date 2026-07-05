import Foundation

enum TaskRowSection {
    case active
    case completed
}

func completedTasksForFinalSection(_ tasks: [TaskItem]) -> [TaskItem] {
    let taskByID = Dictionary(uniqueKeysWithValues: tasks.map { ($0.id, $0) })
    let completedRoots = tasksSortedByGooglePosition(tasks.filter { task in
        task.isCompleted && (task.parent == nil || task.parent.flatMap { taskByID[$0] } == nil)
    })
    var orderedTasks: [TaskItem] = []

    // Walk all children of completed roots, including incomplete ones, so an
    // orphaned incomplete subtask of a completed parent still renders somewhere.
    func appendCompletedTaskTree(from task: TaskItem) {
        orderedTasks.append(task)
        let children = tasksSortedByGooglePosition(tasks.filter { child in
            child.parent == task.id
        })
        for child in children {
            appendCompletedTaskTree(from: child)
        }
    }

    for task in completedRoots {
        appendCompletedTaskTree(from: task)
    }
    return orderedTasks
}

func completedSubtasksForOpenParent(_ parentID: String, tasks: [TaskItem]) -> [TaskItem] {
    tasksSortedByGooglePosition(tasks.filter { task in
        task.parent == parentID && task.isCompleted
    })
}

func subtasksWithCompletedLast(_ subtasks: [TaskItem]) -> [TaskItem] {
    subtasks.filter { !$0.isCompleted } + subtasks.filter(\.isCompleted)
}

func searchResultCountText(_ count: Int) -> String {
    count == 1 ? "1 result" : "\(count) results"
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

struct TaskListTaskEntry {
    let task: TaskItem
    let indentLevel: Int
    let section: TaskRowSection
}

@MainActor
enum TaskListPresentation {
    static func displayRootTasks(from appState: AppState) -> [TaskItem] {
        appState.isSearching ? appState.searchFilteredRootTasks : appState.rootTasks
    }

    static func incompleteRootTasks(from appState: AppState) -> [TaskItem] {
        displayRootTasks(from: appState).filter { !$0.isCompleted }
    }

    /// Task set used to build the final completed section; search-filtered while searching.
    static func completedSectionSourceTasks(from appState: AppState) -> [TaskItem] {
        appState.isSearching ? appState.searchFilteredTasks : appState.tasks
    }

    /// Children shown under an open parent. While searching, matching subtasks
    /// (complete and incomplete) appear inline for context.
    static func displaySubtasks(of taskID: String, from appState: AppState) -> [TaskItem] {
        appState.isSearching ? appState.searchFilteredSubtasks(of: taskID) : appState.subtasks(of: taskID)
    }
}
