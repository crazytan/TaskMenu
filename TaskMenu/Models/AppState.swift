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

/// Adds a task the Tasks API just created to the local list where the API
/// stores a task inserted without `previous`: first among its siblings, at
/// the top level or under `task.parent`. The sibling group's positions are
/// rewritten the way `tasksReorderedAfterMove(_:movedTaskID:newParentID:previousTaskID:)`
/// does after a move, so the order does not hinge on comparing the created
/// task's server position against stale sibling positions the server may
/// have renumbered since. A task whose parent is missing from the list is
/// appended as is.
func tasksWithCreatedTask(_ task: TaskItem, in tasks: [TaskItem]) -> [TaskItem] {
    var updatedTasks = tasks.filter { $0.id != task.id }

    if let parentID = task.parent {
        guard let parentIndex = updatedTasks.firstIndex(where: { $0.id == parentID }) else {
            updatedTasks.append(task)
            return updatedTasks
        }
        // Keep the array grouped as the server lists it: parent, then its
        // subtasks. Sorting is by position, so this only decides tie-breaks.
        let insertIndex = updatedTasks.indices
            .suffix(from: parentIndex + 1)
            .first(where: { updatedTasks[$0].parent != parentID }) ?? updatedTasks.endIndex
        updatedTasks.insert(task, at: insertIndex)
    } else {
        updatedTasks.insert(task, at: 0)
    }

    return tasksReorderedAfterMove(
        updatedTasks,
        movedTaskID: task.id,
        newParentID: task.parent,
        previousTaskID: nil
    ) ?? updatedTasks
}

@MainActor
@Observable
final class AppState {
    var isSignedIn = false
    var isLoading = false
    var errorMessage: String?
    var googleAccountProfile: GoogleAccountProfile?
    /// Whether the app is running on sample data instead of a Google account.
    /// `authService` is untouched in demo mode, so `isSignedIn` is true here
    /// without any token existing.
    private(set) var isDemoMode = false

    var taskLists: [TaskList] = []
    var selectedListId: String?
    var tasks: [TaskItem] = []
    var hasCompletedInitialTaskLoad = false
    var collapsedTaskIDs: Set<String> = []
    var searchText: String = ""
    /// App-wide root-task ordering; subtasks and the completed section always
    /// keep Google order. Persisted like the notification preference and kept
    /// across sign-out, disconnect, and demo exit.
    var taskSortOrder: TaskSortOrder {
        didSet {
            userDefaults.set(taskSortOrder.rawValue, forKey: Constants.UserDefaults.taskSortOrderKey)
        }
    }

    /// Drag-and-drop reordering only makes sense while the list shows Google's
    /// own order; under any other sort the drop index would not map to a position.
    var canReorderTasks: Bool {
        taskSortOrder == .myOrder
    }

    /// Menu-bar counter preference. Persisted; Off by default.
    var menuBarCounterMode: MenuBarCounterMode {
        didSet {
            userDefaults.set(menuBarCounterMode.rawValue, forKey: Constants.UserDefaults.menuBarCounterModeKey)
            guard menuBarCounterMode != oldValue else { return }
            if menuBarCounterMode == .off {
                stopMenuBarCountRefresh()
            } else if oldValue == .off {
                // Other lists have not been fetched while the counter was off.
                scheduleMenuBarCountRefresh()
            }
            // .openTasks <-> .dueToday needs no fetch; the count is recomputed from cache.
        }
    }

    /// Account-wide count for the current `menuBarCounterMode`: 0 when signed
    /// out or Off. Reads the live `tasks` for the selected list and
    /// `taskCacheByListID` for every other known list, so local mutations
    /// committed through `commitTaskChange` show up immediately.
    var menuBarPendingCount: Int {
        pendingTaskCount(for: menuBarCounterMode)
    }

    /// Same as `menuBarPendingCount` for an explicit mode (used by tests and by
    /// the accessor above). Only lists present in `taskLists` (plus the selected
    /// list) contribute, so a cache entry for a list that disappeared is ignored.
    func pendingTaskCount(for mode: MenuBarCounterMode, now: Date = Date()) -> Int {
        guard isSignedIn, mode != .off else { return 0 }
        var tasksByListID = taskCacheByListID
        if let selectedListId {
            tasksByListID[selectedListId] = tasks
        }
        var knownListIDs = Set(taskLists.map(\.id))
        if let selectedListId { knownListIDs.insert(selectedListId) }
        return tasksByListID.reduce(0) { total, entry in
            guard knownListIDs.contains(entry.key) else { return total }
            return total + TaskMenu.pendingTaskCount(in: entry.value, mode: mode, now: now)
        }
    }

    /// Whether the periodic menu-bar count refresh loop is running (test probe).
    var isMenuBarCountRefreshLoopRunning: Bool { menuBarCountRefreshLoop != nil }

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
    /// Short git commit the running build was stamped with, or nil for builds
    /// made outside a git checkout.
    let currentBuildCommit: String?

