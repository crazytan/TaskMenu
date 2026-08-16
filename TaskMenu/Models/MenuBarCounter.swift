import Foundation

/// What the menu-bar status item counts. Raw values are persisted in UserDefaults.
enum MenuBarCounterMode: String, Codable, Sendable, CaseIterable, Identifiable {
    case off
    case openTasks
    case dueToday

    var id: String { rawValue }

    /// Settings pop-up label.
    var title: String {
        switch self {
        case .off: "Off"
        case .openTasks: "Open tasks"
        case .dueToday: "Due today"
        }
    }

    /// Whether `task` contributes to this mode's count. Subtasks are tasks and
    /// count like roots. `dueToday` includes overdue tasks; it compares the
    /// task's local due day (`TaskItem.dueDate(in:)`) with `now` at day
    /// granularity, matching the row's today/overdue colouring.
    func counts(_ task: TaskItem, now: Date = Date(), calendar: Calendar = .current) -> Bool {
        guard !task.isCompleted else { return false }
        switch self {
        case .off:
            return false
        case .openTasks:
            return true
        case .dueToday:
            guard let dueDate = task.dueDate(in: calendar) else { return false }
            return calendar.compare(dueDate, to: now, toGranularity: .day) != .orderedDescending
        }
    }
}

/// Number of tasks in `tasks` that `mode` counts. Zero for `.off`.
func pendingTaskCount(
    in tasks: [TaskItem],
    mode: MenuBarCounterMode,
    now: Date = Date(),
    calendar: Calendar = .current
) -> Int {
    tasks.reduce(0) { $0 + (mode.counts($1, now: now, calendar: calendar) ? 1 : 0) }
}
