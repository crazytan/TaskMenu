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
            // Enqueue synchronously so rapid flips run in flip order; each
            // operation re-reads the preference when it executes, so the
            // final notification state always matches the last flip.
            enqueueNotificationWork { [weak self] in
                guard let self else { return }
                if self.dueDateNotificationsEnabled {
                    await self.performDueDateNotificationSync()
                } else {
                    await self.dueDateNotificationService.removeAllNotifications()
                }
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

        // Build the visible set: direct matches + parents of matching subtasks
        let directMatchIDs = directSearchMatchIDs
        var visibleIDs = directMatchIDs
        for task in tasks where directMatchIDs.contains(task.id) {
            if let parentID = task.parent {
                visibleIDs.insert(parentID)
            }
        }

        return tasks.filter { visibleIDs.contains($0.id) }
    }

    /// Number of tasks that directly match the current search text. Parents
    /// shown only as context for a matching subtask are not counted.
    var searchMatchCount: Int {
        guard isSearching else { return 0 }
        return directSearchMatchIDs.count
    }

    /// IDs of tasks whose title or notes match the current search text.
    private var directSearchMatchIDs: Set<String> {
        let query = searchText.lowercased()
        return Set(tasks.filter { taskMatchesQuery($0, query: query) }.map(\.id))
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
    /// Read by the app delegate's automatic-check loop to pace re-checks.
    let updateCheckInterval: TimeInterval = 24 * 60 * 60

    /// In-memory cache of visible tasks keyed by task list.
    private var taskCacheByListID: [String: [TaskItem]] = [:]
    /// Monotonic token used to ignore stale task-list responses.
    private var taskLoadRequestID = 0
    /// Monotonic generation bumped by every committed local task change and
    /// by sign-out, so an in-flight load whose server snapshot predates the
    /// change discards it instead of clobbering newer state.
    private var taskStateGeneration = 0
    /// Tail of the FIFO chain that serializes notification-service work.
    private var notificationWorkTask: Task<Void, Never>?

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
        let revocationSucceeded = await authService.disconnect()
        clearSignedInState()
        if !revocationSucceeded {
            errorMessage = "Signed out, but Google revocation failed. "
                + "Review access at myaccount.google.com/permissions."
        }
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
        taskStateGeneration += 1
        // Enqueue on the notification chain so the removal deterministically
        // runs after any sync already in flight; post-sign-out continuations
        // re-check `isSignedIn` before enqueueing new syncs.
        let dueDateNotificationService = dueDateNotificationService
        enqueueNotificationWork {
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
            if isSignedIn {
                hasCompletedInitialTaskLoad = true
            }
        }
        do {
            let lists = try await api.listTaskLists()
            // Discard the response when the user signed out during the fetch
            // so stale lists cannot repopulate signed-out state.
            guard isSignedIn else { return }
            taskLists = lists
            if selectedListId == nil, let first = taskLists.first {
                selectedListId = first.id
            }
            await refreshTasks()
        } catch {
            guard isSignedIn else { return }
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
        let token = beginTaskLoad(for: listId)
        defer { finishTaskLoad(token) }
        do {
            let allTasks = try await api.listTasks(listId: listId)
            // A mutation or sign-out during the fetch makes this snapshot
            // stale for the cache as well as the visible list; drop it.
            guard token.generation == taskStateGeneration else { return }
            cacheFetchedTasks(allTasks, for: listId)
            await applyLoadedTasks(allTasks, for: token)
        } catch {
            handleCurrentTaskLoadError(error, for: token)
        }
    }

    @discardableResult
    func addTask(title: String) async -> TaskItem? {
        guard let listId = selectedListId else { return nil }
        do {
            let task = try await api.createTask(listId: listId, title: title)
            guard isSignedIn else { return nil }
            commitTaskChange(to: listId) { tasks in
                tasks.insert(task, at: 0)
            }
            await syncDueDateNotificationsIfNeeded()
            return task
        } catch {
            guard isSignedIn else { return nil }
            handleError(error)
            return nil
        }
    }

    func addSubtask(title: String, parentId: String) async {
        guard let listId = selectedListId else { return }
        do {
            let task = try await api.createTask(listId: listId, title: title, parentId: parentId)
            guard isSignedIn else { return }
            commitTaskChange(to: listId) { tasks in
                // Insert after parent and its existing subtasks
                if let parentIndex = tasks.firstIndex(where: { $0.id == parentId }) {
                    let insertIndex = tasks.indices
                        .suffix(from: parentIndex + 1)
                        .first(where: { tasks[$0].parent != parentId }) ?? tasks.endIndex
                    tasks.insert(task, at: insertIndex)
                } else {
                    tasks.append(task)
                }
            }
            await syncDueDateNotificationsIfNeeded()
        } catch {
            guard isSignedIn else { return }
            handleError(error)
        }
    }

    func toggleTask(_ task: TaskItem) async {
        guard let listId = selectedListId else { return }
        // Toggle from the live value so a rapid second click on a stale row
        // snapshot reverses the first toggle instead of repeating it.
        let original = tasks.first(where: { $0.id == task.id }) ?? task
        var updated = original
        updated.isCompleted.toggle()

        // Completing a parent also completes its open subtasks, matching Google Tasks.
        // Un-completing a parent does not cascade.
        let cascadedChildren = updated.isCompleted
            ? subtasks(of: original.id).filter { !$0.isCompleted }
            : []
        let completedChildren = cascadedChildren.map { child in
            var completedChild = child
            completedChild.isCompleted = true
            return completedChild
        }

        // Optimistic update: immediately reflect in UI
        commitTaskChange(to: listId) { tasks in
            for optimisticTask in [updated] + completedChildren {
                if let index = tasks.firstIndex(where: { $0.id == optimisticTask.id }) {
                    tasks[index] = optimisticTask
                }
            }
        }

        do {
            let result = try await api.updateTask(listId: listId, taskId: original.id, task: updated)
            guard isSignedIn else { return }
            // Update with server response
            commitTaskChange(to: listId) { tasks in
                if let index = tasks.firstIndex(where: { $0.id == result.id }) {
                    tasks[index] = result
                }
            }
        } catch {
            guard isSignedIn else { return }
            // Revert the optimistic completions on failure and skip the
            // cascaded child updates. Only the status field is rewound, and
            // only while it still holds the optimistic value, so edits
            // committed while the request was in flight survive the revert.
            commitTaskChange(to: listId) { tasks in
                revertOptimisticCompletion(from: updated, to: original, in: &tasks)
                for (child, completedChild) in zip(cascadedChildren, completedChildren) {
                    revertOptimisticCompletion(from: completedChild, to: child, in: &tasks)
                }
            }
            handleError(error)
            return
        }

        for completedChild in completedChildren {
            do {
                let result = try await api.updateTask(listId: listId, taskId: completedChild.id, task: completedChild)
                guard isSignedIn else { return }
                commitTaskChange(to: listId) { tasks in
                    if let index = tasks.firstIndex(where: { $0.id == result.id }) {
                        tasks[index] = result
                    }
                }
            } catch {
                guard isSignedIn else { return }
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
            guard isSignedIn else { return }
            commitTaskChange(to: listId) { tasks in
                if let index = tasks.firstIndex(where: { $0.id == task.id }) {
                    tasks[index] = result
                }
            }
            await syncDueDateNotificationsIfNeeded()
        } catch {
            guard isSignedIn else { return }
            handleError(error)
        }
    }

    func deleteTask(_ task: TaskItem) async {
        guard let listId = selectedListId else { return }
        do {
            try await api.deleteTask(listId: listId, taskId: task.id)
            guard isSignedIn else { return }
            var removedIDs: [String] = []
            commitTaskChange(to: listId) { tasks in
                removedIDs = taskIDsIncludingDescendants(of: task.id, in: tasks)
                tasks.removeAll { removedIDs.contains($0.id) }
            }
            let removedTaskIDs = removedIDs
            let dueDateNotificationService = dueDateNotificationService
            await enqueueNotificationWork {
                await dueDateNotificationService.removeNotifications(
                    forTaskIDs: removedTaskIDs,
                    inListID: listId
                )
            }.value
        } catch {
            guard isSignedIn else { return }
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

        // Remember where the task came from so a failure can undo just the move.
        let originalSiblings = tasksSortedByGooglePosition(tasks.filter { $0.parent == currentParentID })
        let originalIndex = originalSiblings.firstIndex { $0.id == task.id }
        let originalPreviousTaskID = originalIndex.flatMap { index in
            index > 0 ? originalSiblings[index - 1].id : nil
        }

        commitTaskChange(to: listId) { tasks in
            tasks = reordered
        }

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
            guard isSignedIn else { return }
            // Undo only the move against the current state, and only while
            // the task still sits under the parent the optimistic move gave
            // it, so changes committed during the request are preserved.
            commitTaskChange(to: listId) { tasks in
                guard tasks.first(where: { $0.id == task.id })?.parent == newParentID,
                      let reverted = tasksReorderedAfterMove(
                        tasks,
                        movedTaskID: task.id,
                        newParentID: currentParentID,
                        previousTaskID: originalPreviousTaskID
                      )
                else { return }
                tasks = reverted
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

    /// Chains notification-service work in FIFO enqueue order. The service is
    /// internally serial too, but chaining here makes the enqueue order (and
    /// therefore the final notification state) deterministic when a sign-out
    /// or preference flip races an in-flight sync. Operations should re-check
    /// state when they execute, not when they are enqueued.
    @discardableResult
    private func enqueueNotificationWork(
        _ operation: @escaping @MainActor () async -> Void
    ) -> Task<Void, Never> {
        let previousWork = notificationWorkTask
        let nextWork = Task {
            await previousWork?.value
            await operation()
        }
        notificationWorkTask = nextWork
        return nextWork
    }

    private func syncDueDateNotificationsIfNeeded() async {
        await enqueueNotificationWork { [weak self] in
            await self?.performDueDateNotificationSync()
        }.value
    }

    /// One guarded sync against current state. Only call from the
    /// notification work chain so it cannot interleave with a sign-out's
    /// removeAll or a preference flip's removal.
    private func performDueDateNotificationSync() async {
        guard isSignedIn, dueDateNotificationsEnabled, let selectedList else { return }
        await dueDateNotificationService.syncNotifications(for: tasks, in: selectedList)
    }

    /// Applies a committed local change to the list captured before a
    /// request's await: the live tasks array when that list is still
    /// selected, otherwise that list's cache, so a list switch during the
    /// request cannot leak the change into the wrong list. Bumps the
    /// task-state generation so in-flight loads discard stale snapshots.
    private func commitTaskChange(to listId: String, _ apply: (inout [TaskItem]) -> Void) {
        taskStateGeneration += 1
        if selectedListId == listId {
            apply(&tasks)
            taskCacheByListID[listId] = tasks
        } else {
            var cachedTasks = taskCacheByListID[listId] ?? []
            apply(&cachedTasks)
            taskCacheByListID[listId] = cachedTasks
        }
    }

    /// Restores the pre-toggle completion status for one task, but only while
    /// the live value still carries the optimistic status, so concurrent
    /// edits committed during the failed request are not clobbered.
    private func revertOptimisticCompletion(
        from optimistic: TaskItem,
        to original: TaskItem,
        in tasks: inout [TaskItem]
    ) {
        guard let index = tasks.firstIndex(where: { $0.id == original.id }),
              tasks[index].status == optimistic.status
        else { return }
        tasks[index].status = original.status
    }

    /// The task's id plus the ids of all of its descendants, walking the
    /// parent relation transitively so nested subtasks are included.
    private func taskIDsIncludingDescendants(of taskID: String, in tasks: [TaskItem]) -> [String] {
        var collectedIDs = [taskID]
        var collectedIDSet: Set<String> = [taskID]
        var frontierIDs: Set<String> = [taskID]
        while !frontierIDs.isEmpty {
            let childIDs = tasks
                .filter { task in
                    guard let parent = task.parent else { return false }
                    return frontierIDs.contains(parent) && !collectedIDSet.contains(task.id)
                }
                .map(\.id)
            collectedIDs.append(contentsOf: childIDs)
            collectedIDSet.formUnion(childIDs)
            frontierIDs = Set(childIDs)
        }
        return collectedIDs
    }

    /// Identifies one in-flight task load: the list it was started for, the
    /// load request it belongs to, and the task-state generation it saw.
    private struct TaskLoadToken {
        let listID: String
        let requestID: Int
        let generation: Int
    }

    private func beginTaskLoad(for listId: String) -> TaskLoadToken {
        taskLoadRequestID += 1
        isLoading = true
        return TaskLoadToken(
            listID: listId,
            requestID: taskLoadRequestID,
            generation: taskStateGeneration
        )
    }

    private func finishTaskLoad(_ token: TaskLoadToken) {
        // Only the newest load for the visible list owns the loading
        // indicator; a mutation bumping the generation must not leave it on.
        guard selectedListId == token.listID, taskLoadRequestID == token.requestID else { return }
        isLoading = false
    }

    private func isCurrentTaskLoad(_ token: TaskLoadToken) -> Bool {
        selectedListId == token.listID
            && taskLoadRequestID == token.requestID
            && taskStateGeneration == token.generation
    }

    private func cacheFetchedTasks(_ fetchedTasks: [TaskItem], for listId: String) {
        taskCacheByListID[listId] = fetchedTasks
    }

    private func applyLoadedTasks(_ loadedTasks: [TaskItem], for token: TaskLoadToken) async {
        guard isCurrentTaskLoad(token) else { return }
        tasks = loadedTasks
        await syncDueDateNotificationsIfNeeded()
    }

    private func handleCurrentTaskLoadError(_ error: Error, for token: TaskLoadToken) {
        guard isCurrentTaskLoad(token) else { return }
        handleError(error)
    }
}