    /// Version plus build commit, e.g. `1.3.0 (a1b2c3d)`. Unstamped builds
    /// show `dev` in place of the commit. Update checks compare
    /// `currentAppVersion`, not this string.
    var currentAppVersionDisplay: String {
        "\(currentAppVersion) (\(currentBuildCommit ?? "dev"))"
    }

    var selectedList: TaskList? {
        taskLists.first { $0.id == selectedListId }
    }

    var isShowingInitialTaskLoad: Bool {
        isSignedIn && !hasCompletedInitialTaskLoad && taskLists.isEmpty && tasks.isEmpty
    }

    /// Root-level tasks (no parent) in the user's chosen sort order.
    var rootTasks: [TaskItem] {
        tasksSorted(tasks.filter { $0.parent == nil }, by: taskSortOrder)
    }

    /// Children of a given task, always ordered by Google's sibling position
    /// regardless of `taskSortOrder`.
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

    /// Root-level tasks from the search-filtered set, in the chosen sort order.
    var searchFilteredRootTasks: [TaskItem] {
        tasksSorted(searchFilteredTasks.filter { $0.parent == nil }, by: taskSortOrder)
    }

    /// Subtasks of a given task from the search-filtered set, in Google order.
    func searchFilteredSubtasks(of taskID: String) -> [TaskItem] {
        tasksSortedByGooglePosition(searchFilteredTasks.filter { $0.parent == taskID })
    }

    private func taskMatchesQuery(_ task: TaskItem, query: String) -> Bool {
        if task.title.lowercased().contains(query) { return true }
        if let notes = task.notes, notes.lowercased().contains(query) { return true }
        return false
    }

