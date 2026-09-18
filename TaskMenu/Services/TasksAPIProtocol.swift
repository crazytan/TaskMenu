import Foundation

protocol TasksAPIProtocol: Sendable {
    func listTaskLists() async throws -> [TaskList]
    /// Creates a task list titled `title` and returns the server's copy.
    func createTaskList(title: String) async throws -> TaskList
    func listTasks(listId: String, showCompleted: Bool, showHidden: Bool) async throws -> [TaskItem]
    func createTask(listId: String, title: String, notes: String?, due: String?, parentId: String?) async throws -> TaskItem
    func updateTask(listId: String, taskId: String, task: TaskItem) async throws -> TaskItem
    func deleteTask(listId: String, taskId: String) async throws
    /// Moves a task under `parentId` (top level when nil), directly after
    /// sibling `previousTaskId` (first among siblings when nil). When
    /// `destinationListId` is set, the task leaves `listId` for that list and
    /// `parentId`/`previousTaskId` refer to tasks in the destination list.
    func moveTask(
        listId: String,
        taskId: String,
        parentId: String?,
        previousTaskId: String?,
        destinationListId: String?
    ) async throws -> TaskItem
    /// Marks a task completed. `GoogleTasksAPI` sends a status-only PATCH so
    /// the widget's completion intent does not need to carry an entire
    /// `TaskItem`; the default implementation (below) routes through
    /// `updateTask` with a completed copy so other conformers do not need to
    /// know about completion specifically.
    func setTaskCompleted(listId: String, taskId: String) async throws -> TaskItem
}

extension TasksAPIProtocol {
    /// Same-list move; see the five-argument requirement.
    func moveTask(listId: String, taskId: String, parentId: String?, previousTaskId: String?) async throws -> TaskItem {
        try await moveTask(
            listId: listId,
            taskId: taskId,
            parentId: parentId,
            previousTaskId: previousTaskId,
            destinationListId: nil
        )
    }

    func listTasks(listId: String, showCompleted: Bool = true, showHidden: Bool = true) async throws -> [TaskItem] {
        try await listTasks(listId: listId, showCompleted: showCompleted, showHidden: showHidden)
    }

    func createTask(listId: String, title: String, notes: String? = nil, due: String? = nil, parentId: String? = nil) async throws -> TaskItem {
        try await createTask(listId: listId, title: title, notes: notes, due: due, parentId: parentId)
    }

    /// Default: fetches the task from `listId`, marks it completed, and
    /// routes through `updateTask` so `DemoTasksAPI`, the `--testing-window`
    /// fake, and test doubles keep compiling and behaving correctly without
    /// any changes — they already implement `updateTask` by overwriting the
    /// stored task with whatever is passed in, so this preserves every
    /// other field. `GoogleTasksAPI` overrides this with a real,
    /// status-only PATCH.
    func setTaskCompleted(listId: String, taskId: String) async throws -> TaskItem {
        let tasks = try await listTasks(listId: listId)
        guard var task = tasks.first(where: { $0.id == taskId }) else {
            throw APIError.serverError(404, "Task not found")
        }
        task.isCompleted = true
        return try await updateTask(listId: listId, taskId: taskId, task: task)
    }
}
