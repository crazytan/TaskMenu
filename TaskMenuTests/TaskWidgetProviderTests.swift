import XCTest
@testable import TaskMenu

/// Covers `TaskWidgetTimelineLoader` and `TaskWidgetListCatalog` — the
/// Foundation-only decision logic behind `TaskListWidgetProvider` and
/// `TaskListEntityQuery`. Both of those (and `TaskListWidgetConfigurationIntent`)
/// live in the `TaskMenuWidget` extension target (`AppIntentTimelineProvider`/
/// `EntityQuery` require `AppIntents`/`WidgetKit`), which this test target —
/// hosting the `TaskMenu` app — cannot import; see `TaskMenuWidget/README.md`
/// and this task's "Scope" notes on testability.
final class TaskWidgetProviderTests: XCTestCase {
    private var tempDirectory: URL!

    override func setUp() {
        super.setUp()
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("TaskWidgetProviderTests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
    }

    override func tearDown() {
        if let tempDirectory {
            try? FileManager.default.removeItem(at: tempDirectory)
        }
        tempDirectory = nil
        super.tearDown()
    }

    private func makeStore() -> TaskWidgetSnapshotStore {
        TaskWidgetSnapshotStore(directoryURL: tempDirectory)
    }

    // MARK: Placeholder

    func testPlaceholderSampleNeverReadsAnyStore() {
        // No store/keychain/API is passed at all — the call signature itself
        // proves this path cannot perform I/O.
        let content = TaskWidgetEntryContent.placeholderSample(rowBudget: 3)

        XCTAssertNil(content.listID, "placeholder content must never carry a real list id")
        XCTAssertEqual(content.status, .live)
        XCTAssertFalse(content.projection?.rows.isEmpty ?? true)
    }

    func testPlaceholderSampleIsFaithfulToRowBudget() {
        let small = TaskWidgetEntryContent.placeholderSample(rowBudget: TaskWidgetProjectionConstants.smallRowBudget)
        XCTAssertLessThanOrEqual(small.projection?.rows.count ?? .max, TaskWidgetProjectionConstants.smallRowBudget)
    }

    // MARK: Cached (gallery/preview) content — never touches the network

    func testCachedContentReadsCacheAndReportsStale() {
        let store = makeStore()
        try? store.setAuthentication(.signedIn)
        _ = try? store.replaceList(
            TaskWidgetListSnapshot(id: "list-1", title: "Errands", refreshedAt: Date(), tasks: [
                TaskWidgetTaskSnapshot(id: "t1", title: "Buy milk", position: "1"),
            ]),
            requestStartedAt: Date()
        )

        let content = TaskWidgetTimelineLoader.cachedContent(
            listID: "list-1", listTitle: "Errands", sortOrder: .myOrder, rowBudget: 6, snapshot: store.read()
        )

        guard case .stale = content.status else {
            return XCTFail("cache-only read must report stale, not live")
        }
        XCTAssertEqual(content.projection?.rows.count, 1)
    }

    func testCachedContentSignedOutReturnsSignedOutStatus() {
        let store = makeStore() // never signed in
        let content = TaskWidgetTimelineLoader.cachedContent(
            listID: "list-1", listTitle: nil, sortOrder: .myOrder, rowBudget: 6, snapshot: store.read()
        )
        XCTAssertEqual(content.status, .signedOut)
        XCTAssertNil(content.projection)
    }

    func testCachedContentNoCacheReturnsNoCacheStatus() {
        let store = makeStore()
        try? store.setAuthentication(.signedIn)
        let content = TaskWidgetTimelineLoader.cachedContent(
            listID: "missing-list", listTitle: nil, sortOrder: .myOrder, rowBudget: 6, snapshot: store.read()
        )
        XCTAssertEqual(content.status, .noCache)
    }

    // MARK: Live loading

    func testLiveSuccessWritesAndReturnsFreshTasks() async {
        let store = makeStore()
        try? store.setAuthentication(.signedIn)
        let api = FakeTasksAPI()
        api.listTasksResult = .success([
            TaskItem(id: "t1", title: "Fresh task", notes: nil, status: .needsAction, due: nil, selfLink: nil, parent: nil, position: "1", updated: nil),
        ])

        let content = await TaskWidgetTimelineLoader.loadLive(
            listID: "list-1", listTitle: "Errands", sortOrder: .myOrder, rowBudget: 6,
            store: store, keychain: InMemoryKeychainService(), api: api
        )

        XCTAssertEqual(content.status, .live)
        XCTAssertEqual(content.projection?.rows.count, 1)
        XCTAssertEqual(store.read().lists.first?.tasks.first?.title, "Fresh task")
    }

    func testLiveNetworkFailureFallsBackToCache() async {
        let store = makeStore()
        try? store.setAuthentication(.signedIn)
        _ = try? store.replaceList(
            TaskWidgetListSnapshot(id: "list-1", title: "Errands", refreshedAt: Date(), tasks: [
                TaskWidgetTaskSnapshot(id: "t1", title: "Cached task", position: "1"),
            ]),
            requestStartedAt: Date()
        )
        let api = FakeTasksAPI()
        api.listTasksResult = .failure(APIError.networkError(URLError(.notConnectedToInternet)))

        let content = await TaskWidgetTimelineLoader.loadLive(
            listID: "list-1", listTitle: "Errands", sortOrder: .myOrder, rowBudget: 6,
            store: store, keychain: InMemoryKeychainService(), api: api
        )

        guard case .stale = content.status else {
            return XCTFail("offline must fall back to stale cache, not clear it")
        }
        XCTAssertEqual(content.projection?.rows.first?.task.title, "Cached task")
    }

    func testLiveCancellationFallsBackToCacheWithoutPersistingAnError() async {
        let store = makeStore()
        try? store.setAuthentication(.signedIn)
        _ = try? store.replaceList(
            TaskWidgetListSnapshot(id: "list-1", title: "Errands", refreshedAt: Date(), tasks: [
                TaskWidgetTaskSnapshot(id: "t1", title: "Cached task", position: "1"),
            ]),
            requestStartedAt: Date()
        )
        let api = FakeTasksAPI()
        api.listTasksResult = .failure(APIError.networkError(URLError(.cancelled)))

        let content = await TaskWidgetTimelineLoader.loadLive(
            listID: "list-1", listTitle: "Errands", sortOrder: .myOrder, rowBudget: 6,
            store: store, keychain: InMemoryKeychainService(), api: api
        )

        guard case .stale = content.status else {
            return XCTFail("cancellation must be treated as cache fallback, not an error state")
        }
    }

    func testLiveNoCacheAndOfflineRendersNoCacheNotACrash() async {
        let store = makeStore()
        try? store.setAuthentication(.signedIn)
        let api = FakeTasksAPI()
        api.listTasksResult = .failure(APIError.networkError(URLError(.notConnectedToInternet)))

        let content = await TaskWidgetTimelineLoader.loadLive(
            listID: "list-1", listTitle: nil, sortOrder: .myOrder, rowBudget: 6,
            store: store, keychain: InMemoryKeychainService(), api: api
        )

        XCTAssertEqual(content.status, .noCache)
    }

    func testLiveAuthRejectionClearsCredentialsAndTaskTitles() async {
        let store = makeStore()
        try? store.setAuthentication(.signedIn)
        _ = try? store.replaceList(
            TaskWidgetListSnapshot(id: "list-1", title: "Errands", refreshedAt: Date(), tasks: [
                TaskWidgetTaskSnapshot(id: "t1", title: "Secret task title", position: "1"),
            ]),
            requestStartedAt: Date()
        )
        let keychain = InMemoryKeychainService()
        try? keychain.save(key: SharedConstants.Keychain.refreshTokenKey, string: "refresh-token")
        let api = FakeTasksAPI()
        api.listTasksResult = .failure(APIError.unauthorized)

        let content = await TaskWidgetTimelineLoader.loadLive(
            listID: "list-1", listTitle: "Errands", sortOrder: .myOrder, rowBudget: 6,
            store: store, keychain: keychain, api: api
        )

        XCTAssertEqual(content.status, .signedOut)
        XCTAssertNil(try? keychain.readString(key: SharedConstants.Keychain.refreshTokenKey))
        XCTAssertTrue(store.read().lists.isEmpty, "no cached task titles must remain after a definitive auth rejection")
    }

    func testDeletedConfiguredListStaysUnavailable() async {
        let store = makeStore()
        try? store.setAuthentication(.signedIn)
        let api = FakeTasksAPI()
        api.listTasksResult = .failure(APIError.serverError(404, "Not Found"))

        let content = await TaskWidgetTimelineLoader.loadLive(
            listID: "deleted-list", listTitle: "Gone", sortOrder: .myOrder, rowBudget: 6,
            store: store, keychain: InMemoryKeychainService(), api: api
        )

        XCTAssertEqual(content.status, .listUnavailable)
    }

    // MARK: Entity/catalog (identity, title, default, ordering)

    func testEntitiesForReturnsOnlyMatchingExistingListsInRequestedOrder() {
        let snapshot = TaskWidgetSnapshot(generatedAt: Date(), authentication: .signedIn, defaultListID: nil, lists: [
            TaskWidgetListSnapshot(id: "a", title: "A"),
            TaskWidgetListSnapshot(id: "b", title: "B"),
        ])
        let entries = TaskWidgetListCatalog.entries(for: ["b", "missing", "a"], in: snapshot)
        XCTAssertEqual(entries.map(\.id), ["b", "a"])
    }

    func testSuggestedEntitiesPreservesGoogleOrder() {
        let snapshot = TaskWidgetSnapshot(generatedAt: Date(), authentication: .signedIn, defaultListID: nil, lists: [
            TaskWidgetListSnapshot(id: "a", title: "A"),
            TaskWidgetListSnapshot(id: "b", title: "B"),
            TaskWidgetListSnapshot(id: "c", title: "C"),
        ])
        XCTAssertEqual(TaskWidgetListCatalog.suggestedEntries(in: snapshot).map(\.id), ["a", "b", "c"])
    }

    func testDefaultEntryPrefersDefaultListID() {
        let snapshot = TaskWidgetSnapshot(generatedAt: Date(), authentication: .signedIn, defaultListID: "b", lists: [
            TaskWidgetListSnapshot(id: "a", title: "A"),
            TaskWidgetListSnapshot(id: "b", title: "B"),
        ])
        XCTAssertEqual(TaskWidgetListCatalog.defaultEntry(in: snapshot)?.id, "b")
    }

    func testDefaultEntryFallsBackToFirstListWhenDefaultIDMissing() {
        let snapshot = TaskWidgetSnapshot(generatedAt: Date(), authentication: .signedIn, defaultListID: "not-there", lists: [
            TaskWidgetListSnapshot(id: "a", title: "A"),
            TaskWidgetListSnapshot(id: "b", title: "B"),
        ])
        XCTAssertEqual(TaskWidgetListCatalog.defaultEntry(in: snapshot)?.id, "a")
    }

    func testDefaultEntryReturnsNilForMissingSnapshotRatherThanFakingAList() {
        XCTAssertNil(TaskWidgetListCatalog.defaultEntry(in: .empty()))
        XCTAssertTrue(TaskWidgetListCatalog.suggestedEntries(in: .empty()).isEmpty)
    }

    func testEntitiesForRenamedListReflectsCurrentTitleUnderTheSameID() {
        let snapshot = TaskWidgetSnapshot(generatedAt: Date(), authentication: .signedIn, defaultListID: nil, lists: [
            TaskWidgetListSnapshot(id: "a", title: "Renamed Title"),
        ])
        XCTAssertEqual(TaskWidgetListCatalog.entries(for: ["a"], in: snapshot).first?.title, "Renamed Title")
    }
}

// MARK: - Fakes

/// Records/stubs `TasksAPIProtocol` calls for provider/completion tests
/// without any real networking. Shared by `TaskWidgetProviderTests` and
/// `CompleteTaskIntentTests`.
final class FakeTasksAPI: TasksAPIProtocol, @unchecked Sendable {
    enum StubResult<T> {
        case success(T)
        case failure(Error)
    }