    /// Expands a parent task so its subtasks are visible. Used when a new
    /// subtask row has to be shown under a collapsed parent.
    func expandTask(_ taskID: String) {
        collapsedTaskIDs.remove(taskID)
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
    /// Held separately so demo mode can swap `api` out and restore it on exit.
    private let liveAPI: any TasksAPIProtocol
    private var api: any TasksAPIProtocol
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
    /// Pacing of the background count refresh loop; tests inject a short value.
    private let menuBarCountRefreshInterval: Duration
    /// The 5-minute loop; nil while the counter is off or the app is signed out.
    private var menuBarCountRefreshLoop: Task<Void, Never>?
    /// The sweep currently fetching lists, so ticks and re-triggers never overlap.
    private var menuBarCountRefreshTask: Task<Void, Never>?
    /// Identifies the sweep that owns `menuBarCountRefreshTask`; a cancelled
    /// sweep that unwinds after its replacement started must not clear the slot.
    private var menuBarCountSweepID = 0

    /// Mac App Store builds do not compile `GitHubUpdateChecker`, so they fall
    /// back to a checker that always reports "no update".
    private static func defaultUpdateChecker() -> any UpdateChecking {
        #if APP_STORE_BUILD
        DisabledUpdateChecker()
        #else
        GitHubUpdateChecker()
        #endif
    }

    init(
        authService: GoogleAuthService = GoogleAuthService(),
        api: (any TasksAPIProtocol)? = nil,
        userDefaults: UserDefaults = .standard,
        dueDateNotificationService: any DueDateNotificationServicing = DueDateNotificationService(),
        updateChecker: any UpdateChecking = defaultUpdateChecker(),
        menuBarCountRefreshInterval: Duration = .seconds(5 * 60),
        currentAppVersion: String = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0",
        currentBuildCommit: String? = Bundle.main.infoDictionary?["GITCommitHash"] as? String
    ) {
        self.authService = authService
        let liveAPI = api ?? GoogleTasksAPI(authService: authService)
        self.liveAPI = liveAPI
        self.api = liveAPI
        self.userDefaults = userDefaults
        self.dueDateNotificationService = dueDateNotificationService
        self.updateChecker = updateChecker
        self.menuBarCountRefreshInterval = menuBarCountRefreshInterval
        self.currentAppVersion = currentAppVersion
        let trimmedBuildCommit = currentBuildCommit?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.currentBuildCommit = (trimmedBuildCommit?.isEmpty ?? true) ? nil : trimmedBuildCommit
        self.dueDateNotificationsEnabled = userDefaults.object(
            forKey: Constants.UserDefaults.dueDateNotificationsEnabledKey
        ) as? Bool ?? true
        self.automaticUpdateChecksEnabled = userDefaults.object(
            forKey: Constants.UserDefaults.automaticUpdateChecksEnabledKey
        ) as? Bool ?? true
        self.lastUpdateCheckDate = userDefaults.object(
            forKey: Constants.UserDefaults.lastUpdateCheckDateKey
        ) as? Date
        // An unknown stored value falls back to the default rather than crashing.
        self.taskSortOrder = userDefaults.string(forKey: Constants.UserDefaults.taskSortOrderKey)
            .flatMap(TaskSortOrder.init(rawValue:)) ?? .myOrder
        self.menuBarCounterMode = userDefaults.string(forKey: Constants.UserDefaults.menuBarCounterModeKey)
            .flatMap(MenuBarCounterMode.init(rawValue:)) ?? .off
        self.isSignedIn = authService.isSignedIn
        self.googleAccountProfile = authService.accountProfile
    }

    private var signInTask: Task<Void, Never>?
    /// Retired when the app moves on, so a stale attempt cannot write back.
    private var signInGeneration = 0

    func signIn() {
        guard signInTask == nil, !isDemoMode else { return }

        errorMessage = nil
        isLoading = true
        signInGeneration += 1
        let generation = signInGeneration
        signInTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if self.signInGeneration == generation {
                    self.isLoading = false
                    self.signInTask = nil
                }
            }
            do {
                try await authService.signIn()
                guard self.signInGeneration == generation else { return }
                self.isSignedIn = true
                self.googleAccountProfile = authService.accountProfile
                await self.loadTaskLists()
            } catch {
                guard self.signInGeneration == generation else { return }
                self.errorMessage = "Sign in failed: \(error.localizedDescription)"
            }
        }
    }

    /// Swaps in sample data and marks the session signed in so the task UI
    /// renders. Takes over from a sign-in still in flight: an abandoned web
    /// authentication never resumes, so waiting for it would wait forever.
    func enterDemoMode() {
        guard !isDemoMode, !isSignedIn else { return }

        signInGeneration += 1
        signInTask?.cancel()
        signInTask = nil
        isLoading = false

        errorMessage = nil
        isDemoMode = true
        api = DemoTasksAPI()
        isSignedIn = true
        googleAccountProfile = nil
        Task { await loadTaskLists() }
    }

    /// Discards the sample data and returns to the signed-out screen, so a
    /// real sign-in afterwards talks to Google again.
    func exitDemoMode() {
        guard isDemoMode else { return }

        isDemoMode = false
        api = liveAPI
        clearSignedInState()
    }

    func signOut() {
        // Demo mode has no token to discard; "sign out" means "leave the demo".
        guard !isDemoMode else {
            exitDemoMode()
            return
        }

        authService.signOut()
        clearSignedInState()
    }

    func disconnectGoogleAccount() async {
        guard !isDemoMode else {
            exitDemoMode()
            return
        }

        let revocationSucceeded = await authService.disconnect()
        clearSignedInState()
        if !revocationSucceeded {
            errorMessage = "Signed out, but Google revocation failed. "
                + "Review access at myaccount.google.com/permissions."
        }
    }

    func refreshGoogleAccountProfileIfNeeded() async {
        guard isSignedIn, !isDemoMode, googleAccountProfile == nil else { return }
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
        stopMenuBarCountRefresh()
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
            // Spawned, not awaited: the visible load returns as fast as before
            // while the other lists fill in for the menu-bar count.
            scheduleMenuBarCountRefresh()
        } catch {
            guard isSignedIn else { return }
            handleError(error)
        }
    }

    /// Creates a task list from a trimmed, non-empty title, appends it to
    /// `taskLists`, and selects it. Blank titles are ignored. Failures surface
    /// through `errorMessage`; nothing is added optimistically, so there is no
    /// rollback. Returns the created list, or nil when nothing was created.
    @discardableResult
    func createTaskList(title: String) async -> TaskList? {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTitle.isEmpty, isSignedIn else { return nil }
        do {
            let list = try await api.createTaskList(title: trimmedTitle)
            // Sign-out (or leaving the demo) during the request cleared the
            // lists; do not repopulate signed-out state.
            guard isSignedIn else { return nil }
            taskLists.removeAll { $0.id == list.id }
            taskLists.append(list)
            await selectList(list.id)
            return list
        } catch {
            guard isSignedIn else { return nil }
            handleError(error)
            return nil
        }
    }

    // MARK: - Menu-bar counter refresh

    /// Kicks off the account-wide fetch that keeps `menuBarPendingCount` covering
    /// every list, and makes sure the periodic loop is running. No-op when the
    /// counter is Off or the app is signed out; a sweep already in flight is not
    /// duplicated. Never awaited by the callers on the visible load path.
    private func scheduleMenuBarCountRefresh(includingSelectedList: Bool = false) {
        guard menuBarCounterMode != .off, isSignedIn else { return }
        startMenuBarCountRefreshLoopIfNeeded()
        guard menuBarCountRefreshTask == nil else { return }
        menuBarCountSweepID += 1
        let sweepID = menuBarCountSweepID
        menuBarCountRefreshTask = Task { [weak self] in
            guard let self else { return }
            await self.refreshMenuBarCounts(includingSelectedList: includingSelectedList)
            // Off → On (or sign-out → sign-in) cancels this sweep and may start
            // a new one before this task unwinds; only the current sweep may
            // free the slot, or the next tick would run a duplicate sweep
            // alongside the replacement.
            guard self.menuBarCountSweepID == sweepID else { return }
            self.menuBarCountRefreshTask = nil
        }
    }

    /// Whether an account-wide count sweep is currently fetching (test probe).
    var isMenuBarCountSweepInFlight: Bool { menuBarCountRefreshTask != nil }

    private func startMenuBarCountRefreshLoopIfNeeded() {
        guard menuBarCountRefreshLoop == nil else { return }
        let interval = menuBarCountRefreshInterval
        menuBarCountRefreshLoop = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: interval)
                } catch {
                    return
                }
                guard let self, self.isSignedIn, self.menuBarCounterMode != .off else { return }
                // Ticks refresh the selected list too, so a popover left closed
                // for hours does not pin a stale contribution.
                self.scheduleMenuBarCountRefresh(includingSelectedList: true)
            }
        }
    }

    private func stopMenuBarCountRefresh() {
        menuBarCountRefreshLoop?.cancel()
        menuBarCountRefreshLoop = nil
        menuBarCountRefreshTask?.cancel()
        menuBarCountRefreshTask = nil
    }

    /// Fetches each known list into `taskCacheByListID` for counting. Off the
    /// visible load path on purpose: never toggles `isLoading`, never sets
    /// `errorMessage` (failures are skipped), never bumps `taskLoadRequestID`,
    /// and never calls `handleError` (a background 401 must not sign the user
    /// out; the next foreground refresh surfaces it). Each list captures the
    /// task-state generation before its request and discards the snapshot if
    /// anything was committed meanwhile, exactly like `refreshTasks()`. The
    /// selected list is only written when `includingSelectedList` is true, it
    /// is still selected, no newer foreground load has started, and the
    /// generation is unchanged; then both `tasks` and its cache entry are
    /// replaced. Fetches are sequential on purpose (small N, no request burst).
    private func refreshMenuBarCounts(includingSelectedList: Bool) async {
        let listIDs = taskLists.map(\.id)
        for listID in listIDs {
            guard isSignedIn, menuBarCounterMode != .off, !Task.isCancelled else { return }
            let isSelected = listID == selectedListId
            if isSelected && !includingSelectedList { continue }
            let generation = taskStateGeneration
            let requestID = taskLoadRequestID
            guard let fetched = try? await api.listTasks(listId: listID) else { continue }
            guard isSignedIn, menuBarCounterMode != .off,
                  taskStateGeneration == generation,
                  taskLists.contains(where: { $0.id == listID })
            else { continue }
            if listID == selectedListId {
                guard includingSelectedList, taskLoadRequestID == requestID else { continue }
                tasks = fetched
            } else if isSelected {
                // Was selected when the request started but not any more; the
                // list switch already loaded it through the foreground path.
                continue
            }
            taskCacheByListID[listID] = fetched
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

    /// Creates a subtask under `parentId`. The Tasks API inserts a task that
    /// carries a parent and no `previous` as the parent's first child, and
    /// the existing siblings' positions can change server-side to make room,
    /// so the created task's returned position is not comparable with the
    /// stale sibling positions held locally: it can tie with, or sort after,
    /// the sibling it actually precedes on the server. The commit therefore
    /// places the task first among its siblings the way a move would,
    /// rewriting the sibling group's positions; the exact server positions
    /// reconcile on the next refresh.
    @discardableResult
    func addSubtask(title: String, parentId: String) async -> TaskItem? {
        guard let listId = selectedListId else { return nil }
        do {
            let task = try await api.createTask(listId: listId, title: title, parentId: parentId)
            guard isSignedIn else { return nil }
            commitTaskChange(to: listId) { tasks in
                // File it under the parent that was asked for; the reorder
                // reads the parent off the task.
                var subtask = task
                subtask.parent = parentId
                tasks = tasksWithCreatedTask(subtask, in: tasks)
            }
            await syncDueDateNotificationsIfNeeded()
            return task
        } catch {
            guard isSignedIn else { return nil }
            handleError(error)
            return nil
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
    /// reorder optimistically and rolls back if the API move fails. Ignored
    /// unless `canReorderTasks`: under any other sort the visible order is not
    /// the position order the drop indices describe.
    func moveTask(_ task: TaskItem, toParent newParentID: String?, after previousTaskID: String?) async {
        guard canReorderTasks,
              let listId = selectedListId,
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
        // Demo tasks are sample data, so they never schedule real reminders.
        guard isSignedIn, !isDemoMode, dueDateNotificationsEnabled, let selectedList else { return }
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
