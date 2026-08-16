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

/// The task's id plus the ids of all of its descendants, walking the parent
/// relation transitively so nested subtasks are included. The task's own id
/// comes first; the rest follow in breadth-first order.
func taskIDsIncludingDescendants(of taskID: String, in tasks: [TaskItem]) -> [String] {
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

/// Files a task tree that arrived from another list into `tasks`: the root
/// (`rootTaskID`) becomes the first top-level task and the destination's
/// root positions are rewritten the way `tasksReorderedAfterMove` does; the
/// tree's subtasks keep their own positions and parent. Any stale copies of
/// the moved tasks already in `tasks` are replaced. Mirrors what
/// `tasks.move` with `destinationTasklist` and no `parent`/`previous` does.
func tasksInsertingMovedTaskTree(_ movedTasks: [TaskItem], rootTaskID: String, into tasks: [TaskItem]) -> [TaskItem] {
    let movedIDs = Set(movedTasks.map(\.id))
    var updatedTasks = tasks.filter { !movedIDs.contains($0.id) }
    updatedTasks.insert(contentsOf: movedTasks, at: 0)
    return tasksReorderedAfterMove(
        updatedTasks,
        movedTaskID: rootTaskID,
        newParentID: nil,
        previousTaskID: nil
    ) ?? updatedTasks
}

/// The in-memory equivalent of `tasks.move` with `destinationTasklist`, shared
/// by the demo and testing-window fakes: the task tree rooted at `taskID`
/// leaves `sourceTasks` and lands first among `destinationTasks`' roots, then
/// an optional `parentId`/`previousTaskId` places it inside the destination.
/// Returns the updated source, destination, and moved task, or nil when the
/// task is missing or the placement is invalid.
func tasksMovingTaskTree(
    _ taskID: String,
    from sourceTasks: [TaskItem],
    to destinationTasks: [TaskItem],
    parentId: String?,
    previousTaskId: String?
) -> (source: [TaskItem], destination: [TaskItem], movedTask: TaskItem)? {
    let movedIDs = Set(taskIDsIncludingDescendants(of: taskID, in: sourceTasks))
    let movedTasks = sourceTasks.filter { movedIDs.contains($0.id) }
    guard movedTasks.contains(where: { $0.id == taskID }) else { return nil }
    var destination = tasksInsertingMovedTaskTree(movedTasks, rootTaskID: taskID, into: destinationTasks)
    if parentId != nil || previousTaskId != nil {
        guard let reordered = tasksReorderedAfterMove(
            destination,
            movedTaskID: taskID,
            newParentID: parentId,
            previousTaskID: previousTaskId
        ) else { return nil }
        destination = reordered
    }
    guard let movedTask = destination.first(where: { $0.id == taskID }) else { return nil }
    return (sourceTasks.filter { !movedIDs.contains($0.id) }, destination, movedTask)
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
    var hasCompletedInitialTaskLoad = false

    /// The pane the popover always shows. Every single-pane accessor and
    /// mutation on `AppState` (`selectedListId`, `tasks`, `addTask(title:)`,
    /// …) forwards here.
    let primaryPane = TaskListPane(id: .primary)
    /// The right-hand pane, rendered only while `sideBySideListsEnabled`. It
    /// keeps its selection in memory while hidden and is re-seeded from the
    /// cache when shown again.
    let secondaryPane = TaskListPane(id: .secondary)

    /// Panes the popover renders: the primary alone, or both while the
    /// side-by-side layout is on.
    var visiblePanes: [TaskListPane] {
        sideBySideListsEnabled ? [primaryPane, secondaryPane] : [primaryPane]
    }

    /// Two-pane popover preference. Persisted; off by default. Turning it on
    /// while signed in gives the secondary pane a list and loads it; turning
    /// it off tears nothing down, so the secondary remembers its selection.
    var sideBySideListsEnabled: Bool {
        didSet {
            userDefaults.set(sideBySideListsEnabled, forKey: Constants.UserDefaults.sideBySideListsEnabledKey)
            guard sideBySideListsEnabled, !oldValue, isSignedIn else { return }
            ensureSecondaryPaneSelection()
            if let listId = secondaryPane.selectedListId {
                // The pane may have gone stale while hidden (it is not a
                // commit target then); the cache is current.
                showCachedTasks(of: listId, in: secondaryPane)
            }
            let secondaryPane = secondaryPane
            Task { [weak self] in
                await self?.refreshTasks(in: secondaryPane)
            }
        }
    }

    // MARK: Primary-pane forwarders

    // Kept so single-pane call sites and tests read and write the primary
    // pane exactly as they did before panes existed. Reading them inside an
    // observation closure tracks the pane's own stored properties.

    var selectedListId: String? {
        get { primaryPane.selectedListId }
        set { primaryPane.selectedListId = newValue }
    }

    var tasks: [TaskItem] {
        get { primaryPane.tasks }
        set { primaryPane.tasks = newValue }
    }

    var collapsedTaskIDs: Set<String> {
        get { primaryPane.collapsedTaskIDs }
        set { primaryPane.collapsedTaskIDs = newValue }
    }

    var searchText: String {
        get { primaryPane.searchText }
        set { primaryPane.searchText = newValue }
    }

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
    /// out or Off. Reads each visible pane's live `tasks` for the list it
    /// shows and `taskCacheByListID` for every other known list, so local
    /// mutations committed through `commitTaskChange` show up immediately.
    var menuBarPendingCount: Int {
        pendingTaskCount(for: menuBarCounterMode)
    }

    /// Same as `menuBarPendingCount` for an explicit mode (used by tests and by
    /// the accessor above). Only lists present in `taskLists` (plus the lists
    /// the visible panes show) contribute, so a cache entry for a list that
    /// disappeared is ignored.
    func pendingTaskCount(for mode: MenuBarCounterMode, now: Date = Date()) -> Int {
        guard isSignedIn, mode != .off else { return 0 }
        var tasksByListID = taskCacheByListID
        var knownListIDs = Set(taskLists.map(\.id))
        for pane in visiblePanes {
            guard let listId = pane.selectedListId else { continue }
            tasksByListID[listId] = pane.tasks
            knownListIDs.insert(listId)
        }
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
        selectedList(in: primaryPane)
    }

    /// The list `pane` shows, if it is still one of `taskLists`.
    func selectedList(in pane: TaskListPane) -> TaskList? {
        taskLists.first { $0.id == pane.selectedListId }
    }

    var isShowingInitialTaskLoad: Bool {
        isSignedIn && !hasCompletedInitialTaskLoad && taskLists.isEmpty && tasks.isEmpty
    }

    /// Root-level tasks (no parent) in the user's chosen sort order.
    var rootTasks: [TaskItem] {
        rootTasks(in: primaryPane)
    }

    /// Root-level tasks of `pane` in the user's chosen sort order.
    func rootTasks(in pane: TaskListPane) -> [TaskItem] {
        tasksSorted(pane.tasks.filter { $0.parent == nil }, by: taskSortOrder)
    }

    /// Children of a given task, always ordered by Google's sibling position
    /// regardless of `taskSortOrder`.
    func subtasks(of taskID: String) -> [TaskItem] {
        subtasks(of: taskID, in: primaryPane)
    }

    func subtasks(of taskID: String, in pane: TaskListPane) -> [TaskItem] {
        tasksSortedByGooglePosition(pane.tasks.filter { $0.parent == taskID })
    }

    /// Whether search is currently active.
    var isSearching: Bool {
        primaryPane.isSearching
    }

    /// Tasks filtered by the current search text.
    /// When searching, includes tasks that match by title/notes, plus parents of matching subtasks.
    /// Returns all tasks when search text is empty.
    var searchFilteredTasks: [TaskItem] {
        searchFilteredTasks(in: primaryPane)
    }

    /// `pane`'s tasks filtered by that pane's search text (all of them while
    /// the filter is empty); parents of matching subtasks are included.
    func searchFilteredTasks(in pane: TaskListPane) -> [TaskItem] {
        guard pane.isSearching else { return pane.tasks }

        // Build the visible set: direct matches + parents of matching subtasks
        let directMatchIDs = directSearchMatchIDs(in: pane)
        var visibleIDs = directMatchIDs
        for task in pane.tasks where directMatchIDs.contains(task.id) {
            if let parentID = task.parent {
                visibleIDs.insert(parentID)
            }
        }

        return pane.tasks.filter { visibleIDs.contains($0.id) }
    }

    /// Number of tasks that directly match the current search text. Parents
    /// shown only as context for a matching subtask are not counted.
    var searchMatchCount: Int {
        searchMatchCount(in: primaryPane)
    }

    func searchMatchCount(in pane: TaskListPane) -> Int {
        guard pane.isSearching else { return 0 }
        return directSearchMatchIDs(in: pane).count
    }

    /// IDs of tasks whose title or notes match the pane's search text.
    private func directSearchMatchIDs(in pane: TaskListPane) -> Set<String> {
        let query = pane.searchText.lowercased()
        return Set(pane.tasks.filter { taskMatchesQuery($0, query: query) }.map(\.id))
    }

    /// Root-level tasks from the search-filtered set, in the chosen sort order.
    var searchFilteredRootTasks: [TaskItem] {
        searchFilteredRootTasks(in: primaryPane)
    }

    func searchFilteredRootTasks(in pane: TaskListPane) -> [TaskItem] {
        tasksSorted(searchFilteredTasks(in: pane).filter { $0.parent == nil }, by: taskSortOrder)
    }

    /// Subtasks of a given task from the search-filtered set, in Google order.
    func searchFilteredSubtasks(of taskID: String) -> [TaskItem] {
        searchFilteredSubtasks(of: taskID, in: primaryPane)
    }

    func searchFilteredSubtasks(of taskID: String, in pane: TaskListPane) -> [TaskItem] {
        tasksSortedByGooglePosition(searchFilteredTasks(in: pane).filter { $0.parent == taskID })
    }

    private func taskMatchesQuery(_ task: TaskItem, query: String) -> Bool {
        if task.title.lowercased().contains(query) { return true }
        if let notes = task.notes, notes.lowercased().contains(query) { return true }
        return false
    }

    /// Tasks of a list as the app currently knows them: the visible pane
    /// showing it, else the cache; empty when the list was never loaded.
    func tasks(in listID: String) -> [TaskItem] {
        if let pane = visiblePanes.first(where: { $0.selectedListId == listID }) {
            return pane.tasks
        }
        return taskCacheByListID[listID] ?? []
    }

    /// Expands a parent task so its subtasks are visible. Used when a new
    /// subtask row has to be shown under a collapsed parent.
    func expandTask(_ taskID: String) {
        primaryPane.expandTask(taskID)
    }

    /// Toggle collapse state for a parent task.
    func toggleCollapsed(_ taskID: String) {
        primaryPane.toggleCollapsed(taskID)
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
    /// Lists whose locally known tasks are not the list: a cache entry seeded
    /// by `moveTask(_:toList:)` before the list was ever fetched (only the
    /// moved task trees), or a list a pane was pointed at before its first
    /// fetch landed (the pane shows an empty placeholder meanwhile). Reminders
    /// are never synced from such state (a sync removes every pending and
    /// delivered reminder of the list that is not in the array it is handed,
    /// and forgets what it already fired); the next full fetch of the list
    /// clears the mark.
    private var partiallyCachedListIDs: Set<String> = []
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
        self.sideBySideListsEnabled = userDefaults.object(
            forKey: Constants.UserDefaults.sideBySideListsEnabledKey
        ) as? Bool ?? false
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
        for pane in [primaryPane, secondaryPane] {
            pane.selectedListId = nil
            pane.tasks = []
            pane.isLoading = false
            pane.taskLoadRequestID += 1
        }
        hasCompletedInitialTaskLoad = false
        taskCacheByListID = [:]
        partiallyCachedListIDs = []
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
            if primaryPane.selectedListId == nil, let first = taskLists.first {
                primaryPane.selectedListId = first.id
                showCachedTasks(of: first.id, in: primaryPane)
            }
            ensureSecondaryPaneSelection()
            await refreshTasks()
            // Spawned, not awaited: the visible load returns as fast as before
            // while the other lists fill in for the menu-bar count.
            scheduleMenuBarCountRefresh()
        } catch {
            guard isSignedIn else { return }
            handleError(error)
        }
    }

    /// Gives the secondary pane a list when it is shown and has none, or its
    /// list vanished: the one after the primary's, wrapping around (see
    /// `TaskListPane.defaultSecondaryListID`). Seeds its tasks from the cache
    /// so it is not blank until the load lands.
    private func ensureSecondaryPaneSelection() {
        guard sideBySideListsEnabled, !taskLists.isEmpty else { return }
        if let id = secondaryPane.selectedListId, taskLists.contains(where: { $0.id == id }) { return }
        secondaryPane.selectedListId = TaskListPane.defaultSecondaryListID(
            in: taskLists,
            after: primaryPane.selectedListId
        )
        if let listId = secondaryPane.selectedListId {
            showCachedTasks(of: listId, in: secondaryPane)
        } else {
            secondaryPane.tasks = []
        }
    }

    /// Shows what the app knows of `listId` in `pane` right away: the cached
    /// tasks, or an empty placeholder when the list has never been fetched.
    /// The placeholder is not the list, so in that case the list is marked
    /// like a move-seeded cache and no reminder sync reads it before the first
    /// load lands (a sync of an empty array would drop the list's pending and
    /// delivered reminders and re-fire today's once the real tasks arrive).
    private func showCachedTasks(of listId: String, in pane: TaskListPane) {
        if let cachedTasks = taskCacheByListID[listId] {
            pane.tasks = cachedTasks
        } else {
            pane.tasks = []
            partiallyCachedListIDs.insert(listId)
        }
    }

    /// Creates a task list from a trimmed, non-empty title, appends it to
    /// `taskLists`, and selects it in `pane` (the primary when nil). Blank
    /// titles are ignored. Failures surface through `errorMessage`; nothing is
    /// added optimistically, so there is no rollback. Returns the created
    /// list, or nil when nothing was created.
    @discardableResult
    func createTaskList(title: String, in pane: TaskListPane? = nil) async -> TaskList? {
        let pane = pane ?? primaryPane
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTitle.isEmpty, isSignedIn else { return nil }
        do {
            let list = try await api.createTaskList(title: trimmedTitle)
            // Sign-out (or leaving the demo) during the request cleared the
            // lists; do not repopulate signed-out state.
            guard isSignedIn else { return nil }
            taskLists.removeAll { $0.id == list.id }
            taskLists.append(list)
            // A secondary pane that had no list yet (the account had none)
            // now has one to show.
            ensureSecondaryPaneSelection()
            await selectList(list.id, in: pane)
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
    /// `errorMessage` (failures are skipped), never bumps a pane's
    /// `taskLoadRequestID`, and never calls `handleError` (a background 401
    /// must not sign the user out; the next foreground refresh surfaces it).
    /// Each list captures the task-state generation before its request and
    /// discards the snapshot if anything was committed meanwhile, exactly like
    /// `refreshTasks()`. A list a visible pane shows is only written when
    /// `includingSelectedList` is true, every pane showing it was already
    /// showing it when the request started with no newer foreground load
    /// since, and the generation is unchanged; then those panes' `tasks` and
    /// the cache entry are replaced. Fetches are sequential on purpose (small
    /// N, no request burst).
    private func refreshMenuBarCounts(includingSelectedList: Bool) async {
        let listIDs = taskLists.map(\.id)
        for listID in listIDs {
            guard isSignedIn, menuBarCounterMode != .off, !Task.isCancelled else { return }
            let showingPanes = visiblePanes.filter { $0.selectedListId == listID }
            let wasShown = !showingPanes.isEmpty
            if wasShown && !includingSelectedList { continue }
            let generation = taskStateGeneration
            let requestIDsByPane = showingPanes.map { ($0, $0.taskLoadRequestID) }
            guard let fetched = try? await api.listTasks(listId: listID) else { continue }
            guard isSignedIn, menuBarCounterMode != .off,
                  taskStateGeneration == generation,
                  taskLists.contains(where: { $0.id == listID })
            else { continue }
            let nowShowingPanes = visiblePanes.filter { $0.selectedListId == listID }
            if !nowShowingPanes.isEmpty {
                guard includingSelectedList else { continue }
                // A pane that switched onto the list during the request, or
                // started a newer load, is served by the foreground path.
                let isCurrentForEveryPane = nowShowingPanes.allSatisfy { pane in
                    requestIDsByPane.contains { $0.0 === pane && $0.1 == pane.taskLoadRequestID }
                }
                guard isCurrentForEveryPane else { continue }
                for pane in nowShowingPanes {
                    pane.tasks = fetched
                }
            } else if wasShown {
                // Was shown when the request started but not any more; the
                // list switch already loaded it through the foreground path.
                continue
            }
            cacheFetchedTasks(fetched, for: listID)
        }
    }

    func refreshForMenuPresentation() async {
        guard isSignedIn, !isLoading else { return }

        if taskLists.isEmpty || selectedListId == nil {
            await loadTaskLists()
        } else {
            ensureSecondaryPaneSelection()
            await refreshTasks()
        }
    }

    /// Explicit refresh: fetches both active and completed tasks fresh from
    /// the server for every visible pane, one request per distinct list
    /// (concurrently when the panes show different lists).
    func refreshTasks() async {
        var listIDs: [String] = []
        for pane in visiblePanes {
            if let listId = pane.selectedListId, !listIDs.contains(listId) {
                listIDs.append(listId)
            }
        }
        guard !listIDs.isEmpty else { return }
        if listIDs.count == 1 {
            let listId = listIDs[0]
            await loadTasks(for: listId, into: visiblePanes.filter { $0.selectedListId == listId })
            return
        }
        // Two lists: fetch in parallel. `Task {}` inherits the main actor, so
        // the pane references never leave it.
        let loads = listIDs.map { listId in
            Task { [weak self] in
                guard let self else { return }
                await self.loadTasks(for: listId, into: self.visiblePanes.filter { $0.selectedListId == listId })
            }
        }
        for load in loads {
            await load.value
        }
    }

    /// Refreshes the list `pane` shows, applying the response to every visible
    /// pane showing that list as well.
    func refreshTasks(in pane: TaskListPane) async {
        guard let listId = pane.selectedListId else { return }
        var targets = visiblePanes.filter { $0.selectedListId == listId }
        if !targets.contains(where: { $0 === pane }) {
            targets.append(pane)
        }
        await loadTasks(for: listId, into: targets)
    }

    /// One request for `listId`, applied to every pane in `targetPanes`
    /// through its own load token, so each pane's stale-load protection and
    /// loading flag work independently.
    private func loadTasks(for listId: String, into targetPanes: [TaskListPane]) async {
        let tokens = targetPanes.map { beginTaskLoad(for: listId, in: $0) }
        defer { tokens.forEach(finishTaskLoad) }
        do {
            let allTasks = try await api.listTasks(listId: listId)
            // A mutation or sign-out during the fetch makes this snapshot
            // stale for the cache as well as the visible list; drop it. Every
            // token shares the generation captured before the request.
            guard tokens.first?.generation == taskStateGeneration else { return }
            cacheFetchedTasks(allTasks, for: listId)
            for token in tokens {
                applyLoadedTasks(allTasks, for: token)
            }
            if tokens.contains(where: isCurrentTaskLoad) {
                await syncDueDateNotificationsIfNeeded()
            }
        } catch {
            // Once, not per pane.
            if tokens.contains(where: isCurrentTaskLoad) {
                handleError(error)
            }
        }
    }

    @discardableResult
    func addTask(title: String, in pane: TaskListPane? = nil) async -> TaskItem? {
        let pane = pane ?? primaryPane
        guard let listId = pane.selectedListId else { return nil }
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
    func addSubtask(title: String, parentId: String, in pane: TaskListPane? = nil) async -> TaskItem? {
        let pane = pane ?? primaryPane
        guard let listId = pane.selectedListId else { return nil }
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

    func toggleTask(_ task: TaskItem, in pane: TaskListPane? = nil) async {
        let pane = pane ?? primaryPane
        guard let listId = pane.selectedListId else { return }
        // Toggle from the live value so a rapid second click on a stale row
        // snapshot reverses the first toggle instead of repeating it.
        let original = pane.tasks.first(where: { $0.id == task.id }) ?? task
        var updated = original
        updated.isCompleted.toggle()

        // Completing a parent also completes its open subtasks, matching Google Tasks.
        // Un-completing a parent does not cascade.
        let cascadedChildren = updated.isCompleted
            ? subtasks(of: original.id, in: pane).filter { !$0.isCompleted }
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

    func updateTask(_ task: TaskItem, in pane: TaskListPane? = nil) async {
        let pane = pane ?? primaryPane
        guard let listId = pane.selectedListId else { return }
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

    func deleteTask(_ task: TaskItem, in pane: TaskListPane? = nil) async {
        let pane = pane ?? primaryPane
        guard let listId = pane.selectedListId else { return }
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
    func moveTask(
        _ task: TaskItem,
        toParent newParentID: String?,
        after previousTaskID: String?,
        in pane: TaskListPane? = nil
    ) async {
        let pane = pane ?? primaryPane
        let tasks = pane.tasks
        guard canReorderTasks,
              let listId = pane.selectedListId,
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

    /// Moves a top-level task together with its subtasks from the list `pane`
    /// shows (the primary's when nil) to `destinationListID`, where it lands
    /// first among the root tasks. Optimistic: both lists change immediately
    /// (every visible pane showing either list, plus the caches) and the move
    /// is undone with `errorMessage` set if the API call fails. Subtasks are
    /// never moved on their own, since that would leave their parent behind.
    func moveTask(_ task: TaskItem, toList destinationListID: String, from pane: TaskListPane? = nil) async {
        let pane = pane ?? primaryPane
        let tasks = pane.tasks
        guard let sourceListID = pane.selectedListId,
              destinationListID != sourceListID,
              let liveTask = tasks.first(where: { $0.id == task.id }),
              liveTask.parent == nil
        else { return }

        // Snapshot the tree (array order preserved) so a failure can put it
        // back exactly where it was; source positions are never rewritten.
        let movedIDs = taskIDsIncludingDescendants(of: task.id, in: tasks)
        let movedIDSet = Set(movedIDs)
        let movedTasks = tasks.filter { movedIDSet.contains($0.id) }
        let originalIndex = tasks.firstIndex { $0.id == task.id } ?? 0
        // A destination that was never fetched gets a cache holding only the
        // moved tree; mark it so no reminder sync treats that as the list.
        // The mark outlives a rollback on purpose (the entry stays, empty).
        if taskCacheByListID[destinationListID] == nil {
            partiallyCachedListIDs.insert(destinationListID)
        }

        commitTaskChange(to: sourceListID) { tasks in
            tasks.removeAll { movedIDSet.contains($0.id) }
        }
        commitTaskChange(to: destinationListID) { tasks in
            tasks = tasksInsertingMovedTaskTree(movedTasks, rootTaskID: task.id, into: tasks)
        }

        do {
            // The returned position is not comparable with the cached sibling
            // positions (same reason as `addSubtask`); the next refresh reconciles.
            _ = try await api.moveTask(
                listId: sourceListID,
                taskId: task.id,
                parentId: nil,
                previousTaskId: nil,
                destinationListId: destinationListID
            )
            guard isSignedIn else { return }
            let dueDateNotificationService = dueDateNotificationService
            await enqueueNotificationWork {
                await dueDateNotificationService.removeNotifications(forTaskIDs: movedIDs, inListID: sourceListID)
            }.value
            await syncDueDateNotificationsIfNeeded()
            // Re-syncs the destination's reminders, unless its cache is still
            // only the moved trees (`partiallyCachedListIDs`, checked inside):
            // syncing a partial cache would wipe that list's other reminders,
            // so the next full load of the list schedules them instead.
            await enqueueNotificationWork { [weak self] in
                await self?.performDueDateNotificationSync(forListID: destinationListID)
            }.value
        } catch {
            guard isSignedIn else { return }
            // Roll back against the current state so edits committed during
            // the request survive.
            commitTaskChange(to: destinationListID) { tasks in
                tasks.removeAll { movedIDSet.contains($0.id) }
            }
            commitTaskChange(to: sourceListID) { tasks in
                tasks.removeAll { movedIDSet.contains($0.id) }
                tasks.insert(contentsOf: movedTasks, at: min(originalIndex, tasks.endIndex))
            }
            handleError(error)
        }
    }

    /// Switches `pane` (the primary when nil) to `listId`: shows the cached
    /// tasks right away, then refreshes that list for every pane showing it.
    func selectList(_ listId: String, in pane: TaskListPane? = nil) async {
        let pane = pane ?? primaryPane
        pane.selectedListId = listId
        showCachedTasks(of: listId, in: pane)
        await refreshTasks(in: pane)
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

    /// Guarded syncs against current state: one for `listID` when given,
    /// otherwise one per distinct list the visible panes show. Only call from
    /// the notification work chain so it cannot interleave with a sign-out's
    /// removeAll or a preference flip's removal. The service caps pending
    /// requests globally, so syncing two lists is safe.
    private func performDueDateNotificationSync(forListID listID: String? = nil) async {
        // Demo tasks are sample data, so they never schedule real reminders.
        guard isSignedIn, !isDemoMode, dueDateNotificationsEnabled else { return }
        var targetListIDs: [String] = []
        if let listID {
            targetListIDs = [listID]
        } else {
            for pane in visiblePanes {
                if let id = pane.selectedListId, !targetListIDs.contains(id) {
                    targetListIDs.append(id)
                }
            }
        }
        for targetListID in targetListIDs {
            // A cache seeded only by moves, or a pane's empty placeholder for
            // a list whose first fetch has not landed, is not the list;
            // syncing it would drop every other pending reminder of that list
            // until it is next loaded.
            guard isSignedIn, !isDemoMode, dueDateNotificationsEnabled,
                  !partiallyCachedListIDs.contains(targetListID),
                  let list = taskLists.first(where: { $0.id == targetListID })
            else { continue }
            await dueDateNotificationService.syncNotifications(for: tasks(in: targetListID), in: list)
        }
    }

    /// Read-only view of the per-list cache; a visible pane's list entry
    /// mirrors that pane's `tasks`. Nil when the list has never been loaded or
    /// written.
    func cachedTasks(forListID listID: String) -> [TaskItem]? {
        taskCacheByListID[listID]
    }

    /// Applies a committed local change to the list captured before a
    /// request's await: every visible pane showing that list gets the result
    /// (so two panes on one list stay identical), and so does that list's
    /// cache; a list switch during the request therefore cannot leak the
    /// change into the wrong list. A hidden secondary pane is deliberately not
    /// a target; it is re-seeded from the cache when shown again. Bumps the
    /// task-state generation so in-flight loads discard stale snapshots.
    private func commitTaskChange(to listId: String, _ apply: (inout [TaskItem]) -> Void) {
        taskStateGeneration += 1
        let showingPanes = visiblePanes.filter { $0.selectedListId == listId }
        var updatedTasks = showingPanes.first?.tasks ?? taskCacheByListID[listId] ?? []
        apply(&updatedTasks)
        for pane in showingPanes {
            pane.tasks = updatedTasks
        }
        taskCacheByListID[listId] = updatedTasks
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

    /// Identifies one in-flight task load for one pane: the pane and list it
    /// was started for, the pane's load request it belongs to, and the
    /// task-state generation it saw. Main-actor only (it holds a pane).
    private struct TaskLoadToken {
        let pane: TaskListPane
        let listID: String
        let requestID: Int
        let generation: Int
    }

    private func beginTaskLoad(for listId: String, in pane: TaskListPane) -> TaskLoadToken {
        pane.taskLoadRequestID += 1
        pane.isLoading = true
        isLoading = true
        return TaskLoadToken(
            pane: pane,
            listID: listId,
            requestID: pane.taskLoadRequestID,
            generation: taskStateGeneration
        )
    }

    private func finishTaskLoad(_ token: TaskLoadToken) {
        // Only the newest load for the pane's visible list owns that pane's
        // loading indicator; a mutation bumping the generation must not leave
        // it on. The app-wide flag stays on while any pane still loads.
        guard token.pane.selectedListId == token.listID,
              token.pane.taskLoadRequestID == token.requestID
        else { return }
        token.pane.isLoading = false
        isLoading = primaryPane.isLoading || secondaryPane.isLoading
    }

    private func isCurrentTaskLoad(_ token: TaskLoadToken) -> Bool {
        token.pane.selectedListId == token.listID
            && token.pane.taskLoadRequestID == token.requestID
            && taskStateGeneration == token.generation
    }

    /// Stores a full server snapshot for `listId`, which also clears the
    /// partial mark left by a move into, or a pane pointed at, a list that
    /// had never been fetched.
    private func cacheFetchedTasks(_ fetchedTasks: [TaskItem], for listId: String) {
        taskCacheByListID[listId] = fetchedTasks
        partiallyCachedListIDs.remove(listId)
    }

    private func applyLoadedTasks(_ loadedTasks: [TaskItem], for token: TaskLoadToken) {
        guard isCurrentTaskLoad(token) else { return }
        token.pane.tasks = loadedTasks
    }
}