    var listTasksResult: StubResult<[TaskItem]> = .success([])
    var setTaskCompletedResults: [String: StubResult<TaskItem>] = [:]

    private(set) var completedTaskIDs: [String] = []
    private(set) var listTasksCallCount = 0

    func listTaskLists() async throws -> [TaskList] { [] }

    func createTaskList(title: String) async throws -> TaskList {
        TaskList(id: "unused", title: title, selfLink: nil, updated: nil)
    }

    func listTasks(listId: String, showCompleted: Bool, showHidden: Bool) async throws -> [TaskItem] {
        listTasksCallCount += 1
        switch listTasksResult {
        case .success(let tasks): return tasks
        case .failure(let error): throw error
        }
    }

    func createTask(listId: String, title: String, notes: String?, due: String?, parentId: String?) async throws -> TaskItem {
        TaskItem(id: "unused", title: title, notes: notes, status: .needsAction, due: due, selfLink: nil, parent: parentId, position: nil, updated: nil)
    }

    func updateTask(listId: String, taskId: String, task: TaskItem) async throws -> TaskItem { task }

    func deleteTask(listId: String, taskId: String) async throws {}

    func moveTask(
        listId: String,
        taskId: String,
        parentId: String?,
        previousTaskId: String?,
        destinationListId: String?
    ) async throws -> TaskItem {
        TaskItem(id: taskId, title: "", notes: nil, status: .needsAction, due: nil, selfLink: nil, parent: parentId, position: nil, updated: nil)
    }

    func setTaskCompleted(listId: String, taskId: String) async throws -> TaskItem {
        completedTaskIDs.append(taskId)
        let result = setTaskCompletedResults[taskId] ?? .success(
            TaskItem(id: taskId, title: "", notes: nil, status: .completed, due: nil, selfLink: nil, parent: nil, position: nil, updated: nil)
        )
        switch result {
        case .success(let task): return task
        case .failure(let error): throw error
        }
    }
}
