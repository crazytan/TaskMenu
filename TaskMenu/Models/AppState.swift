import Foundation
import Observation

func tasksSortedByGooglePosition(_ tasks: [TaskItem]) -> [TaskItem] {
    tasks.enumerated()
        .sorted { left, right in
            switch (left.element.position, right.element.position) {
            case let (leftPosition?, rightPosition?) where leftPosition != rightPosition:
                return leftPosition < rightPosition
            case (_?, nil):
                return true
            case (nil, _?):
                return false
            default:
                return left.offset < right.offset
            }
        }
        .map(\.element)
}

/// Recomputes local ordering after a drag-and-drop move, mirroring the Google
/// Tasks move API: the moved task lands under `newParentID` (top level when
/// nil) directly after sibling `previousTaskID` (first among siblings when
/// nil). Positions of the destination sibling group are rewritten so
/// `tasksSortedByGooglePosition(_:)` reflects the new order; the source
/// group's relative order is untouched. Returns nil when the move is invalid:
/// unknown task, moving under itself or its own subtree, or a `previousTaskID`
/// that is not a destination sibling.
func tasksReorderedAfterMove(
    _ tasks: [TaskItem],
    movedTaskID: String,
    newParentID: String?,
    previousTaskID: String?
) -> [TaskItem]? {
    guard let movedIndex = tasks.firstIndex(where: { $0.id == movedTaskID }),
          movedTaskID != newParentID,
          movedTaskID != previousTaskID
    else {
        return nil
    }

    if let newParentID {
        guard tasks.contains(where: { $0.id == newParentID }) else { return nil }
        // Walk the destination's ancestor chain to reject moves into the
        // moved task's own subtree (and bail out on malformed parent cycles).
        var visitedIDs: Set<String> = []
        var ancestorID: String? = newParentID
        while let currentID = ancestorID {
            guard currentID != movedTaskID, visitedIDs.insert(currentID).inserted else { return nil }
            ancestorID = tasks.first(where: { $0.id == currentID })?.parent
        }
    }

    var movedTask = tasks[movedIndex]
    movedTask.parent = newParentID

    var siblings = tasksSortedByGooglePosition(
        tasks.filter { $0.parent == newParentID && $0.id != movedTaskID }
    )
    let insertionIndex: Int
    if let previousTaskID {
        guard let previousIndex = siblings.firstIndex(where: { $0.id == previousTaskID }) else { return nil }
        insertionIndex = previousIndex + 1
    } else {
        insertionIndex = 0
    }
    siblings.insert(movedTask, at: insertionIndex)

    var updatedTasksByID: [String: TaskItem] = [:]
    for (index, sibling) in siblings.enumerated() {
        var updated = sibling
        updated.position = String(format: "%020d", index)
        updatedTasksByID[updated.id] = updated
    }
    return tasks.map { updatedTasksByID[$0.id] ?? $0 }
}

@MainActor
@Observable
final class AppState {
    var isSignedIn = false
    var isLoading = false
    var errorMessage: String?
    var googleAccountProfile: GoogleAccountProfile?

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
    var automaticUpdateChecksEnabled: Bool {
        didSet {
            userDefaults.set(
                automaticUpdateChecksEnabled,
                forKey: Constants.UserDefaults.automaticUpdateChecksEnabledKey
            )
        }
    }
    var lastUpdateCheckDate: Date? {
        didSet {
            if let lastUpdateCheckDate {
                userDefaults.set(lastUpdateCheckDate, forKey: Constants.UserDefaults.lastUpdateCheckDateKey)
            } else {
                userDefaults.removeObject(forKey: Constants.UserDefaults.lastUpdateCheckDateKey)
            }
        }
    }
    var latestAvailableUpdate: AppUpdateRelease?
    var isCheckingForUpdates = false
    var updateCheckErrorMessage: String?
    let currentAppVersion: String

    var selectedList: TaskList? {
        taskLists.first { $0.id == selectedListId }
    }

    var isShowingInitialTaskLoad: Bool {
        isSignedIn && !hasCompletedInitialTaskLoad && taskLists.isEmpty && tasks.isEmpty
    }

    /// Root-level tasks (no parent), ordered by Google's sibling position.
    var rootTasks: [TaskItem] {
        tasksSortedByGooglePosition(tasks.filter { $0.parent == nil })
    }

    /// Children of a given task, ordered by Google's sibling position.
    func subtasks(of taskID: String) -> [TaskItem] {
        tasksSortedByGooglePosition(tasks.filter { $0.parent == taskID })
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
        tasksSortedByGooglePosition(searchFilteredTasks.filter { $0.parent == nil })
    }

