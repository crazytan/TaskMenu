import SwiftUI

@MainActor
@Observable
final class AppState {
    var isSignedIn = false
    var isLoading = false
    var errorMessage: String?

    var taskLists: [TaskList] = []
    var selectedListId: String?
    var tasks: [TaskItem] = []
    var collapsedTaskIDs: Set<String> = []
    var searchText: String = ""
    var dueDateNotificationsEnabled: Bool {
        didSet {
            userDefaults.set(
                dueDateNotificationsEnabled,
                forKey: Constants.UserDefaults.dueDateNotificationsEnabledKey
            )
            let enabled = dueDateNotificationsEnabled
            Task { [weak self] in
                guard let self else { return }
                await self.applyDueDateNotificationsPreferenceChange(enabled: enabled)
            }
        }
    }

    var selectedList: TaskList? {
        taskLists.first { $0.id == selectedListId }
    }

    /// Root-level tasks (no parent), preserving API order.
    var rootTasks: [TaskItem] {
        tasks.filter { $0.parent == nil }
    }

    /// Children of a given task, preserving API order.
    func subtasks(of taskID: String) -> [TaskItem] {
        tasks.filter { $0.parent == taskID }
    }

    /// Whether a task has any children.
    func hasSubtasks(_ taskID: String) -> Bool {
        tasks.contains { $0.parent == taskID }
    }

