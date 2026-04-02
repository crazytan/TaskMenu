import Foundation

protocol TasksAPIProtocol: Sendable {
    func listTaskLists() async throws -> [TaskList]
    func listTasks(listId: String, showCompleted: Bool, showHidden: Bool) async throws -> [TaskItem]
    func createTask(listId: String, title: String, notes: String?, due: String?, parentId: String?) async throws -> TaskItem
    func updateTask(listId: String, taskId: String, task: TaskItem) async throws -> TaskItem
    func deleteTask(listId: String, taskId: String) async throws
    func moveTask(listId: String, taskId: String, previousId: String?, parentId: String?) async throws -> TaskItem
}

extension TasksAPIProtocol {
    func listTasks(listId: String, showCompleted: Bool = true, showHidden: Bool = true) async throws -> [TaskItem] {
        try await listTasks(listId: listId, showCompleted: showCompleted, showHidden: showHidden)
    }

    func createTask(listId: String, title: String, notes: String? = nil, due: String? = nil, parentId: String? = nil) async throws -> TaskItem {
        try await createTask(listId: listId, title: title, notes: notes, due: due, parentId: parentId)
    }

    func moveTask(listId: String, taskId: String, previousId: String? = nil, parentId: String? = nil) async throws -> TaskItem {
        try await moveTask(listId: listId, taskId: taskId, previousId: previousId, parentId: parentId)
    }
}
