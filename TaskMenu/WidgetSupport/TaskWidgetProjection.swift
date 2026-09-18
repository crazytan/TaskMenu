import Foundation

/// Presentation-facing row budgets. Kept as plain tunable constants (rather
/// than folded into a WidgetKit-only type) so both the widget provider and
/// tests can reference them without this file importing WidgetKit.
enum TaskWidgetProjectionConstants {
    static let smallRowBudget = 3
    static let mediumRowBudget = 6
    static let largeRowBudget = 10
}

/// Compact due-date presentation bucket for one row. Computed with the
/// repository's date-only Google due-date semantics
/// (`TaskItem.dueDate(in:)` / `DateFormatting`), never by comparing raw wire
/// strings.
enum TaskWidgetDueTreatment: Sendable, Equatable {
    /// No due date set.
    case undated
    /// Due date's local calendar day is strictly before `now`'s.
    case overdue
    /// Due date's local calendar day matches `now`'s.
    case dueToday
    /// Due date's local calendar day is `now`'s plus one day.
    case dueTomorrow
    /// Any other dated due date (future beyond tomorrow, or malformed-but-present).
    case dated(Date)
}

/// One row the widget can render: either a visible root task or one of its
/// open direct subtasks, immediately following that root.
struct TaskWidgetProjectedRow: Sendable, Equatable, Identifiable {
    var id: String { task.id }
    let task: TaskWidgetTaskSnapshot
    /// `true` for an open direct subtask row, rendered indented under its
    /// parent. `false` for a root row (including an orphaned subtask — see
    /// `TaskWidgetProjection`'s orphan policy).
    let isSubtask: Bool
    let dueTreatment: TaskWidgetDueTreatment
}

/// The rows selected for one widget rendering, plus how many additional
/// open rows did not fit inside the family's row budget.
struct TaskWidgetProjectedList: Sendable, Equatable {
    let rows: [TaskWidgetProjectedRow]
    /// Count backing the "+N more" affordance. Zero when everything fit.
    let remainderCount: Int
}