    /// Subtasks of a given task from the search-filtered set.
    func searchFilteredSubtasks(of taskID: String) -> [TaskItem] {
        tasksSortedByGooglePosition(searchFilteredTasks.filter { $0.parent == taskID })
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

    private let authService: GoogleAuthService
    private let api: any TasksAPIProtocol
    private let userDefaults: UserDefaults
    private let dueDateNotificationService: any DueDateNotificationServicing
    private let updateChecker: any UpdateChecking
    private let updateCheckInterval: TimeInterval = 24 * 60 * 60

    /// In-memory cache of visible tasks keyed by task list.
    private var taskCacheByListID: [String: [TaskItem]] = [:]
    /// Monotonic token used to ignore stale task-list responses.
    private var taskLoadRequestID = 0

    init(
        authService: GoogleAuthService = GoogleAuthService(),
        api: (any TasksAPIProtocol)? = nil,
        userDefaults: UserDefaults = .standard,
        dueDateNotificationService: any DueDateNotificationServicing = DueDateNotificationService(),
        updateChecker: any UpdateChecking = GitHubUpdateChecker(),
        currentAppVersion: String = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0"
    ) {
        self.authService = authService
        self.api = api ?? GoogleTasksAPI(authService: authService)
        self.userDefaults = userDefaults
        self.dueDateNotificationService = dueDateNotificationService
        self.updateChecker = updateChecker
        self.currentAppVersion = currentAppVersion
        self.dueDateNotificationsEnabled = userDefaults.object(
            forKey: Constants.UserDefaults.dueDateNotificationsEnabledKey
        ) as? Bool ?? true
        self.automaticUpdateChecksEnabled = userDefaults.object(
            forKey: Constants.UserDefaults.automaticUpdateChecksEnabledKey
        ) as? Bool ?? true
        self.lastUpdateCheckDate = userDefaults.object(
            forKey: Constants.UserDefaults.lastUpdateCheckDateKey
        ) as? Date
        self.isSignedIn = authService.isSignedIn
        self.googleAccountProfile = authService.accountProfile
    }

    private var signInTask: Task<Void, Never>?

    func signIn() {
        guard signInTask == nil else { return }

        errorMessage = nil
        isLoading = true
        signInTask = Task { [weak self] in
            guard let self else { return }
            defer {
                self.isLoading = false
                self.signInTask = nil
            }
            do {
                try await authService.signIn()
                self.isSignedIn = true
                self.googleAccountProfile = authService.accountProfile
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

    func refreshGoogleAccountProfileIfNeeded() async {
        guard isSignedIn, googleAccountProfile == nil else { return }
        await authService.refreshAccountProfile()
        googleAccountProfile = authService.accountProfile
    }

    func checkForUpdatesManually() async {
        _ = await performUpdateCheck()
    }

    func checkForUpdatesIfNeeded() async -> AppUpdateRelease? {
        guard automaticUpdateChecksEnabled, isAutomaticUpdateCheckDue else { return nil }
        let release = await performUpdateCheck()
        guard let release, release.version != lastAlertedUpdateVersion else { return nil }
        return release
    }

    func markUpdateAlertShown(for release: AppUpdateRelease) {
        userDefaults.set(release.version, forKey: Constants.UserDefaults.lastAlertedUpdateVersionKey)
    }

    private func clearSignedInState() {
        isSignedIn = false
        googleAccountProfile = nil
        taskLists = []
        tasks = []
        selectedListId = nil
        hasCompletedInitialTaskLoad = false
        taskCacheByListID = [:]
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

    @discardableResult
    func addTask(title: String) async -> TaskItem? {
        guard let listId = selectedListId else { return nil }
        do {
            let task = try await api.createTask(listId: listId, title: title)
            tasks.insert(task, at: 0)
            updateVisibleTaskCacheForSelectedList()
            await syncDueDateNotificationsIfNeeded()
            return task
        } catch {
            handleError(error)
            return nil
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

        // Completing a parent also completes its open subtasks, matching Google Tasks.
        // Un-completing a parent does not cascade.
        let cascadedChildren = updated.isCompleted
            ? subtasks(of: task.id).filter { !$0.isCompleted }
            : []

        // Optimistic update: immediately reflect in UI
        if let index = tasks.firstIndex(where: { $0.id == task.id }) {
            tasks[index] = updated
        }
        var completedChildren: [TaskItem] = []
        for child in cascadedChildren {
            var completedChild = child
            completedChild.isCompleted = true
            if let index = tasks.firstIndex(where: { $0.id == child.id }) {
                tasks[index] = completedChild
            }
            completedChildren.append(completedChild)
        }
        updateVisibleTaskCacheForSelectedList()

        do {
            let result = try await api.updateTask(listId: listId, taskId: task.id, task: updated)
            // Update with server response
            if let index = tasks.firstIndex(where: { $0.id == result.id }) {
                tasks[index] = result
            }
            updateVisibleTaskCacheForSelectedList()
        } catch {
            // Revert optimistic updates on failure and skip the cascaded child updates
            if let index = tasks.firstIndex(where: { $0.id == task.id }) {
                tasks[index] = task
            }
            for child in cascadedChildren {
                if let index = tasks.firstIndex(where: { $0.id == child.id }) {
                    tasks[index] = child
                }
            }
            updateVisibleTaskCacheForSelectedList()
            handleError(error)
            return
        }

        for completedChild in completedChildren {
            do {
                let result = try await api.updateTask(listId: listId, taskId: completedChild.id, task: completedChild)
                if let index = tasks.firstIndex(where: { $0.id == result.id }) {
                    tasks[index] = result
                }
                updateVisibleTaskCacheForSelectedList()
            } catch {
                // Leave the optimistic completion in place; the next refresh reconciles
                handleError(error)
            }
        }
        await syncDueDateNotificationsIfNeeded()
    }

    func updateTask(_ task: TaskItem) async {
        guard let listId = selectedListId else { return }
        do {
            let result = try await api.updateTask(listId: listId, taskId: task.id, task: task)
            if let index = tasks.firstIndex(where: { $0.id == task.id }) {
                tasks[index] = result
            }
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
            updateVisibleTaskCacheForSelectedList()
            await dueDateNotificationService.removeNotifications(
                forTaskIDs: removedIDs,
                inListID: listId
            )
        } catch {
            handleError(error)
        }
    }

    /// Moves a task under `newParentID` (top level when nil), directly after
    /// sibling `previousTaskID` (first among siblings when nil). Applies the
    /// reorder optimistically and rolls back if the API move fails.
    func moveTask(_ task: TaskItem, toParent newParentID: String?, after previousTaskID: String?) async {
        guard let listId = selectedListId,
              let reordered = tasksReorderedAfterMove(
                tasks,
                movedTaskID: task.id,
                newParentID: newParentID,
                previousTaskID: previousTaskID
              )
        else {
            return
        }

        // Skip drops that leave the task exactly where it was.
        let currentParentID = tasks.first(where: { $0.id == task.id })?.parent
        if currentParentID == newParentID {
            let siblingIDs = { (source: [TaskItem]) in
                tasksSortedByGooglePosition(source.filter { $0.parent == newParentID }).map(\.id)
            }
            if siblingIDs(tasks) == siblingIDs(reordered) { return }
        }

        let snapshot = tasks
        tasks = reordered
        updateVisibleTaskCacheForSelectedList()

        do {
            // The optimistic order already matches the server outcome; exact
            // server positions reconcile on the next refresh.
            _ = try await api.moveTask(
                listId: listId,
                taskId: task.id,
                parentId: newParentID,
                previousTaskId: previousTaskID
            )
        } catch {
            taskCacheByListID[listId] = snapshot
            if selectedListId == listId {
                tasks = snapshot
            }
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

    private var isAutomaticUpdateCheckDue: Bool {
        guard let lastUpdateCheckDate else { return true }
        return Date().timeIntervalSince(lastUpdateCheckDate) >= updateCheckInterval
    }

    private var lastAlertedUpdateVersion: String? {
        userDefaults.string(forKey: Constants.UserDefaults.lastAlertedUpdateVersionKey)
    }

    private func performUpdateCheck() async -> AppUpdateRelease? {
        guard !isCheckingForUpdates else { return latestAvailableUpdate }

        isCheckingForUpdates = true
        defer { isCheckingForUpdates = false }

        do {
            let release = try await updateChecker.latestUpdate(currentVersion: currentAppVersion)
            lastUpdateCheckDate = Date()
            latestAvailableUpdate = release
            updateCheckErrorMessage = nil
            return release
        } catch {
            lastUpdateCheckDate = Date()
            updateCheckErrorMessage = messageForUpdateCheckError(error)
            return nil
        }
    }

    private func messageForUpdateCheckError(_ error: Error) -> String {
        if let localizedError = error as? LocalizedError,
           let description = localizedError.errorDescription {
            return description
        }

        return error.localizedDescription
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

    private func cacheFetchedTasks(_ fetchedTasks: [TaskItem], for listId: String) {
        taskCacheByListID[listId] = fetchedTasks
    }

    private func updateVisibleTaskCacheForSelectedList() {
        guard let listId = selectedListId else { return }
        taskCacheByListID[listId] = tasks
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
}
