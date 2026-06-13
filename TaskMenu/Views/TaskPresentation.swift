import Foundation

enum TaskRowSection {
    case active
    case completed
}

func subtasksWithCompletedLast(_ subtasks: [TaskItem]) -> [TaskItem] {
    subtasks.filter { !$0.isCompleted } + subtasks.filter(\.isCompleted)
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
}
