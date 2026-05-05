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
    var hasCompletedInitialTaskLoad = false
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
    var experimentalFullWindowLiquidGlassEnabled: Bool {
        didSet {
            userDefaults.set(
                experimentalFullWindowLiquidGlassEnabled,
                forKey: Constants.UserDefaults.experimentalFullWindowLiquidGlassEnabledKey
            )
        }
    }

    var selectedList: TaskList? {
        taskLists.first { $0.id == selectedListId }
    }

    var isShowingInitialTaskLoad: Bool {
        isSignedIn && !hasCompletedInitialTaskLoad && taskLists.isEmpty && tasks.isEmpty
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
    private let api: any TasksAPIProtocol
    private let userDefaults: UserDefaults
    private let dueDateNotificationService: any DueDateNotificationServicing

    /// In-memory cache of visible tasks keyed by task list.
    private var taskCacheByListID: [String: [TaskItem]] = [:]
    /// Task lists whose completed tasks have been fetched at least once.
    private var completedTasksFetchedListIDs: Set<String> = []
    /// In-memory cache of completed tasks keyed by task list.
    private var completedTasksCacheByListID: [String: [TaskItem]] = [:]
    /// Monotonic token used to ignore stale task-list responses.
    private var taskLoadRequestID = 0

    init(
        authService: GoogleAuthService = GoogleAuthService(),
        api: (any TasksAPIProtocol)? = nil,
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
        self.experimentalFullWindowLiquidGlassEnabled = userDefaults.object(
            forKey: Constants.UserDefaults.experimentalFullWindowLiquidGlassEnabledKey
        ) as? Bool ?? false
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
        clearSignedInState()
    }

    func disconnectGoogleAccount() async {
        await authService.disconnect()
        clearSignedInState()
    }

    private func clearSignedInState() {
        isSignedIn = false
        taskLists = []
        tasks = []
        selectedListId = nil
        hasCompletedInitialTaskLoad = false
        taskCacheByListID = [:]
        completedTasksFetchedListIDs = []
        completedTasksCacheByListID = [:]
        taskLoadRequestID += 1
        let dueDateNotificationService = dueDateNotificationService
        Task {
            await dueDateNotificationService.removeAllNotifications()
        }
    }

    func bootstrapSignedInState() async {
        guard isSignedIn, taskLists.isEmpty, selectedListId == nil, !isLoading else { return }
        await loadTaskLists()
    }

    func loadTaskLists() async {
        isLoading = true
        defer {
            isLoading = false
            hasCompletedInitialTaskLoad = true
        }
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

    func refreshForMenuPresentation() async {
        guard isSignedIn, !isLoading else { return }

        if taskLists.isEmpty || selectedListId == nil {
            await loadTaskLists()
        } else {
            await refreshTasks()
        }
    }

    /// Loads active tasks (always fresh) and completed tasks (from cache if available).
    func loadTasks() async {
        guard let listId = selectedListId else { return }
        showCachedTasks(for: listId)

        let requestID = beginTaskLoad(for: listId)
        defer { finishTaskLoad(requestID, for: listId) }
        do {
            let activeTasks = try await api.listTasks(listId: listId, showCompleted: false, showHidden: false)
            let loadedTasks: [TaskItem]
            if completedTasksFetchedListIDs.contains(listId) {
                loadedTasks = activeTasks + (completedTasksCacheByListID[listId] ?? [])
            } else {
                let completed = try await api.listTasks(listId: listId, showCompleted: true, showHidden: true)
                    .filter { $0.isCompleted }
                loadedTasks = activeTasks + completed
            }
            cacheFetchedTasks(loadedTasks, for: listId)
            await applyLoadedTasks(loadedTasks, for: listId, requestID: requestID)
        } catch {
            handleCurrentTaskLoadError(error, for: listId, requestID: requestID)
        }
    }

    /// Explicit refresh: fetches both active and completed tasks fresh from server.
    func refreshTasks() async {
        guard let listId = selectedListId else { return }
        let requestID = beginTaskLoad(for: listId)
        defer { finishTaskLoad(requestID, for: listId) }
        do {
            let allTasks = try await api.listTasks(listId: listId)
            cacheFetchedTasks(allTasks, for: listId)
            await applyLoadedTasks(allTasks, for: listId, requestID: requestID)
        } catch {
            handleCurrentTaskLoadError(error, for: listId, requestID: requestID)
        }
    }

    func addTask(title: String) async {
        guard let listId = selectedListId else { return }
        do {
            let task = try await api.createTask(listId: listId, title: title)
            tasks.insert(task, at: 0)
            updateVisibleTaskCacheForSelectedList()
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
            updateVisibleTaskCacheForSelectedList()
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
            updateVisibleTaskCacheForSelectedList()
        }
        
        do {
            let result = try await api.updateTask(listId: listId, taskId: task.id, task: updated)
            // Update with server response
            if let index = tasks.firstIndex(where: { $0.id == result.id }) {
                tasks[index] = result
            }
            updateCompletedTaskCache(with: result, for: listId)
            updateVisibleTaskCacheForSelectedList()
            await syncDueDateNotificationsIfNeeded()
        } catch {
            // Revert optimistic update on failure
            if let index = tasks.firstIndex(where: { $0.id == task.id }) {
                tasks[index] = task
                updateVisibleTaskCacheForSelectedList()
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
            updateCompletedTaskCache(with: result, for: listId)
            updateVisibleTaskCacheForSelectedList()
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
            taskCacheByListID[listId]?.removeAll { removedIDs.contains($0.id) }
            completedTasksCacheByListID[listId]?.removeAll { removedIDs.contains($0.id) }
            updateVisibleTaskCacheForSelectedList()
            await dueDateNotificationService.removeNotifications(
                forTaskIDs: removedIDs,
                inListID: listId
            )
        } catch {
            handleError(error)
        }
    }

    func moveTask(_ task: TaskItem, toActiveIndex destinationIndex: Int) async {
        await moveTask(task, toSiblingIndex: destinationIndex)
    }

    func moveTask(_ task: TaskItem, toSiblingIndex destinationIndex: Int) async {
        guard let listId = selectedListId else { return }
        guard let moveContext = makeMoveContext(for: task.id, destinationIndex: destinationIndex) else {
            return
        }

        let originalTasks = tasks
        tasks = moveContext.reorderedTasks
        updateVisibleTaskCacheForSelectedList()

        do {
            let movedTask = try await api.moveTask(
                listId: listId,
                taskId: task.id,
                previousId: moveContext.previousTaskID,
                parentId: task.parent
            )
            if let index = tasks.firstIndex(where: { $0.id == movedTask.id }) {
                tasks[index] = movedTask
                updateVisibleTaskCacheForSelectedList()
            }
        } catch {
            tasks = originalTasks
            updateVisibleTaskCacheForSelectedList()
            handleError(error)
        }
    }

    func selectList(_ listId: String) async {
        selectedListId = listId
        if let cachedTasks = taskCacheByListID[listId] {
            tasks = cachedTasks
        } else {
            tasks = []
        }
        await refreshTasks()
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

    private func beginTaskLoad(for listId: String) -> Int {
        taskLoadRequestID += 1
        isLoading = true
        return taskLoadRequestID
    }

    private func finishTaskLoad(_ requestID: Int, for listId: String) {
        guard isCurrentTaskLoad(requestID, for: listId) else { return }
        isLoading = false
    }

    private func isCurrentTaskLoad(_ requestID: Int, for listId: String) -> Bool {
        selectedListId == listId && taskLoadRequestID == requestID
    }

    private func showCachedTasks(for listId: String) {
        guard selectedListId == listId, let cachedTasks = taskCacheByListID[listId] else { return }
        tasks = cachedTasks
    }

    private func cacheFetchedTasks(_ fetchedTasks: [TaskItem], for listId: String) {
        taskCacheByListID[listId] = fetchedTasks
        completedTasksCacheByListID[listId] = fetchedTasks.filter { $0.isCompleted }
        completedTasksFetchedListIDs.insert(listId)
    }

    private func updateVisibleTaskCacheForSelectedList() {
        guard let listId = selectedListId else { return }
        taskCacheByListID[listId] = tasks
        if completedTasksFetchedListIDs.contains(listId) {
            completedTasksCacheByListID[listId] = tasks.filter { $0.isCompleted }
        }
    }

    private func updateCompletedTaskCache(with task: TaskItem, for listId: String) {
        if task.isCompleted {
            var cachedCompletedTasks = completedTasksCacheByListID[listId] ?? []
            if let index = cachedCompletedTasks.firstIndex(where: { $0.id == task.id }) {
                cachedCompletedTasks[index] = task
            } else {
                cachedCompletedTasks.append(task)
            }
            completedTasksCacheByListID[listId] = cachedCompletedTasks
            completedTasksFetchedListIDs.insert(listId)
        } else {
            completedTasksCacheByListID[listId]?.removeAll { $0.id == task.id }
        }
    }

    private func applyLoadedTasks(_ loadedTasks: [TaskItem], for listId: String, requestID: Int) async {
        guard isCurrentTaskLoad(requestID, for: listId) else { return }
        tasks = loadedTasks
        await syncDueDateNotificationsIfNeeded()
    }

    private func handleCurrentTaskLoadError(_ error: Error, for listId: String, requestID: Int) {
        guard isCurrentTaskLoad(requestID, for: listId) else { return }
        handleError(error)
    }

    private func makeMoveContext(for taskID: String, destinationIndex: Int) -> TaskMoveContext? {
        guard let movedTask = tasks.first(where: { $0.id == taskID && !$0.isCompleted }) else {
            return nil
        }

        let activeSiblings = tasks.filter { !$0.isCompleted && $0.parent == movedTask.parent }
        guard let sourceIndex = activeSiblings.firstIndex(where: { $0.id == taskID }) else { return nil }

        let clampedDestinationIndex = min(max(destinationIndex, 0), activeSiblings.count)
        var reorderedActiveSiblings = activeSiblings
        reorderedActiveSiblings.move(
            fromOffsets: IndexSet(integer: sourceIndex),
            toOffset: clampedDestinationIndex
        )

        guard reorderedActiveSiblings.map(\.id) != activeSiblings.map(\.id) else {
            return nil
        }

        guard let movedTaskIndex = reorderedActiveSiblings.firstIndex(where: { $0.id == taskID }) else {
            return nil
        }

        let previousTaskID = movedTaskIndex > 0 ? reorderedActiveSiblings[movedTaskIndex - 1].id : nil
        var reorderedIterator = reorderedActiveSiblings.makeIterator()
        let reorderedTasks = tasks.map { task in
            if !task.isCompleted && task.parent == movedTask.parent {
                return reorderedIterator.next() ?? task
            }
            return task
        }

        return TaskMoveContext(
            reorderedTasks: reorderedTasks,
            previousTaskID: previousTaskID
        )
    }
}

private struct TaskMoveContext {
    let reorderedTasks: [TaskItem]
    let previousTaskID: String?
}