/// Turns a list's minimized, unordered task cache into the rows one widget
/// family should render: open-only filtering, root ordering, subtask
/// flattening, and row-budget truncation.
enum TaskWidgetProjection {
    /// Projects `tasks` (one list's full minimized cache, any status/order)
    /// into a widget-ready row list.
    ///
    /// Rules:
    /// - Only `needsAction` tasks are ever shown; a completed task (parent
    ///   or child) disappears from the projection entirely.
    /// - A task is a **root** when it has no `parent`, or when its `parent`
    ///   is not present among the open tasks. The latter is the orphan
    ///   policy: a subtask whose parent is completed, deleted, or otherwise
    ///   missing from this snapshot is promoted to a root rather than
    ///   silently dropped, since Google Tasks is only one parent level deep
    ///   and there is no ancestor to reattach it to.
    /// - Roots are ordered by `sortOrder`, reusing `tasksSorted(_:by:calendar:)`
    ///   (the same function `AppState`/`TaskSortOrder` use) so "My order"
    ///   and "Due date" match the app exactly, including the Google-position
    ///   tie-break.
    /// - Each visible root is immediately followed by its open direct
    ///   subtasks in Google sibling order (`tasksSortedByGooglePosition`),
    ///   each consuming its own row slot.
    /// - Rows are truncated to `rowBudget` (see `TaskWidgetProjectionConstants`);
    ///   `remainderCount` is however many rows were cut, even if the cut
    ///   lands in the middle of one root's subtask group.
    static func project(
        tasks: [TaskWidgetTaskSnapshot],
        sortOrder: TaskSortOrder,
        rowBudget: Int,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> TaskWidgetProjectedList {
        let openTasks = tasks.filter { $0.status == .needsAction }
        let openIDs = Set(openTasks.map(\.id))

        func isRoot(_ task: TaskWidgetTaskSnapshot) -> Bool {
            guard let parent = task.parent else { return true }
            return !openIDs.contains(parent)
        }

        let roots = openTasks.filter(isRoot)
        let sortedRoots = orderPreservingTaskItemSort(roots) { tasksSorted($0, by: sortOrder, calendar: calendar) }

        var subtasksByParent: [String: [TaskWidgetTaskSnapshot]] = [:]
        for task in openTasks where !isRoot(task) {
            subtasksByParent[task.parent!, default: []].append(task)
        }
        for (parentID, children) in subtasksByParent {
            subtasksByParent[parentID] = orderPreservingTaskItemSort(children, tasksSortedByGooglePosition)
        }

        var rows: [TaskWidgetProjectedRow] = []
        rows.reserveCapacity(openTasks.count)
        for root in sortedRoots {
            rows.append(
                TaskWidgetProjectedRow(
                    task: root,
                    isSubtask: false,
                    dueTreatment: dueTreatment(for: root.due, now: now, calendar: calendar)
                )
            )
            for subtask in subtasksByParent[root.id] ?? [] {
                rows.append(
                    TaskWidgetProjectedRow(
                        task: subtask,
                        isSubtask: true,
                        dueTreatment: dueTreatment(for: subtask.due, now: now, calendar: calendar)
                    )
                )
            }
        }

        let visibleRows = Array(rows.prefix(max(0, rowBudget)))
        return TaskWidgetProjectedList(rows: visibleRows, remainderCount: rows.count - visibleRows.count)
    }

    /// Computes the due treatment for a raw Google due-date wire string
    /// (`yyyy-MM-ddT00:00:00.000Z`, or `nil` for undated), using
    /// `TaskItem.dueDate(in:)`'s date-only parsing so a task at midnight UTC
    /// lands on the correct local calendar day across time zones and DST
    /// boundaries.
    static func dueTreatment(for due: String?, now: Date = Date(), calendar: Calendar = .current) -> TaskWidgetDueTreatment {
        // Mirrors `TaskItem.dueDate(in:)` exactly (it forwards to the same
        // `DateFormatting` call); calling `DateFormatting` directly avoids
        // constructing a throwaway `TaskItem` just to parse a due string.
        guard let due, let dueDate = DateFormatting.parseGoogleTaskDueDate(due, calendar: calendar) else {
            return .undated
        }

        let today = calendar.startOfDay(for: now)
        if calendar.isDate(dueDate, inSameDayAs: today) {
            return .dueToday
        }
        if let tomorrow = calendar.date(byAdding: .day, value: 1, to: today), calendar.isDate(dueDate, inSameDayAs: tomorrow) {
            return .dueTomorrow
        }
        if dueDate < today {
            return .overdue
        }
        return .dated(dueDate)
    }

    /// Adapts the widget's minimized task snapshots into `TaskItem`
    /// instances (using only the fields the sorters read: `position`/`due`)
    /// so root ordering can call the exact same sorters `AppState` uses,
    /// then maps the sorted order back onto the original snapshots by id.
    /// This keeps ordering semantics as a single source of truth instead of
    /// re-implementing position/due-date comparison here.
    private static func orderPreservingTaskItemSort(
        _ tasks: [TaskWidgetTaskSnapshot],
        _ sort: ([TaskItem]) -> [TaskItem]
    ) -> [TaskWidgetTaskSnapshot] {
        guard !tasks.isEmpty else { return [] }
        let byID = Dictionary(uniqueKeysWithValues: tasks.map { ($0.id, $0) })
        let items = tasks.map { snapshot in
            TaskItem(
                id: snapshot.id,
                title: snapshot.title,
                notes: nil,
                status: snapshot.status,
                due: snapshot.due,
                selfLink: nil,
                parent: snapshot.parent,
                position: snapshot.position,
                updated: nil
            )
        }
        return sort(items).compactMap { byID[$0.id] }
    }
}
