import XCTest
@testable import TaskMenu

/// Two-pane state on `AppState`: the side-by-side preference, the secondary
/// pane's default list, per-pane loads and stale-load protection, per-list
/// refresh dedupe, mutation fan-out to every pane showing a list, hidden-pane
/// re-seeding, sign-out/demo reset, and notification sync per visible list.
/// Runs against a recording wrapper around `DemoTasksAPI` (three lists:
/// `demo-today`, `demo-work`, `demo-personal`).
@MainActor
final class SideBySidePanesTests: XCTestCase {
    private var userDefaults: UserDefaults!
    private var userDefaultsSuiteName: String!
    private var dueDateNotificationService: TestDueDateNotificationService!
    private var api: RecordingTasksAPI!
    private var state: AppState!

    override func setUp() async throws {
        userDefaultsSuiteName = "dev.crazytan.TaskMenu.tests.sidebyside.\(UUID().uuidString)"
        userDefaults = UserDefaults(suiteName: userDefaultsSuiteName)
        userDefaults.removePersistentDomain(forName: userDefaultsSuiteName)
        dueDateNotificationService = TestDueDateNotificationService()
        api = RecordingTasksAPI()
        state = makeState()
    }

    override func tearDown() async throws {
        if let userDefaultsSuiteName {
            userDefaults.removePersistentDomain(forName: userDefaultsSuiteName)
        }
        userDefaults = nil
        userDefaultsSuiteName = nil
        dueDateNotificationService = nil
        api = nil
        state = nil
    }

    // MARK: - Helpers

    private func makeState() -> AppState {
        AppState(
            authService: GoogleAuthService(keychain: InMemoryKeychainService()),
            api: api,
            userDefaults: userDefaults,
            dueDateNotificationService: dueDateNotificationService
        )
    }

    /// Signs in against the demo lists; the primary pane lands on `demo-today`.
    private func signInAndLoad() async {
        state.isSignedIn = true
        await state.loadTaskLists()
    }

    private func makeTask(id: String, title: String = "Task") -> TaskItem {
        TaskItem(
            id: id,
            title: title,
            notes: nil,
            status: .needsAction,
            due: nil,
            selfLink: nil,
            parent: nil,
            position: nil,
            updated: nil
        )
    }

