import XCTest
@testable import TaskMenu

/// `AppState`'s widget-snapshot publishing: every convergence point
/// (bootstrap/list load, selected-list load, account-wide load, task
/// mutations including rollback, list creation, deleted-list recovery,
/// selection change, sign-out/disconnect), demo mode never reaching a
/// production publisher, and the cross-process stale-write protection
/// `TaskWidgetSnapshotStore.replaceList(_:requestStartedAt:)` provides.
///
/// Most tests inject `RecordingTaskWidgetSnapshotPublisher`, a fast in-memory
/// double, and assert on the calls `AppState` made. Two tests
/// (`testStaleInFlightResponseDoesNotOverwriteNewerCrossProcessPublish` and
/// `testPublishedListContainsOnlyOpenTasksNoNotesNoEmail`) need the real
/// store-backed `TaskWidgetSnapshotPublisher` to prove store-level behavior,
/// so they construct one pointed at a temporary directory — never the real
/// App Group container.
@MainActor
final class AppStateWidgetPublishingTests: XCTestCase {
    private var userDefaults: UserDefaults!
    private var userDefaultsSuiteName: String!
    private var dueDateNotificationService: TestDueDateNotificationService!
    private var api: WidgetPublishingFakeTasksAPI!
    private var publisher: RecordingTaskWidgetSnapshotPublisher!
    private var state: AppState!

    private let listA = TaskList(id: "list-a", title: "List A", selfLink: nil, updated: nil)
    private let listB = TaskList(id: "list-b", title: "List B", selfLink: nil, updated: nil)

    override func setUp() async throws {
        userDefaultsSuiteName = "dev.crazytan.TaskMenu.tests.widgetpublishing.\(UUID().uuidString)"
        userDefaults = UserDefaults(suiteName: userDefaultsSuiteName)
        userDefaults.removePersistentDomain(forName: userDefaultsSuiteName)
        dueDateNotificationService = TestDueDateNotificationService()
        api = WidgetPublishingFakeTasksAPI(taskLists: [listA, listB])
        publisher = RecordingTaskWidgetSnapshotPublisher()
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
        publisher = nil
        state = nil
    }

    // MARK: - Helpers

    private func makeState(widgetSnapshotPublisher: (any TaskWidgetSnapshotPublishing)? = nil) -> AppState {
        AppState(
            authService: GoogleAuthService(keychain: InMemoryKeychainService()),
            api: api,
            userDefaults: userDefaults,
            dueDateNotificationService: dueDateNotificationService,
            widgetSnapshotPublisher: widgetSnapshotPublisher ?? publisher
        )
    }

    /// Signs in without a real OAuth round trip, like the rest of the test
    /// suite (`SideBySidePanesTests.signInAndLoad()`): `AppState.isSignedIn`
    /// is a plain settable property.
    private func signInAndLoad() async {
        state.isSignedIn = true
        await state.loadTaskLists()
    }

    private func makeTask(
        id: String,
        title: String = "Task",
        status: TaskItem.TaskStatus = .needsAction,
        parent: String? = nil,
        position: String? = nil,
        notes: String? = nil
    ) -> TaskItem {
        TaskItem(
            id: id,
            title: title,
            notes: notes,
            status: status,
            due: nil,
            selfLink: nil,
            parent: parent,
            position: position,
            updated: nil
        )
    }

    private func makeTempDirectoryStore() -> (store: TaskWidgetSnapshotStore, directory: URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AppStateWidgetPublishingTests-\(UUID().uuidString)")
        return (TaskWidgetSnapshotStore(directoryURL: directory), directory)
    }