    /// Whether search is currently active.
    var isSearching: Bool {
        !searchText.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// Tasks filtered by the current search text.
    /// When searching, includes tasks that match by title/notes, plus parents of matching subtasks.
    /// Returns all tasks when search text is empty.
    var searchFilteredTasks: [TaskItem] {
        guard isSearching else { return tasks }
        let query = searchText.lowercased()

        // Find all directly matching task IDs
        let directMatchIDs = Set(tasks.filter { taskMatchesQuery($0, query: query) }.map(\.id))

        // Build the visible set: direct matches + parents of matching subtasks
        var visibleIDs = directMatchIDs
        for task in tasks where directMatchIDs.contains(task.id) {
            if let parentID = task.parent {
                visibleIDs.insert(parentID)
            }
        }

        return tasks.filter { visibleIDs.contains($0.id) }
    }

    /// Root-level tasks from the search-filtered set.
    var searchFilteredRootTasks: [TaskItem] {
        searchFilteredTasks.filter { $0.parent == nil }
    }

    /// Subtasks of a given task from the search-filtered set.
    func searchFilteredSubtasks(of taskID: String) -> [TaskItem] {
        searchFilteredTasks.filter { $0.parent == taskID }
    }

    private func taskMatchesQuery(_ task: TaskItem, query: String) -> Bool {
        if task.title.lowercased().contains(query) { return true }
        if let notes = task.notes, notes.lowercased().contains(query) { return true }
        return false
    }

    /// Toggle collapse state for a parent task.
    func toggleCollapsed(_ taskID: String) {
        if collapsedTaskIDs.contains(taskID) {
            collapsedTaskIDs.remove(taskID)
        } else {
            collapsedTaskIDs.insert(taskID)
        }
    }

    /// Whether a root-level task can be indented (made a subtask of the task above it).
    func canIndentTask(_ task: TaskItem) -> Bool {
        guard task.parent == nil, !task.isCompleted, !hasSubtasks(task.id) else { return false }
        let roots = rootTasks.filter { !$0.isCompleted }
        guard let index = roots.firstIndex(where: { $0.id == task.id }), index > 0 else { return false }
        return true
    }

    /// Whether a subtask can be outdented (moved to root level).
    func canOutdentTask(_ task: TaskItem) -> Bool {
        task.parent != nil
    }

    /// Indent a root-level task to become a subtask of the task directly above it.
    func indentTask(_ task: TaskItem) async {
        guard let listId = selectedListId else { return }
        guard canIndentTask(task) else { return }

        let roots = rootTasks.filter { !$0.isCompleted }
        guard let taskIndex = roots.firstIndex(where: { $0.id == task.id }), taskIndex > 0 else { return }
        let newParent = roots[taskIndex - 1]

        let originalTasks = tasks
        if let idx = tasks.firstIndex(where: { $0.id == task.id }) {
            var updatedTask = tasks.remove(at: idx)
            updatedTask.parent = newParent.id
            if let parentIdx = tasks.firstIndex(where: { $0.id == newParent.id }) {
                let insertIdx = tasks.indices
                    .suffix(from: parentIdx + 1)
                    .first(where: { tasks[$0].parent != newParent.id }) ?? tasks.endIndex
                tasks.insert(updatedTask, at: insertIdx)
            }
        }

        do {
            let movedTask = try await api.moveTask(
                listId: listId,
                taskId: task.id,
                parentId: newParent.id
            )
            if let index = tasks.firstIndex(where: { $0.id == movedTask.id }) {
                tasks[index] = movedTask
            }
        } catch {
            tasks = originalTasks
            handleError(error)
        }
    }

    /// Outdent a subtask to become a root-level task, placed after its former parent.
    func outdentTask(_ task: TaskItem) async {
        guard let listId = selectedListId else { return }
        guard let parentId = task.parent else { return }

        let originalTasks = tasks
        if let idx = tasks.firstIndex(where: { $0.id == task.id }) {
            var updatedTask = tasks.remove(at: idx)
            updatedTask.parent = nil
            if let parentIdx = tasks.firstIndex(where: { $0.id == parentId }) {
                let insertIdx = tasks.indices
                    .suffix(from: parentIdx + 1)
                    .first(where: { tasks[$0].parent != parentId }) ?? tasks.endIndex
                tasks.insert(updatedTask, at: insertIdx)
            } else {
                tasks.append(updatedTask)
            }
        }

        do {
            let movedTask = try await api.moveTask(
                listId: listId,
                taskId: task.id,
                previousId: parentId
            )
            if let index = tasks.firstIndex(where: { $0.id == movedTask.id }) {
                tasks[index] = movedTask
            }
        } catch {
            tasks = originalTasks
            handleError(error)
        }
    }

    private let authService: GoogleAuthService
    private let api: GoogleTasksAPI
    private let userDefaults: UserDefaults
    private let dueDateNotificationService: any DueDateNotificationServicing

    /// Whether completed tasks have been fetched for the current list
    private var completedTasksFetched = false
    /// In-memory cache of completed tasks for the current list
    private var completedTasksCache: [TaskItem] = []

    init(
        authService: GoogleAuthService = GoogleAuthService(),
        api: GoogleTasksAPI? = nil,
        userDefaults: UserDefaults = .standard,
        dueDateNotificationService: any DueDateNotificationServicing = DueDateNotificationService()
    ) {
        self.authService = authService
        self.api = api ?? GoogleTasksAPI(authService: authService)
        self.userDefaults = userDefaults
        self.dueDateNotificationService = dueDateNotificationService
        self.dueDateNotificationsEnabled = userDefaults.object(
            forKey: Constants.UserDefaults.dueDateNotificationsEnabledKey
        ) as? Bool ?? true
        self.isSignedIn = authService.isSignedIn
    }

    private var signInTask: Task<Void, Never>?

    func signIn() {
        signInTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await authService.signIn()
                self.isSignedIn = true
                await self.loadTaskLists()
            } catch {
                self.errorMessage = "Sign in failed: \(error.localizedDescription)"
            }
        }
    }

    func signOut() {
        authService.signOut()
        isSignedIn = false
        taskLists = []
        tasks = []
        selectedListId = nil
        completedTasksFetched = false
        completedTasksCache = []
        let dueDateNotificationService = dueDateNotificationService
        Task {
            await dueDateNotificationService.removeAllNotifications()
        }
    }

    func loadTaskLists() async {
        isLoading = true
        defer { isLoading = false }
        do {
            taskLists = try await api.listTaskLists()
            if selectedListId == nil, let first = taskLists.first {
                selectedListId = first.id
            }
            await refreshTasks()
        } catch {
            handleError(error)
        }
    }

    /// Loads active tasks (always fresh) and completed tasks (from cache if available).
    func loadTasks() async {
        guard let listId = selectedListId else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let activeTasks = try await api.listTasks(listId: listId, showCompleted: false, showHidden: false)
            if completedTasksFetched {
                tasks = activeTasks + completedTasksCache
            } else {
                let completed = try await api.listTasks(listId: listId, showCompleted: true, showHidden: true)
                    .filter { $0.isCompleted }
                completedTasksCache = completed
                completedTasksFetched = true
                tasks = activeTasks + completed
            }
            await syncDueDateNotificationsIfNeeded()
        } catch {
            handleError(error)
        }
    }

    /// Explicit refresh: fetches both active and completed tasks fresh from server.
    func refreshTasks() async {
        guard let listId = selectedListId else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let allTasks = try await api.listTasks(listId: listId)
            completedTasksCache = allTasks.filter { $0.isCompleted }
            completedTasksFetched = true
            tasks = allTasks
            await syncDueDateNotificationsIfNeeded()
        } catch {
            handleError(error)
        }
    }

    func addTask(title: String) async {
        guard let listId = selectedListId else { return }
        do {
            let task = try await api.createTask(listId: listId, title: title)
            tasks.insert(task, at: 0)
            await syncDueDateNotificationsIfNeeded()
        } catch {
            handleError(error)
        }
    }

    func addSubtask(title: String, parentId: String) async {
        guard let listId = selectedListId else { return }
        do {
            let task = try await api.createTask(listId: listId, title: title, parentId: parentId)
            // Insert after parent and its existing subtasks
            if let parentIndex = tasks.firstIndex(where: { $0.id == parentId }) {
                let insertIndex = tasks.indices
                    .suffix(from: parentIndex + 1)
                    .first(where: { tasks[$0].parent != parentId }) ?? tasks.endIndex
                tasks.insert(task, at: insertIndex)
            } else {
                tasks.append(task)
            }
            await syncDueDateNotificationsIfNeeded()
        } catch {
            handleError(error)
        }
    }

    func toggleTask(_ task: TaskItem) async {
        guard let listId = selectedListId else { return }
        var updated = task
        updated.isCompleted.toggle()
        
        // Optimistic update: immediately reflect in UI
        if let index = tasks.firstIndex(where: { $0.id == task.id }) {
            tasks[index] = updated
        }
        
        do {
            let result = try await api.updateTask(listId: listId, taskId: task.id, task: updated)
            // Update with server response
            if let index = tasks.firstIndex(where: { $0.id == result.id }) {
                tasks[index] = result
            }
            // Update completed tasks cache
            if result.isCompleted {
                if !completedTasksCache.contains(where: { $0.id == result.id }) {
                    completedTasksCache.append(result)
                }
            } else {
                completedTasksCache.removeAll { $0.id == result.id }
            }
            await syncDueDateNotificationsIfNeeded()
        } catch {
            // Revert optimistic update on failure
            if let index = tasks.firstIndex(where: { $0.id == task.id }) {
                tasks[index] = task
            }
            handleError(error)
        }
    }

    func updateTask(_ task: TaskItem) async {
        guard let listId = selectedListId else { return }
        do {
            let result = try await api.updateTask(listId: listId, taskId: task.id, task: task)
            if let index = tasks.firstIndex(where: { $0.id == task.id }) {
                tasks[index] = result
            }
            // Keep cache in sync
            if result.isCompleted {
                if let idx = completedTasksCache.firstIndex(where: { $0.id == result.id }) {
                    completedTasksCache[idx] = result
                }
            }
            await syncDueDateNotificationsIfNeeded()
        } catch {
            handleError(error)
        }
    }

    func deleteTask(_ task: TaskItem) async {
        guard let listId = selectedListId else { return }
        do {
            try await api.deleteTask(listId: listId, taskId: task.id)
            let childIDs = tasks.filter { $0.parent == task.id }.map(\.id)
            let removedIDs = [task.id] + childIDs
            tasks.removeAll { removedIDs.contains($0.id) }
            completedTasksCache.removeAll { removedIDs.contains($0.id) }
            await dueDateNotificationService.removeNotifications(
                forTaskIDs: removedIDs,
                inListID: listId
            )
        } catch {
            handleError(error)
        }
    }

    func moveTask(_ task: TaskItem, toActiveIndex destinationIndex: Int) async {
        guard let listId = selectedListId else { return }
        guard let moveContext = makeMoveContext(for: task.id, destinationIndex: destinationIndex) else {
            return
        }

        let originalTasks = tasks
        tasks = moveContext.reorderedTasks

        do {
            let movedTask = try await api.moveTask(
                listId: listId,
                taskId: task.id,
                previousId: moveContext.previousTaskID,
                parentId: task.parent
            )
            if let index = tasks.firstIndex(where: { $0.id == movedTask.id }) {
                tasks[index] = movedTask
            }
        } catch {
            tasks = originalTasks
            handleError(error)
        }
    }

    func selectList(_ listId: String) async {
        selectedListId = listId
        completedTasksFetched = false
        completedTasksCache = []
        await loadTasks()
    }

    private func handleError(_ error: Error) {
        if let apiError = error as? APIError {
            switch apiError {
            case .unauthorized:
                errorMessage = "Session expired. Please sign in again."
                signOut()
            case .networkError(let underlying):
                errorMessage = "Network error: \(underlying.localizedDescription)"
            case .serverError(let code, let message):
                errorMessage = "Server error \(code): \(message ?? "Unknown")"
            case .decodingError:
                errorMessage = "Failed to parse server response."
            }
        } else {
            errorMessage = error.localizedDescription
        }
    }

    private func applyDueDateNotificationsPreferenceChange(enabled: Bool) async {
        if enabled {
            await syncDueDateNotificationsIfNeeded()
        } else {
            await dueDateNotificationService.removeAllNotifications()
        }
    }

    private func syncDueDateNotificationsIfNeeded() async {
        guard dueDateNotificationsEnabled, let selectedList else { return }
        await dueDateNotificationService.syncNotifications(for: tasks, in: selectedList)
    }

    private func makeMoveContext(for taskID: String, destinationIndex: Int) -> TaskMoveContext? {
        let activeTasks = tasks.filter { !$0.isCompleted }
        guard let sourceIndex = activeTasks.firstIndex(where: { $0.id == taskID }) else { return nil }

        let clampedDestinationIndex = min(max(destinationIndex, 0), activeTasks.count)
        var reorderedActiveTasks = activeTasks
        reorderedActiveTasks.move(
            fromOffsets: IndexSet(integer: sourceIndex),
            toOffset: clampedDestinationIndex
        )

        guard reorderedActiveTasks.map(\.id) != activeTasks.map(\.id) else {
            return nil
        }

        guard let movedTaskIndex = reorderedActiveTasks.firstIndex(where: { $0.id == taskID }) else {
            return nil
        }

        let previousTaskID = movedTaskIndex > 0 ? reorderedActiveTasks[movedTaskIndex - 1].id : nil
        let completedTasks = tasks.filter { $0.isCompleted }

        return TaskMoveContext(
            reorderedTasks: reorderedActiveTasks + completedTasks,
            previousTaskID: previousTaskID
        )
    }
}

private struct TaskMoveContext {
    let reorderedTasks: [TaskItem]
    let previousTaskID: String?
}
