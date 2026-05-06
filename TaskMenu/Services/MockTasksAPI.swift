import Foundation

actor MockTasksAPI: TasksAPIProtocol {
    private var taskLists: [TaskList]
    private var tasksByList: [String: [TaskItem]]

    init() {
        let today = DateFormatting.formatGoogleTaskDueDate(Date())

        taskLists = [
            TaskList(id: "list1", title: "My Tasks", selfLink: nil, updated: nil),
            TaskList(id: "list2", title: "Work", selfLink: nil, updated: nil),
        ]

        tasksByList = [
            "list1": [
                TaskItem(id: "task1", title: "Buy groceries", notes: nil, status: .needsAction, due: nil, selfLink: nil, parent: nil, position: "00000000000000000000", updated: nil),
                TaskItem(id: "task2", title: "Read chapter 5", notes: nil, status: .needsAction, due: nil, selfLink: nil, parent: nil, position: "00000000000000000001", updated: nil),
                TaskItem(id: "task3", title: "Take notes", notes: nil, status: .needsAction, due: nil, selfLink: nil, parent: "task2", position: "00000000000000000000", updated: nil),
                TaskItem(id: "task4", title: "Schedule dentist", notes: nil, status: .needsAction, due: today, selfLink: nil, parent: nil, position: "00000000000000000002", updated: nil),
                TaskItem(id: "task5", title: "File taxes", notes: nil, status: .completed, due: nil, selfLink: nil, parent: nil, position: "00000000000000000003", updated: nil),
            ],
            "list2": [],
        ]
    }

    func listTaskLists() async throws -> [TaskList] {
        taskLists
    }

    func listTasks(listId: String, showCompleted: Bool, showHidden: Bool) async throws -> [TaskItem] {
        let tasks = tasksByList[listId] ?? []
        if showCompleted {
            return tasks
        }
        return tasks.filter { !$0.isCompleted }
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
            position: "00000000000000000000",
            updated: nil
        )
        var tasks = tasksByList[listId] ?? []
        if let parentId {
            // Insert after parent and its existing subtasks
            if let parentIndex = tasks.firstIndex(where: { $0.id == parentId }) {
                var insertIndex = parentIndex + 1
                while insertIndex < tasks.count && tasks[insertIndex].parent == parentId {
                    insertIndex += 1
                }
                tasks.insert(task, at: insertIndex)
            } else {
                tasks.append(task)
            }
        } else {
            tasks.insert(task, at: 0)
        }
        tasksByList[listId] = tasks
        return task
    }

    func updateTask(listId: String, taskId: String, task: TaskItem) async throws -> TaskItem {
        var tasks = tasksByList[listId] ?? []
        if let index = tasks.firstIndex(where: { $0.id == taskId }) {
            tasks[index] = task
            tasksByList[listId] = tasks
        }
        return task
    }

    func deleteTask(listId: String, taskId: String) async throws {
        var tasks = tasksByList[listId] ?? []
        // Remove task and its children
        let childIDs = tasks.filter { $0.parent == taskId }.map(\.id)
        let removedIDs = Set([taskId] + childIDs)
        tasks.removeAll { removedIDs.contains($0.id) }
        tasksByList[listId] = tasks
    }

    func moveTask(listId: String, taskId: String, previousId: String?, parentId: String?) async throws -> TaskItem {
        var tasks = tasksByList[listId] ?? []
        guard let taskIndex = tasks.firstIndex(where: { $0.id == taskId }) else {
            throw APIError.serverError(404, "Task not found")
        }
        var task = tasks.remove(at: taskIndex)
        task.parent = parentId

        if let previousId, let prevIndex = tasks.firstIndex(where: { $0.id == previousId }) {
            tasks.insert(task, at: prevIndex + 1)
        } else if let parentId, let parentIndex = tasks.firstIndex(where: { $0.id == parentId }) {
            tasks.insert(task, at: parentIndex + 1)
        } else {
            tasks.insert(task, at: 0)
        }

        tasksByList[listId] = tasks
        return task
    }
}