    private func waitUntil(_ condition: @MainActor @escaping () -> Bool) async {
        for _ in 0..<100 {
            if condition() { return }
            await Task.yield()
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    private func containsCatalogCall(
        in calls: [RecordingTaskWidgetSnapshotPublisher.Call],
        where predicate: (TaskWidgetAuthenticationState, [String], String?) -> Bool
    ) -> Bool {
        calls.contains {
            if case let .catalog(authentication, listIDs, defaultListID) = $0 {
                return predicate(authentication, listIDs, defaultListID)
            }
            return false
        }
    }

    private func containsListCall(
        in calls: [RecordingTaskWidgetSnapshotPublisher.Call],
        where predicate: (String, [String]) -> Bool
    ) -> Bool {
        calls.contains {
            if case let .list(id, _, taskIDs, _) = $0 {
                return predicate(id, taskIDs)
            }
            return false
        }
    }

    private func containsDefaultListIDCall(in calls: [RecordingTaskWidgetSnapshotPublisher.Call], _ id: String?) -> Bool {
        calls.contains {
            if case .defaultListID(id) = $0 { return true }
            return false
        }
    }

    private func containsClearCall(in calls: [RecordingTaskWidgetSnapshotPublisher.Call]) -> Bool {
        calls.contains {
            if case .clear = $0 { return true }
            return false
        }
    }

    // MARK: - Bootstrap / list load

    func testBootstrapPublishesCatalogAndSelectedListTasks() async {
        await api.setTasks([makeTask(id: "a1"), makeTask(id: "a2")], for: listA.id)

        await signInAndLoad()

        XCTAssertTrue(containsCatalogCall(in: publisher.calls) { authentication, listIDs, defaultListID in
            authentication == .signedIn && listIDs == [listA.id, listB.id] && defaultListID == listA.id
        })
        XCTAssertTrue(containsListCall(in: publisher.calls) { id, taskIDs in
            id == listA.id && taskIDs == ["a1", "a2"]
        })
    }

    func testLoadTaskListsRepublishesCatalogWhenListSetChanges() async {
        await signInAndLoad()
        publisher.reset()

        await api.removeList(listB.id)
        await state.loadTaskLists()

        XCTAssertTrue(containsCatalogCall(in: publisher.calls) { _, listIDs, _ in
            listIDs == [listA.id]
        })
    }

    // MARK: - Selected-list load

    func testSelectingAListPublishesItsTasks() async {
        await api.setTasks([makeTask(id: "b1")], for: listB.id)
        await signInAndLoad()
        publisher.reset()

        await state.selectList(listB.id)

        XCTAssertTrue(containsListCall(in: publisher.calls) { id, taskIDs in
            id == listB.id && taskIDs == ["b1"]
        })
        XCTAssertTrue(containsDefaultListIDCall(in: publisher.calls, listB.id))
    }

    // MARK: - Account-wide load

    func testAccountWideMenuBarSweepPublishesEveryOtherList() async {
        await api.setTasks([makeTask(id: "b1")], for: listB.id)
        state.menuBarCounterMode = .openTasks
        defer { state.menuBarCounterMode = .off }

        await signInAndLoad()
        await waitUntil {
            self.containsListCall(in: self.publisher.calls) { id, taskIDs in
                id == self.listB.id && taskIDs == ["b1"]
            }
        }

        XCTAssertTrue(containsListCall(in: publisher.calls) { id, taskIDs in
            id == listB.id && taskIDs == ["b1"]
        })
    }

    // MARK: - Task mutations

    func testAddTaskPublishesTheUpdatedList() async {
        await signInAndLoad()
        publisher.reset()

        let created = await state.addTask(title: "New task")

        XCTAssertNotNil(created)
        XCTAssertTrue(containsListCall(in: publisher.calls) { id, taskIDs in
            id == listA.id && taskIDs.contains(created?.id ?? "")
        })
    }

    func testAddSubtaskPublishesTheUpdatedList() async {
        await api.setTasks([makeTask(id: "parent1")], for: listA.id)
        await signInAndLoad()
        publisher.reset()

        let created = await state.addSubtask(title: "Sub", parentId: "parent1")

        XCTAssertNotNil(created)
        XCTAssertTrue(containsListCall(in: publisher.calls) { id, taskIDs in
            id == listA.id && taskIDs.contains(created?.id ?? "") && taskIDs.contains("parent1")
        })
    }

    func testCompletingATaskPublishesTheCommittedList() async {
        await api.setTasks([makeTask(id: "t1")], for: listA.id)
        await signInAndLoad()
        publisher.reset()

        await state.toggleTask(state.tasks[0])

        XCTAssertTrue(state.tasks[0].isCompleted)
        // publishListToWidget hands the publisher the full committed array
        // (including completed tasks); filtering to open-only is the
        // production publisher's job, verified separately in
        // `testPublishedListContainsOnlyOpenTasksNoNotesNoEmail`. Here we
        // only need proof AppState re-published the list after the commit.
        XCTAssertTrue(containsListCall(in: publisher.calls) { id, taskIDs in
            id == listA.id && taskIDs == ["t1"]
        })
        XCTAssertEqual(publisher.lastPublishedTasksByListID[listA.id]?.first?.isCompleted, true)
    }

    func testCompletionRollbackRepublishesTheRevertedTask() async {
        await api.setTasks([makeTask(id: "t1")], for: listA.id)
        await api.setUpdateTaskError(.serverError(500, "boom"), for: "t1")
        await signInAndLoad()
        publisher.reset()

        await state.toggleTask(state.tasks[0])

        XCTAssertFalse(state.tasks[0].isCompleted)
        // Two commits for the list: the optimistic completion, then the
        // rollback. `lastPublishedTasksByListID` holds whatever the most
        // recent of those two published, which must be the reverted state.
        let listPublishCount = publisher.calls.filter {
            if case let .list(id, _, _, _) = $0 { return id == listA.id }
            return false
        }.count
        XCTAssertEqual(listPublishCount, 2)
        XCTAssertEqual(publisher.lastPublishedTasksByListID[listA.id]?.first?.isCompleted, false)
    }

    func testEditingATaskPublishesTheUpdatedTitle() async {
        await api.setTasks([makeTask(id: "t1", title: "Old")], for: listA.id)
        await signInAndLoad()
        publisher.reset()

        var edited = state.tasks[0]
        edited.title = "New"
        await state.updateTask(edited)

        XCTAssertEqual(publisher.lastPublishedTasksByListID[listA.id]?.first(where: { $0.id == "t1" })?.title, "New")
    }

    func testDeletingATaskPublishesItsRemoval() async {
        await api.setTasks([makeTask(id: "t1"), makeTask(id: "t2")], for: listA.id)
        await signInAndLoad()
        publisher.reset()

        await state.deleteTask(state.tasks[0])

        XCTAssertEqual(publisher.lastPublishedTasksByListID[listA.id]?.map(\.id), ["t2"])
    }

    func testReorderingPublishesTheNewOrder() async {
        await api.setTasks([makeTask(id: "t1"), makeTask(id: "t2")], for: listA.id)
        await signInAndLoad()
        publisher.reset()

        // Move t2 to the front.
        await state.moveTask(state.tasks[1], toParent: nil, after: nil)

        // The published payload is the raw committed array (storage order,
        // like `pane.tasks`), not visual order — `position` carries the
        // order, exactly as `TaskWidgetProjection` (and `rootTasks`) expect
        // to read it. Sort by Google position, the way both of those do, to
        // check the move actually landed.
        let published = publisher.lastPublishedTasksByListID[listA.id] ?? []
        XCTAssertEqual(tasksSortedByGooglePosition(published).map(\.id), ["t2", "t1"])
    }

    // MARK: - Cross-list move and rollback

    func testCrossListMovePublishesBothLists() async {
        await api.setTasks([makeTask(id: "t1")], for: listA.id)
        await signInAndLoad()
        publisher.reset()

        await state.moveTask(state.tasks[0], toList: listB.id)

        XCTAssertTrue(containsListCall(in: publisher.calls) { id, taskIDs in id == listA.id && !taskIDs.contains("t1") })
        XCTAssertTrue(containsListCall(in: publisher.calls) { id, taskIDs in id == listB.id && taskIDs.contains("t1") })
    }

    func testCrossListMoveRollbackRepublishesBothOriginalLists() async {
        await api.setTasks([makeTask(id: "t1")], for: listA.id)
        await api.setMoveTaskFailure(.serverError(500, "boom"))
        await signInAndLoad()
        publisher.reset()

        await state.moveTask(state.tasks[0], toList: listB.id)

        XCTAssertEqual(publisher.lastPublishedTasksByListID[listA.id]?.map(\.id), ["t1"])
        XCTAssertEqual(publisher.lastPublishedTasksByListID[listB.id]?.map(\.id), [])
    }

    // MARK: - List creation

    func testCreatingAListPublishesTheCatalogAndItsEmptyTasks() async {
        await signInAndLoad()
        publisher.reset()

        let created = await state.createTaskList(title: "New List")

        XCTAssertNotNil(created)
        guard let created else { return }
        XCTAssertTrue(containsCatalogCall(in: publisher.calls) { _, listIDs, _ in listIDs.contains(created.id) })
        XCTAssertTrue(containsListCall(in: publisher.calls) { id, taskIDs in id == created.id && taskIDs.isEmpty })
    }

    // MARK: - Deleted-list (404) recovery

    func testMissingListRecoveryRepublishesTheCatalogWithoutTheDeletedList() async {
        await signInAndLoad()
        publisher.reset()

        await api.removeList(listA.id)
        await state.refreshTasks()

        XCTAssertTrue(containsCatalogCall(in: publisher.calls) { _, listIDs, _ in
            !listIDs.contains(listA.id) && listIDs.contains(listB.id)
        })
    }

    // MARK: - Selection change

    func testSelectionChangePublishesTheNewDefaultListID() async {
        await signInAndLoad()
        publisher.reset()

        await state.selectList(listB.id)

        XCTAssertTrue(containsDefaultListIDCall(in: publisher.calls, listB.id))
    }

    func testSecondaryPaneSelectionNeverPublishesDefaultListID() async {
        await signInAndLoad()
        publisher.reset()

        state.sideBySideListsEnabled = true
        await waitUntil { self.state.secondaryPane.selectedListId != nil }

        XCTAssertFalse(publisher.calls.contains {
            if case .defaultListID = $0 { return true }
            return false
        })
    }

    // MARK: - Sign-out / disconnect

    func testSignOutClearsTheWidgetSnapshot() async {
        await signInAndLoad()
        publisher.reset()

        state.signOut()

        XCTAssertTrue(containsClearCall(in: publisher.calls))
    }

    func testDisconnectClearsTheWidgetSnapshot() async {
        await signInAndLoad()
        publisher.reset()

        await state.disconnectGoogleAccount()

        XCTAssertTrue(containsClearCall(in: publisher.calls))
    }

    // MARK: - Demo mode

    func testDemoModeNeverPublishesToTheInjectedPublisher() async {
        state.enterDemoMode()
        await waitUntil { !self.state.taskLists.isEmpty }

        _ = await state.addTask(title: "Demo task")
        await state.selectList(state.taskLists.last?.id ?? "")

        XCTAssertTrue(publisher.calls.isEmpty)
    }

    func testExitingDemoModeStillClearsTheSnapshot() async {
        state.enterDemoMode()
        await waitUntil { !self.state.taskLists.isEmpty }
        publisher.reset()

        state.exitDemoMode()

        XCTAssertTrue(containsClearCall(in: publisher.calls))
    }

    // MARK: - Stale-write protection (real store, temporary directory)

    /// Proves `AppState` captures the network request's *start* time (not
    /// its completion time) and passes it through to
    /// `TaskWidgetSnapshotStore.replaceList(_:requestStartedAt:)`, so a
    /// fetch that began before another process's (the widget extension's)
    /// newer publish — but finishes later — cannot overwrite it. The other
    /// process is simulated by writing the same temporary-directory store
    /// directly while `AppState`'s fetch is still in flight; the generation
    /// guard `AppState` uses for its own in-process state cannot catch this,
    /// since nothing changed within this `AppState` instance — only the
    /// store's own timestamp comparison can.
    func testStaleInFlightResponseDoesNotOverwriteNewerCrossProcessPublish() async throws {
        let (store, directory) = makeTempDirectoryStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let storeBackedPublisher = TaskWidgetSnapshotPublisher(store: store)

        let delayedAPI = WidgetPublishingFakeTasksAPI(taskLists: [listA])
        await delayedAPI.setTasks([makeTask(id: "old1")], for: listA.id)
        // A gate, not a fixed delay: `AppState.loadTasks(for:into:)` captures
        // its `requestStartedAt` before calling `listTasks`, so once the
        // fake signals "started" that timestamp already exists and is
        // strictly earlier than anything `Date()` produces afterwards —
        // deterministic ordering with no sleep-based guessing (see
        // CONTRACT.md: "Add deterministic tests in which responses finish
        // out of order").
        let gate = await delayedAPI.armGate(for: listA.id)

        let raceState = AppState(
            authService: GoogleAuthService(keychain: InMemoryKeychainService()),
            api: delayedAPI,
            userDefaults: userDefaults,
            dueDateNotificationService: dueDateNotificationService,
            widgetSnapshotPublisher: storeBackedPublisher
        )
        raceState.isSignedIn = true

        let staleLoad = Task { await raceState.loadTaskLists() }
        await gate.waitUntilStarted()
        // The gate guarantees the stale request's `requestStartedAt` was
        // already captured, strictly before this point in wall-clock time.
        // `TaskWidgetSnapshotStore` round-trips `refreshedAt`/
        // `refreshStartedAt` at sub-second precision (`.secondsSince1970`),
        // so that ordering survives persistence without needing to pad past
        // a whole second here — unlike an earlier version of this test,
        // written against the store's previous whole-second-only `.iso8601`
        // encoding, which could make two timestamps captured milliseconds
        // apart decode as equal.

        // Simulate the widget extension (a different process, here just a
        // second store instance over the same directory) publishing fresher
        // content for the same list while the stale request above is still
        // in flight.
        let newerList = TaskWidgetListSnapshot(
            id: listA.id,
            title: listA.title,
            refreshedAt: Date(),
            refreshStartedAt: Date(),
            tasks: [TaskWidgetTaskSnapshot(id: "fromWidget", title: "From widget", status: .needsAction)]
        )
        XCTAssertTrue(try store.replaceList(newerList, requestStartedAt: Date()))

        await gate.release()
        await staleLoad.value

        let storedList = store.read().lists.first { $0.id == listA.id }
        XCTAssertEqual(storedList?.tasks.map(\.id), ["fromWidget"])
    }

    // MARK: - Published content: open-only, no notes/email (real store)

    func testPublishedListContainsOnlyOpenTasksNoNotesNoEmail() async throws {
        let (store, directory) = makeTempDirectoryStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let storeBackedPublisher = TaskWidgetSnapshotPublisher(store: store)

        let secretNote = "super-secret-note-\(UUID().uuidString)"
        let secretEmail = "secret-user-\(UUID().uuidString)@example.com"
        let contentAPI = WidgetPublishingFakeTasksAPI(taskLists: [listA])
        await contentAPI.setTasks(
            [makeTask(id: "open1", notes: secretNote), makeTask(id: "done1", status: .completed)],
            for: listA.id
        )

        let contentState = AppState(
            authService: GoogleAuthService(keychain: InMemoryKeychainService()),
            api: contentAPI,
            userDefaults: userDefaults,
            dueDateNotificationService: dueDateNotificationService,
            widgetSnapshotPublisher: storeBackedPublisher
        )
        contentState.isSignedIn = true
        contentState.googleAccountProfile = GoogleAccountProfile(email: secretEmail)

        await contentState.loadTaskLists()

        let storedList = store.read().lists.first { $0.id == listA.id }
        XCTAssertEqual(storedList?.tasks.map(\.id), ["open1"])

        let rawContents = try String(
            contentsOf: directory.appendingPathComponent(TaskWidgetConstants.snapshotFileName),
            encoding: .utf8
        )
        XCTAssertFalse(rawContents.contains(secretNote))
        XCTAssertFalse(rawContents.contains(secretEmail))
        XCTAssertFalse(rawContents.lowercased().contains("notes"))
    }

    // MARK: - Default publisher safety (no test touches the real App Group)

    /// The primary, unconditional guarantee: `TaskWidgetSnapshotPublisher()`
    /// — the default `AppState.init` uses in production — never resolves a
    /// real App Group container while running under XCTest, because its
    /// default initializer checks `ProcessInfo.processInfo.environment
    /// ["XCTestConfigurationFilePath"]` (the same mechanism
    /// `KeychainService`/`TaskMenuApp.isUnitTesting` use) and substitutes a
    /// store with no directory when set. This holds regardless of whether
    /// `SharedConstants.appGroupIdentifier` resolves to a real value in this
    /// build/signing configuration — unlike an incidental "it happens to be
    /// nil under the unsigned CI build" check, it keeps holding once the
    /// owner registers the App Group and tests run against a signed host.
    func testDefaultProductionPublisherNeverReachesRealContainerUnderXCTest() {
        XCTAssertNil(TaskWidgetSnapshotPublisher().store.directoryURL)

        // Secondary, build-configuration-dependent fact, kept as a sanity
        // check on *this* run rather than the guarantee itself.
        XCTAssertNil(SharedConstants.appGroupIdentifier)
    }
}

// MARK: - Test doubles

/// Records every call `AppState` makes without touching any file system
/// location, real or temporary. `@unchecked Sendable` because every call
/// this test suite makes to it happens on the main actor (from `AppState`
/// itself or directly from a `@MainActor` test method); nothing here is
/// accessed from a background thread.
final class RecordingTaskWidgetSnapshotPublisher: TaskWidgetSnapshotPublishing, @unchecked Sendable {
    enum Call {
        case catalog(authentication: TaskWidgetAuthenticationState, listIDs: [String], defaultListID: String?)
        case list(id: String, title: String, taskIDs: [String], requestStartedAt: Date)
        case defaultListID(String?)
        case clear
    }

    private(set) var calls: [Call] = []
    /// Most recent full `tasks` payload `AppState` handed `publishList` for
    /// each list id, for tests that need task content (title, completion
    /// status) rather than just the id list `Call.list` records.
    private(set) var lastPublishedTasksByListID: [String: [TaskItem]] = [:]

    func reset() {
        calls = []
        lastPublishedTasksByListID = [:]
    }

    func publishCatalog(authentication: TaskWidgetAuthenticationState, lists: [TaskList], defaultListID: String?) {
        calls.append(.catalog(authentication: authentication, listIDs: lists.map(\.id), defaultListID: defaultListID))
    }

    func publishList(id: String, title: String, tasks: [TaskItem], requestStartedAt: Date) {
        calls.append(.list(id: id, title: title, taskIDs: tasks.map(\.id), requestStartedAt: requestStartedAt))
        lastPublishedTasksByListID[id] = tasks
    }

    func setDefaultListID(_ id: String?) {
        calls.append(.defaultListID(id))
    }

    func clear() {
        calls.append(.clear)
    }
}

/// Minimal controllable `TasksAPIProtocol` fake for widget-publishing tests:
/// configurable per-list tasks, an optional per-list `listTasks` delay (for
/// the out-of-order stale-write test), a settable `updateTask`/`moveTask`
/// failure, and `removeList(_:)` to simulate a list deleted server-side
/// (subsequent `listTasks` calls for it throw 404, like `RecordingTasksAPI`
/// and `DelayedTasksAPI` in `SideBySidePanesTests.swift` /
/// `AppStateBehaviorTests.swift`, which this mirrors but does not share —
/// both are private to their own files).
private actor WidgetPublishingFakeTasksAPI: TasksAPIProtocol {
    private var taskLists: [TaskList]
    private var tasksByListID: [String: [TaskItem]] = [:]
    private var delaysByListID: [String: Duration] = [:]
    private var gatesByListID: [String: RequestGate] = [:]
    private var listTasksErrorsByListID: [String: APIError] = [:]
    private var updateTaskErrorsByTaskID: [String: APIError] = [:]
    private var moveTaskError: APIError?
    private var createTaskListCounter = 0
    private var createTaskCounter = 0

    init(taskLists: [TaskList]) {
        self.taskLists = taskLists
    }

    func setTasks(_ tasks: [TaskItem], for listID: String) {
        tasksByListID[listID] = tasks
    }

    func setDelay(_ delay: Duration, for listID: String) {
        delaysByListID[listID] = delay
    }

    /// Makes the next `listTasks(listId:)` call for `listID` block (after
    /// entering the method — i.e. after its caller already captured its own
    /// "request started" timestamp) until the test calls `release()` on the
    /// returned gate. Lets a test observe "the request has started" and then
    /// deterministically sequence what happens next, instead of guessing
    /// with `Task.sleep`.
    func armGate(for listID: String) -> RequestGate {
        let gate = RequestGate()
        gatesByListID[listID] = gate
        return gate
    }

    func setUpdateTaskError(_ error: APIError, for taskID: String) {
        updateTaskErrorsByTaskID[taskID] = error
    }

    func setMoveTaskFailure(_ error: APIError) {
        moveTaskError = error
    }

    /// Removes `listID` from the catalog and makes its tasks 404, like a
    /// list deleted elsewhere while the app was running.
    func removeList(_ listID: String) {
        taskLists.removeAll { $0.id == listID }
        listTasksErrorsByListID[listID] = .serverError(404, "Not Found")
    }

    func listTaskLists() async throws -> [TaskList] {
        taskLists
    }

    func createTaskList(title: String) async throws -> TaskList {
        createTaskListCounter += 1
        let list = TaskList(id: "created-list-\(createTaskListCounter)", title: title, selfLink: nil, updated: nil)
        taskLists.append(list)
        tasksByListID[list.id] = []
        return list
    }

    func listTasks(listId: String, showCompleted: Bool, showHidden: Bool) async throws -> [TaskItem] {
        let tasks = tasksByListID[listId] ?? []
        if let gate = gatesByListID[listId] {
            await gate.signalStarted()
            await gate.waitUntilReleased()
        } else if let delay = delaysByListID[listId] {
            try? await Task.sleep(for: delay)
        }
        if let error = listTasksErrorsByListID[listId] {
            throw error
        }
        return showCompleted ? tasks : tasks.filter { !$0.isCompleted }
    }

    func createTask(listId: String, title: String, notes: String?, due: String?, parentId: String?) async throws -> TaskItem {
        createTaskCounter += 1
        return TaskItem(
            id: "created-\(createTaskCounter)",
            title: title,
            notes: notes,
            status: .needsAction,
            due: due,
            selfLink: nil,
            parent: parentId,
            position: nil,
            updated: nil
        )
    }

    func updateTask(listId: String, taskId: String, task: TaskItem) async throws -> TaskItem {
        if let error = updateTaskErrorsByTaskID[taskId] {
            throw error
        }
        return task
    }

    func deleteTask(listId: String, taskId: String) async throws {}

    func moveTask(
        listId: String,
        taskId: String,
        parentId: String?,
        previousTaskId: String?,
        destinationListId: String?
    ) async throws -> TaskItem {
        if let moveTaskError {
            throw moveTaskError
        }
        if let destinationListId, destinationListId != listId {
            guard let moved = tasksMovingTaskTree(
                taskId,
                from: tasksByListID[listId] ?? [],
                to: tasksByListID[destinationListId] ?? [],
                parentId: parentId,
                previousTaskId: previousTaskId
            ) else {
                throw APIError.serverError(400, "Invalid move")
            }
            tasksByListID[listId] = moved.source
            tasksByListID[destinationListId] = moved.destination
            return moved.movedTask
        }
        guard let reordered = tasksReorderedAfterMove(
            tasksByListID[listId] ?? [],
            movedTaskID: taskId,
            newParentID: parentId,
            previousTaskID: previousTaskId
        ), let movedTask = reordered.first(where: { $0.id == taskId }) else {
            throw APIError.serverError(400, "Invalid move")
        }
        tasksByListID[listId] = reordered
        return movedTask
    }
}

/// A one-shot "request started" / "release the response" signal for
/// deterministically testing out-of-order network completions, without
/// guessing at real wall-clock margins with `Task.sleep`. `actor` because
/// it is awaited from both the fake API (inside a `listTasks` call) and the
/// test method concurrently.
private actor RequestGate {
    private var started = false
    private var released = false
    private var startContinuation: CheckedContinuation<Void, Never>?
    private var releaseContinuation: CheckedContinuation<Void, Never>?

    /// Called by the fake API once it has entered the gated call, so its
    /// caller (`AppState`) has already captured whatever "request started"
    /// state it needed to before this method could even be reached.
    func signalStarted() {
        started = true
        startContinuation?.resume()
        startContinuation = nil
    }

    /// Called by the test: suspends until `signalStarted()` has run.
    func waitUntilStarted() async {
        if started { return }
        await withCheckedContinuation { startContinuation = $0 }
    }

    /// Called by the test once it is done acting while the request is
    /// suspended, to let the fake API's call return.
    func release() {
        released = true
        releaseContinuation?.resume()
        releaseContinuation = nil
    }

    /// Called by the fake API: suspends until the test calls `release()`.
    func waitUntilReleased() async {
        if released { return }
        await withCheckedContinuation { releaseContinuation = $0 }
    }
}