    private func waitUntil(_ condition: @MainActor @escaping () -> Bool) async {
        for _ in 0..<100 {
            if condition() { return }
            await Task.yield()
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    private func waitUntil(_ condition: @escaping () async -> Bool) async {
        for _ in 0..<100 {
            if await condition() { return }
            await Task.yield()
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    // MARK: - Preference

    func testSideBySideDefaultsOffAndPersists() {
        XCTAssertFalse(state.sideBySideListsEnabled)
        XCTAssertEqual(state.visiblePanes.count, 1)
        XCTAssertTrue(state.visiblePanes[0] === state.primaryPane)

        state.sideBySideListsEnabled = true

        XCTAssertEqual(userDefaults.object(forKey: Constants.UserDefaults.sideBySideListsEnabledKey) as? Bool, true)
        XCTAssertEqual(state.visiblePanes.count, 2)
        XCTAssertTrue(state.visiblePanes[0] === state.primaryPane)
        XCTAssertTrue(state.visiblePanes[1] === state.secondaryPane)
    }

    func testInitialStateReadsStoredSideBySidePreference() {
        userDefaults.set(true, forKey: Constants.UserDefaults.sideBySideListsEnabledKey)
        let restored = makeState()
        XCTAssertTrue(restored.sideBySideListsEnabled)
        XCTAssertEqual(restored.visiblePanes.count, 2)
    }

    // MARK: - Secondary default list

    func testDefaultSecondaryListIsTheOneAfterThePrimaryWrappingAround() {
        let lists = ["a", "b", "c"].map { TaskList(id: $0, title: $0, selfLink: nil, updated: nil) }
        XCTAssertEqual(TaskListPane.defaultSecondaryListID(in: lists, after: "a"), "b")
        XCTAssertEqual(TaskListPane.defaultSecondaryListID(in: lists, after: "c"), "a")
        XCTAssertEqual(TaskListPane.defaultSecondaryListID(in: lists, after: nil), "a")
        XCTAssertEqual(TaskListPane.defaultSecondaryListID(in: lists, after: "unknown"), "a")
        XCTAssertEqual(TaskListPane.defaultSecondaryListID(in: [lists[0]], after: "a"), "a")
        XCTAssertNil(TaskListPane.defaultSecondaryListID(in: [], after: "a"))
    }

    func testEnablingSideBySideSelectsNextListAndLoadsIt() async {
        await signInAndLoad()
        XCTAssertEqual(state.primaryPane.selectedListId, "demo-today")
        let primaryTasks = state.primaryPane.tasks
        XCTAssertFalse(primaryTasks.isEmpty)
        XCTAssertNil(state.secondaryPane.selectedListId)

        state.sideBySideListsEnabled = true

        XCTAssertEqual(state.secondaryPane.selectedListId, "demo-work")
        await waitUntil { !self.state.secondaryPane.tasks.isEmpty }
        XCTAssertFalse(state.secondaryPane.tasks.isEmpty)
        XCTAssertTrue(state.secondaryPane.tasks.allSatisfy { $0.id.hasPrefix("work-") })
        XCTAssertEqual(state.primaryPane.selectedListId, "demo-today")
        XCTAssertEqual(state.primaryPane.tasks.map(\.id), primaryTasks.map(\.id))
        let listTasksListIDs = await api.listTasksListIDs
        XCTAssertTrue(listTasksListIDs.contains("demo-work"))
    }

    func testLoadTaskListsWithSideBySideOnFillsBothPanes() async {
        state.sideBySideListsEnabled = true
        await signInAndLoad()

        XCTAssertEqual(state.primaryPane.selectedListId, "demo-today")
        XCTAssertEqual(state.secondaryPane.selectedListId, "demo-work")
        XCTAssertFalse(state.primaryPane.tasks.isEmpty)
        XCTAssertFalse(state.secondaryPane.tasks.isEmpty)
        let listTasksListIDs = await api.listTasksListIDs
        XCTAssertEqual(Set(listTasksListIDs), ["demo-today", "demo-work"])
        XCTAssertEqual(listTasksListIDs.count, 2)
    }

    // MARK: - Refresh

    func testRefreshTasksLoadsEachDistinctVisibleListOnce() async {
        state.sideBySideListsEnabled = true
        await signInAndLoad()
        await api.clearLog()

        await state.refreshTasks()
        var listTasksListIDs = await api.listTasksListIDs
        XCTAssertEqual(listTasksListIDs.count, 2)
        XCTAssertEqual(Set(listTasksListIDs), ["demo-today", "demo-work"])

        await state.selectList("demo-today", in: state.secondaryPane)
        await api.clearLog()

        await state.refreshTasks()
        listTasksListIDs = await api.listTasksListIDs
        XCTAssertEqual(listTasksListIDs, ["demo-today"])
        XCTAssertEqual(state.secondaryPane.tasks.map(\.id), state.primaryPane.tasks.map(\.id))
    }

    // MARK: - Mutations

    func testMutationFansOutToEveryPaneShowingTheList() async {
        state.sideBySideListsEnabled = true
        await signInAndLoad()
        await state.selectList("demo-today", in: state.secondaryPane)

        let created = await state.addTask(title: "X", in: state.secondaryPane)

        XCTAssertNotNil(created)
        XCTAssertEqual(state.primaryPane.tasks.first?.title, "X")
        XCTAssertEqual(state.secondaryPane.tasks.first?.title, "X")
        XCTAssertEqual(state.tasks(in: "demo-today").first?.title, "X")
        XCTAssertEqual(state.primaryPane.tasks.map(\.id), state.secondaryPane.tasks.map(\.id))
    }

    func testMutationInSecondaryPaneTargetsItsOwnList() async {
        state.sideBySideListsEnabled = true
        await signInAndLoad()
        let primaryTasksBefore = state.primaryPane.tasks
        guard let workTask = state.secondaryPane.tasks.first(where: { !$0.isCompleted }) else {
            return XCTFail("secondary pane should show open work tasks")
        }

        await state.toggleTask(workTask, in: state.secondaryPane)

        XCTAssertEqual(state.secondaryPane.tasks.first { $0.id == workTask.id }?.isCompleted, true)
        let updateTaskListIDs = await api.updateTaskListIDs
        XCTAssertEqual(updateTaskListIDs.last, "demo-work")
        XCTAssertEqual(state.primaryPane.tasks.map(\.id), primaryTasksBefore.map(\.id))
    }

    func testLegacyMutationsDefaultToThePrimaryPane() async {
        state.sideBySideListsEnabled = true
        await signInAndLoad()
        let secondaryTasksBefore = state.secondaryPane.tasks

        await state.addTask(title: "Only here")

        XCTAssertEqual(state.primaryPane.tasks.first?.title, "Only here")
        XCTAssertEqual(state.secondaryPane.tasks.map(\.id), secondaryTasksBefore.map(\.id))
        XCTAssertFalse(state.secondaryPane.tasks.contains { $0.title == "Only here" })
    }

    func testSelectListInSecondaryPaneLeavesPrimaryAlone() async {
        state.sideBySideListsEnabled = true
        await signInAndLoad()

        await state.selectList("demo-personal", in: state.secondaryPane)

        XCTAssertEqual(state.secondaryPane.selectedListId, "demo-personal")
        XCTAssertTrue(state.secondaryPane.tasks.allSatisfy { $0.id.hasPrefix("personal-") })
        XCTAssertEqual(state.primaryPane.selectedListId, "demo-today")
        XCTAssertTrue(state.primaryPane.tasks.allSatisfy { $0.id.hasPrefix("today-") })
    }

    // MARK: - Loads

    func testStaleSecondaryLoadIsDroppedAfterSecondarySwitch() async {
        state.sideBySideListsEnabled = true
        await signInAndLoad()
        await api.setDelay(.milliseconds(150), forList: "demo-work")
        await state.selectList("demo-personal", in: state.secondaryPane)

        let slowSelect = Task { await state.selectList("demo-work", in: state.secondaryPane) }
        await Task.yield()
        await state.selectList("demo-personal", in: state.secondaryPane)
        await slowSelect.value

        XCTAssertEqual(state.secondaryPane.selectedListId, "demo-personal")
        XCTAssertFalse(state.secondaryPane.tasks.isEmpty)
        XCTAssertTrue(state.secondaryPane.tasks.allSatisfy { $0.id.hasPrefix("personal-") })
    }

    func testPaneLoadingFlagsAreIndependent() async {
        state.sideBySideListsEnabled = true
        await signInAndLoad()
        await api.setDelay(.milliseconds(120), forList: "demo-work")

        let refresh = Task { await state.refreshTasks(in: state.secondaryPane) }
        await waitUntil { self.state.secondaryPane.isLoading }

        XCTAssertTrue(state.secondaryPane.isLoading)
        XCTAssertFalse(state.primaryPane.isLoading)
        XCTAssertTrue(state.isLoading)

        await refresh.value
        XCTAssertFalse(state.secondaryPane.isLoading)
        XCTAssertFalse(state.primaryPane.isLoading)
        XCTAssertFalse(state.isLoading)
    }

    // MARK: - Hidden secondary pane

    func testSecondaryPaneRemembersItsSelectionWhileHidden() async {
        state.sideBySideListsEnabled = true
        await signInAndLoad()
        await state.selectList("demo-personal", in: state.secondaryPane)

        state.sideBySideListsEnabled = false
        XCTAssertEqual(state.visiblePanes.count, 1)
        XCTAssertEqual(state.secondaryPane.selectedListId, "demo-personal")
        await api.clearLog()

        state.sideBySideListsEnabled = true

        XCTAssertEqual(state.secondaryPane.selectedListId, "demo-personal")
        // The enable kicks off a refresh of the remembered list, not a re-default.
        await waitUntil { await !self.api.listTasksListIDs.isEmpty }
        await waitUntil { !self.state.secondaryPane.isLoading }
        let listTasksListIDs = await api.listTasksListIDs
        XCTAssertEqual(listTasksListIDs, ["demo-personal"])
        XCTAssertTrue(state.secondaryPane.tasks.allSatisfy { $0.id.hasPrefix("personal-") })
    }

    func testHiddenSecondaryPaneIsNotACommitTargetButIsReseededWhenShown() async {
        state.sideBySideListsEnabled = true
        await signInAndLoad()
        XCTAssertEqual(state.secondaryPane.selectedListId, "demo-work")

        state.sideBySideListsEnabled = false
        await state.selectList("demo-work", in: state.primaryPane)
        await state.addTask(title: "Y")

        XCTAssertEqual(state.primaryPane.tasks.first?.title, "Y")
        XCTAssertEqual(state.cachedTasks(forListID: "demo-work")?.first?.title, "Y")
        XCTAssertFalse(state.secondaryPane.tasks.contains { $0.title == "Y" })
        await api.clearLog()

        state.sideBySideListsEnabled = true

        XCTAssertEqual(state.secondaryPane.tasks.first?.title, "Y", "re-seeded from the cache immediately")
        await waitUntil { await !self.api.listTasksListIDs.isEmpty }
        await waitUntil { !self.state.secondaryPane.isLoading }
        XCTAssertEqual(state.secondaryPane.tasks.first?.title, "Y", "and still there after the refresh")
        XCTAssertEqual(state.secondaryPane.tasks.map(\.id), state.primaryPane.tasks.map(\.id))
    }

    // MARK: - Reset

    func testSignOutResetsBothPanes() async {
        state.sideBySideListsEnabled = true
        await signInAndLoad()
        XCTAssertNotNil(state.secondaryPane.selectedListId)

        state.signOut()

        for pane in [state.primaryPane, state.secondaryPane] {
            XCTAssertNil(pane.selectedListId)
            XCTAssertTrue(pane.tasks.isEmpty)
            XCTAssertFalse(pane.isLoading)
        }

        await signInAndLoad()
        XCTAssertEqual(state.primaryPane.selectedListId, "demo-today")
        XCTAssertEqual(state.secondaryPane.selectedListId, "demo-work")
    }

    func testExitDemoModeResetsSecondaryPane() async {
        state.sideBySideListsEnabled = true
        state.enterDemoMode()
        await waitUntil { !self.state.secondaryPane.tasks.isEmpty && !self.state.primaryPane.tasks.isEmpty }
        XCTAssertEqual(state.primaryPane.selectedListId, "demo-today")
        XCTAssertEqual(state.secondaryPane.selectedListId, "demo-work")

        state.exitDemoMode()

        XCTAssertNil(state.primaryPane.selectedListId)
        XCTAssertNil(state.secondaryPane.selectedListId)
        XCTAssertTrue(state.primaryPane.tasks.isEmpty)
        XCTAssertTrue(state.secondaryPane.tasks.isEmpty)
    }

    // MARK: - Notifications

    func testNotificationSyncCoversEveryVisibleList() async {
        state.sideBySideListsEnabled = true
        await signInAndLoad()

        let syncCalls = await dueDateNotificationService.syncCalls
        let syncedListIDs = Set(syncCalls.map(\.list.id))
        XCTAssertTrue(syncedListIDs.isSuperset(of: ["demo-today", "demo-work"]))
        let todaySync = syncCalls.last { $0.list.id == "demo-today" }
        let workSync = syncCalls.last { $0.list.id == "demo-work" }
        XCTAssertEqual(todaySync?.tasks.map(\.id), state.primaryPane.tasks.map(\.id))
        XCTAssertEqual(workSync?.tasks.map(\.id), state.secondaryPane.tasks.map(\.id))
    }

    /// A pane's list is synced from what that pane knows. Before its first
    /// fetch lands the pane holds an empty placeholder, which must never reach
    /// the notification service: a sync of an empty array removes the list's
    /// pending and delivered reminders and forgets what already fired, so the
    /// real load moments later would re-fire every overdue reminder.
    func testUnfetchedPaneListIsNeverSyncedFromItsEmptyPlaceholder() async {
        state.sideBySideListsEnabled = true
        await api.setDelay(.milliseconds(150), forList: "demo-work")

        // The primary's load lands first and syncs every visible list; the
        // secondary's list waits for its own fetch.
        await signInAndLoad()

        let workSyncs = await dueDateNotificationService.syncCalls.filter { $0.list.id == "demo-work" }
        XCTAssertFalse(workSyncs.isEmpty, "the secondary's own load syncs its list")
        XCTAssertTrue(workSyncs.allSatisfy { !$0.tasks.isEmpty }, "never synced as empty: \(workSyncs.map(\.tasks.count))")
        XCTAssertEqual(workSyncs.first?.tasks.map(\.id), state.secondaryPane.tasks.map(\.id))
    }

    func testMutationWhileTheOtherPaneStillLoadsDoesNotSyncItsListAsEmpty() async {
        await signInAndLoad()
        await api.setDelay(.milliseconds(400), forList: "demo-work")

        state.sideBySideListsEnabled = true
        await waitUntil { self.state.secondaryPane.isLoading }
        XCTAssertTrue(state.secondaryPane.tasks.isEmpty, "placeholder until the load lands")

        // A primary-pane mutation syncs every visible list; the secondary's
        // list has never been fetched, so it is skipped rather than emptied.
        await state.addTask(title: "X")

        let workSyncsDuringLoad = await dueDateNotificationService.syncCalls.filter { $0.list.id == "demo-work" }
        XCTAssertTrue(workSyncsDuringLoad.isEmpty, "synced as: \(workSyncsDuringLoad.map(\.tasks.count))")

        // Once the list has actually been fetched, it is synced like any other.
        await waitUntil { !self.state.secondaryPane.isLoading }
        await state.refreshTasks(in: state.secondaryPane)
        let workSyncs = await dueDateNotificationService.syncCalls.filter { $0.list.id == "demo-work" }
        XCTAssertFalse(workSyncs.isEmpty)
        XCTAssertTrue(workSyncs.allSatisfy { !$0.tasks.isEmpty })
        XCTAssertEqual(workSyncs.last?.tasks.map(\.id), state.secondaryPane.tasks.map(\.id))
    }

    // MARK: - Forwarders

    func testLegacyAccessorsMirrorThePrimaryPane() {
        let task = makeTask(id: "t", title: "T")
        state.tasks = [task]
        XCTAssertEqual(state.primaryPane.tasks.map(\.id), [task.id])
        state.selectedListId = "x"
        XCTAssertEqual(state.primaryPane.selectedListId, "x")
        state.searchText = "query"
        XCTAssertEqual(state.primaryPane.searchText, "query")
        XCTAssertTrue(state.isSearching)
        state.collapsedTaskIDs = ["t"]
        XCTAssertEqual(state.primaryPane.collapsedTaskIDs, ["t"])
        XCTAssertEqual(state.rootTasks.map(\.id), state.rootTasks(in: state.primaryPane).map(\.id))
        XCTAssertEqual(state.selectedList?.id, state.selectedList(in: state.primaryPane)?.id)
        XCTAssertTrue(state.secondaryPane.tasks.isEmpty)
    }

    // MARK: - Move between lists

    func testMovingATaskToTheOtherPanesListShowsItThere() async {
        state.sideBySideListsEnabled = true
        await signInAndLoad()
        guard let todayTask = state.primaryPane.tasks.first(where: { $0.parent == nil && !$0.isCompleted }) else {
            return XCTFail("primary pane should show a top-level task")
        }

        await state.moveTask(todayTask, toList: "demo-work", from: state.primaryPane)

        XCTAssertFalse(state.primaryPane.tasks.contains { $0.id == todayTask.id })
        XCTAssertEqual(state.secondaryPane.tasks.first?.id, todayTask.id)
        XCTAssertNil(state.errorMessage)
    }

    // MARK: - Deleted Lists

    /// Deleting the shown list on the website used to leave the pane asking for
    /// it until the app was relaunched; the 404 now re-reads the lists.
    func testListDeletedOnTheServerMovesThePaneToASurvivingList() async {
        await signInAndLoad()
        XCTAssertEqual(state.primaryPane.selectedListId, "demo-today")

        await api.deleteListOnServer("demo-today")
        await state.refreshTasks()

        XCTAssertFalse(state.taskLists.contains { $0.id == "demo-today" })
        XCTAssertEqual(state.primaryPane.selectedListId, "demo-work")
        XCTAssertNil(state.errorMessage, "recovering is not an error the user has to see")
    }

    /// The recovery reloads the lists, which loads tasks again; a second 404
    /// must not send it round the loop.
    func testEveryListDeletedLeavesNoSelectionAndNoRecursion() async {
        await signInAndLoad()
        for listID in ["demo-today", "demo-work", "demo-personal"] {
            await api.deleteListOnServer(listID)
        }

        await state.refreshTasks()

        XCTAssertTrue(state.taskLists.isEmpty)
        XCTAssertNil(state.primaryPane.selectedListId)
        XCTAssertTrue(state.primaryPane.tasks.isEmpty)
    }

    // MARK: - Restored Across Launches

    func testEachPaneReopensOnTheListItLastShowed() async {
        await signInAndLoad()
        state.sideBySideListsEnabled = true
        await state.selectList("demo-personal")
        await state.selectList("demo-work", in: state.secondaryPane)

        let relaunched = makeState()

        XCTAssertEqual(relaunched.primaryPane.selectedListId, "demo-personal")
        XCTAssertEqual(relaunched.secondaryPane.selectedListId, "demo-work")
    }

    /// A stored list the account no longer has must not survive the first load.
    func testRestoredListThatNoLongerExistsIsDropped() async {
        await signInAndLoad()
        await state.selectList("demo-personal")

        await api.deleteListOnServer("demo-personal")
        let relaunched = makeState()
        XCTAssertEqual(relaunched.primaryPane.selectedListId, "demo-personal")

        relaunched.isSignedIn = true
        await relaunched.loadTaskLists()

        XCTAssertEqual(relaunched.primaryPane.selectedListId, "demo-today")
    }

    func testSignOutForgetsTheStoredLists() async {
        await signInAndLoad()
        await state.selectList("demo-personal")

        state.signOut()

        XCTAssertNil(makeState().primaryPane.selectedListId)
    }

    // MARK: - Per-Pane Sort Order

    /// Both panes show `demo-today`, so only the sort can explain a different
    /// first row: `today-invoice` is the list's one overdue root task.
    func testEachPaneSortsIndependentlyAndRemembersItsOrder() async {
        await signInAndLoad()
        state.sideBySideListsEnabled = true
        await state.selectList("demo-today", in: state.secondaryPane)

        state.setSortOrder(.dueDate, in: state.secondaryPane)

        XCTAssertEqual(state.primaryPane.sortOrder, .myOrder)
        XCTAssertEqual(state.rootTasks(in: state.primaryPane).first?.id, "today-standup")
        XCTAssertEqual(state.rootTasks(in: state.secondaryPane).first?.id, "today-invoice")

        let relaunched = makeState()
        XCTAssertEqual(relaunched.primaryPane.sortOrder, .myOrder)
        XCTAssertEqual(relaunched.secondaryPane.sortOrder, .dueDate)
    }

    /// Dragging maps drop indices back to Google positions, so it is gated per
    /// pane rather than for the whole popover.
    func testDraggingIsGatedPerPane() async {
        await signInAndLoad()
        state.sideBySideListsEnabled = true

        state.setSortOrder(.dueDate, in: state.secondaryPane)

        XCTAssertTrue(state.canReorderTasks(in: state.primaryPane))
        XCTAssertFalse(state.canReorderTasks(in: state.secondaryPane))
        XCTAssertTrue(state.canReorderTasks, "the bare property still reads the primary pane")
    }
}

/// Wraps `DemoTasksAPI`, recording which lists `listTasks`/`updateTask` were
/// called for, honouring a per-list `listTasks` delay, and able to make a list
/// disappear the way deleting it on the Google Tasks website does.
private actor RecordingTasksAPI: TasksAPIProtocol {
    private let wrapped = DemoTasksAPI()
    private(set) var listTasksListIDs: [String] = []
    private(set) var updateTaskListIDs: [String] = []
    private var delaysByListID: [String: Duration] = [:]
    private var deletedListIDs: Set<String> = []

    /// Drops `listID` from `listTaskLists()` and makes its tasks 404, like a
    /// list deleted elsewhere while the app was running.
    func deleteListOnServer(_ listID: String) {
        deletedListIDs.insert(listID)
    }

    func clearLog() {
        listTasksListIDs = []
        updateTaskListIDs = []
    }

    func setDelay(_ delay: Duration, forList listID: String) {
        delaysByListID[listID] = delay
    }

    func listTaskLists() async throws -> [TaskList] {
        try await wrapped.listTaskLists().filter { !deletedListIDs.contains($0.id) }
    }

    func createTaskList(title: String) async throws -> TaskList {
        try await wrapped.createTaskList(title: title)
    }

    func listTasks(listId: String, showCompleted: Bool, showHidden: Bool) async throws -> [TaskItem] {
        listTasksListIDs.append(listId)
        if deletedListIDs.contains(listId) {
            throw APIError.serverError(404, "Not Found")
        }
        // Snapshot before the delay, like a server responding to the request
        // as it arrived.
        let tasks = try await wrapped.listTasks(listId: listId, showCompleted: showCompleted, showHidden: showHidden)
        if let delay = delaysByListID[listId] {
            try? await Task.sleep(for: delay)
        }
        return tasks
    }

    func createTask(listId: String, title: String, notes: String?, due: String?, parentId: String?) async throws -> TaskItem {
        try await wrapped.createTask(listId: listId, title: title, notes: notes, due: due, parentId: parentId)
    }

    func updateTask(listId: String, taskId: String, task: TaskItem) async throws -> TaskItem {
        updateTaskListIDs.append(listId)
        return try await wrapped.updateTask(listId: listId, taskId: taskId, task: task)
    }

    func deleteTask(listId: String, taskId: String) async throws {
        try await wrapped.deleteTask(listId: listId, taskId: taskId)
    }

    func moveTask(
        listId: String,
        taskId: String,
        parentId: String?,
        previousTaskId: String?,
        destinationListId: String?
    ) async throws -> TaskItem {
        try await wrapped.moveTask(
            listId: listId,
            taskId: taskId,
            parentId: parentId,
            previousTaskId: previousTaskId,
            destinationListId: destinationListId
        )
    }
}
