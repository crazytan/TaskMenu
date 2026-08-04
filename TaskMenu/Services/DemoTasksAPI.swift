import Foundation

/// In-memory sample data backing demo mode, so the app can be used without a
/// Google account. Mutations live and die with the demo session. Unlike the
/// deliberately odd `TestingWindowTasksAPI` fixtures, this content is realistic.
actor DemoTasksAPI: TasksAPIProtocol {
    private let lists = [
        TaskList(id: "demo-today", title: "Today", selfLink: nil, updated: nil),
        TaskList(id: "demo-work", title: "Work", selfLink: nil, updated: nil),
        TaskList(id: "demo-personal", title: "Personal", selfLink: nil, updated: nil)
    ]
    private var tasksByListID: [String: [TaskItem]]

    init() {
        func due(inDays offset: Int) -> String? {
            guard let date = Calendar.current.date(byAdding: .day, value: offset, to: Date()) else { return nil }
            return DateFormatting.formatGoogleTaskDueDate(date)
        }

        func task(
            _ id: String,
            _ title: String,
            notes: String? = nil,
            status: TaskItem.TaskStatus = .needsAction,
            dueInDays: Int? = nil,
            parent: String? = nil,
            position: String
        ) -> TaskItem {
            TaskItem(
                id: id,
                title: title,
                notes: notes,
                status: status,
                due: dueInDays.flatMap { due(inDays: $0) },
                selfLink: nil,
                parent: parent,
                position: position,
                updated: nil
            )
        }

        tasksByListID = [
            "demo-today": [
                task(
                    "today-standup",
                    "Write up standup notes",
                    notes: "Blockers first, then what shipped yesterday.",
                    dueInDays: 0,
                    position: "0001"
                ),
                task(
                    "today-review",
                    "Review the pull request queue",
                    notes: "Start with anything blocking the release branch.",
                    dueInDays: 0,
                    position: "0002"
                ),
                task("today-review-api", "Sync the API client changes", parent: "today-review", position: "0001"),
                task("today-review-tests", "Leave notes on the test plan", parent: "today-review", position: "0002"),
                task("today-invoice", "Send the March invoice", dueInDays: -1, position: "0003"),
                task("today-walk", "Afternoon walk", dueInDays: 0, position: "0004"),
                task("today-inbox", "Clear the inbox", status: .completed, dueInDays: 0, position: "0005")
            ],
            "demo-work": [
                task(
                    "work-launch",
                    "Ship the 2.0 launch checklist",
                    notes: "Everything below has to land before the announcement goes out.",
                    dueInDays: 3,
                    position: "0001"
                ),
                task("work-launch-copy", "Finalize the release notes", parent: "work-launch", position: "0001"),
                task("work-launch-assets", "Export the marketing screenshots", dueInDays: 1, parent: "work-launch", position: "0002"),
                task("work-launch-qa", "Run the regression pass", status: .completed, parent: "work-launch", position: "0003"),
                task("work-roadmap", "Draft next quarter's roadmap", dueInDays: 7, position: "0002"),
                task("work-onemore", "Book the team offsite", dueInDays: 14, position: "0003"),
                task("work-retro", "Schedule the sprint retro", status: .completed, dueInDays: -2, position: "0004")
            ],
            "demo-personal": [
                task("personal-groceries", "Pick up groceries", notes: "Coffee, olive oil, lemons.", dueInDays: 0, position: "0001"),
                task("personal-dentist", "Book a dentist appointment", dueInDays: -3, position: "0002"),
                task("personal-trip", "Plan the summer trip", dueInDays: 21, position: "0003"),
                task("personal-trip-flights", "Compare flight prices", parent: "personal-trip", position: "0001"),
                task("personal-trip-stay", "Shortlist places to stay", parent: "personal-trip", position: "0002"),
                task("personal-books", "Return the library books", status: .completed, dueInDays: -1, position: "0004")
            ]
        ]
    }

    func listTaskLists() async throws -> [TaskList] {
        lists
    }

    func listTasks(listId: String, showCompleted: Bool, showHidden: Bool) async throws -> [TaskItem] {
        let tasks = tasksByListID[listId] ?? []
        return showCompleted ? tasks : tasks.filter { !$0.isCompleted }
    }

    func createTask(listId: String, title: String, notes: String?, due: String?, parentId: String?) async throws -> TaskItem {
        let task = TaskItem(
            id: UUID().uuidString,
            title: title,
            notes: notes,
            status: .needsAction,
            due: due,
            selfLink: nil,
            parent: parentId,
            position: String(format: "%04d", (tasksByListID[listId]?.count ?? 0) + 1),
            updated: nil
        )
        tasksByListID[listId, default: []].insert(task, at: 0)
        return task
    }

    func updateTask(listId: String, taskId: String, task: TaskItem) async throws -> TaskItem {
        if let index = tasksByListID[listId]?.firstIndex(where: { $0.id == taskId }) {
            tasksByListID[listId]?[index] = task
        }
        return task
    }

    func deleteTask(listId: String, taskId: String) async throws {
        let tasks = tasksByListID[listId] ?? []
        let childIDs = tasks.filter { $0.parent == taskId }.map(\.id)
        let removedIDs = Set([taskId] + childIDs)
        tasksByListID[listId]?.removeAll { removedIDs.contains($0.id) }
    }

    func moveTask(listId: String, taskId: String, parentId: String?, previousTaskId: String?) async throws -> TaskItem {
        guard let tasks = tasksByListID[listId],
              let reordered = tasksReorderedAfterMove(
                tasks,
                movedTaskID: taskId,
                newParentID: parentId,
                previousTaskID: previousTaskId
              ),
              let movedTask = reordered.first(where: { $0.id == taskId })
        else {
            throw APIError.serverError(400, "Invalid move")
        }
        tasksByListID[listId] = reordered
        return movedTask
    }
}
