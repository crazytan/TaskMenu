import XCTest
@testable import TaskMenu

/// Covers `TaskWidgetCompletionCoordinator` — the Foundation-only cascade/
/// refetch/publish logic behind `CompleteTaskIntent`. `CompleteTaskIntent`
/// itself lives in the `TaskMenuWidget` extension target (`AppIntent`
/// requires `AppIntents`/`WidgetKit`), which this test target — hosting the
/// `TaskMenu` app — cannot import; see `TaskMenuWidget/README.md`. Uses
/// `FakeTasksAPI` from `TaskWidgetProviderTests.swift`.
final class CompleteTaskIntentTests: XCTestCase {
    private var tempDirectory: URL!

    override func setUp() {
        super.setUp()
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CompleteTaskIntentTests-\(UUID().uuidString)")
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

    private func seedSignedInList(_ store: TaskWidgetSnapshotStore, tasks: [TaskWidgetTaskSnapshot]) {
        try? store.setAuthentication(.signedIn)
        _ = try? store.replaceList(
            TaskWidgetListSnapshot(id: "list-1", title: "Errands", refreshedAt: Date(), tasks: tasks),
            requestStartedAt: Date()
        )
    }

    // MARK: Single task

    func testSingleTaskSuccessCompletesAndRefetches() async {
        let store = makeStore()
        seedSignedInList(store, tasks: [
            TaskWidgetTaskSnapshot(id: "t1", title: "Buy milk", position: "1"),
            TaskWidgetTaskSnapshot(id: "t2", title: "Buy eggs", position: "2"),
        ])
        let api = FakeTasksAPI()
        api.listTasksResult = .success([
            TaskItem(id: "t2", title: "Buy eggs", notes: nil, status: .needsAction, due: nil, selfLink: nil, parent: nil, position: "2", updated: nil),
        ])

        let outcome = await TaskWidgetCompletionCoordinator.complete(
            listID: "list-1", taskID: "t1", store: store, keychain: InMemoryKeychainService(), api: api
        )

        XCTAssertEqual(outcome.result, .success)
        XCTAssertTrue(outcome.sharedStateChanged)
        XCTAssertEqual(api.completedTaskIDs, ["t1"])
        XCTAssertEqual(store.read().lists.first?.tasks.map(\.id), ["t2"])
    }

    // MARK: Parent cascade

    func testParentCompletionCascadesToOpenDirectChildren() async {
        let store = makeStore()
        seedSignedInList(store, tasks: [
            TaskWidgetTaskSnapshot(id: "parent", title: "Plan trip", position: "1"),
            TaskWidgetTaskSnapshot(id: "child1", title: "Book flight", parent: "parent", position: "1"),
            TaskWidgetTaskSnapshot(id: "child2", title: "Book hotel", parent: "parent", position: "2"),
            TaskWidgetTaskSnapshot(id: "sibling", title: "Unrelated", position: "2"),
        ])
        let api = FakeTasksAPI()
        api.listTasksResult = .success([
            TaskItem(id: "sibling", title: "Unrelated", notes: nil, status: .needsAction, due: nil, selfLink: nil, parent: nil, position: "2", updated: nil),
        ])

        let outcome = await TaskWidgetCompletionCoordinator.complete(
            listID: "list-1", taskID: "parent", store: store, keychain: InMemoryKeychainService(), api: api
        )

        XCTAssertEqual(outcome.result, .success)
        XCTAssertEqual(Set(api.completedTaskIDs), ["parent", "child1", "child2"])
        XCTAssertEqual(store.read().lists.first?.tasks.map(\.id), ["sibling"])
    }

    func testCompletedChildrenAreAlreadyAbsentFromTheCascade() async {
        // The snapshot invariant (open tasks only) means an already-completed
        // child never appears under `parent` in the cache to begin with, so
        // the coordinator never has to special-case "skip completed
        // children" — there is nothing to skip.
        let store = makeStore()
        seedSignedInList(store, tasks: [
            TaskWidgetTaskSnapshot(id: "parent", title: "Plan trip", position: "1"),
            TaskWidgetTaskSnapshot(id: "child-open", title: "Book flight", parent: "parent", position: "1"),
        ])
        let api = FakeTasksAPI()
        api.listTasksResult = .success([])

        _ = await TaskWidgetCompletionCoordinator.complete(
            listID: "list-1", taskID: "parent", store: store, keychain: InMemoryKeychainService(), api: api
        )

        XCTAssertEqual(Set(api.completedTaskIDs), ["parent", "child-open"])
    }

    func testSubtaskCompletionDoesNotAffectSiblings() async {
        let store = makeStore()
        seedSignedInList(store, tasks: [
            TaskWidgetTaskSnapshot(id: "parent", title: "Plan trip", position: "1"),
            TaskWidgetTaskSnapshot(id: "child1", title: "Book flight", parent: "parent", position: "1"),
            TaskWidgetTaskSnapshot(id: "child2", title: "Book hotel", parent: "parent", position: "2"),
        ])
        let api = FakeTasksAPI()
        api.listTasksResult = .success([
            TaskItem(id: "parent", title: "Plan trip", notes: nil, status: .needsAction, due: nil, selfLink: nil, parent: nil, position: "1", updated: nil),
            TaskItem(id: "child2", title: "Book hotel", notes: nil, status: .needsAction, due: nil, selfLink: nil, parent: "parent", position: "2", updated: nil),
        ])

        let outcome = await TaskWidgetCompletionCoordinator.complete(
            listID: "list-1", taskID: "child1", store: store, keychain: InMemoryKeychainService(), api: api
        )

        XCTAssertEqual(outcome.result, .success)
        XCTAssertEqual(api.completedTaskIDs, ["child1"], "completing a subtask must never cascade to its siblings")
    }

    // MARK: Failure modes

    func testTotalFailureLeavesCacheUnchanged() async {
        let store = makeStore()
        seedSignedInList(store, tasks: [TaskWidgetTaskSnapshot(id: "t1", title: "Buy milk", position: "1")])
        let api = FakeTasksAPI()
        api.setTaskCompletedResults["t1"] = .failure(APIError.networkError(URLError(.notConnectedToInternet)))

        let outcome = await TaskWidgetCompletionCoordinator.complete(
            listID: "list-1", taskID: "t1", store: store, keychain: InMemoryKeychainService(), api: api
        )

        XCTAssertEqual(outcome.result, .transientFailure)
        XCTAssertFalse(outcome.sharedStateChanged)
        XCTAssertEqual(store.read().lists.first?.tasks.map(\.id), ["t1"], "the cached task must remain visible after a transient failure")
    }

    func testPartialChildFailureRefetchesAndPublishesServerTruth() async {
        let store = makeStore()
        seedSignedInList(store, tasks: [
            TaskWidgetTaskSnapshot(id: "parent", title: "Plan trip", position: "1"),
            TaskWidgetTaskSnapshot(id: "child1", title: "Book flight", parent: "parent", position: "1"),
            TaskWidgetTaskSnapshot(id: "child2", title: "Book hotel", parent: "parent", position: "2"),
        ])
        let api = FakeTasksAPI()
        api.setTaskCompletedResults["child2"] = .failure(APIError.serverError(500, nil))
        // Server truth after the partial failure: child2 is still open.
        api.listTasksResult = .success([
            TaskItem(id: "child2", title: "Book hotel", notes: nil, status: .needsAction, due: nil, selfLink: nil, parent: "parent", position: "2", updated: nil),
        ])

        let outcome = await TaskWidgetCompletionCoordinator.complete(
            listID: "list-1", taskID: "parent", store: store, keychain: InMemoryKeychainService(), api: api
        )

        XCTAssertEqual(outcome.result, .partialFailure)
        XCTAssertTrue(outcome.sharedStateChanged)
        XCTAssertEqual(store.read().lists.first?.tasks.map(\.id), ["child2"], "must publish server truth, not pretend every child completed")
    }

    func testOverlappingStaleAppFetchCannotResurrectACompletedTask() async {
        let store = makeStore()
        seedSignedInList(store, tasks: [TaskWidgetTaskSnapshot(id: "t1", title: "Buy milk", position: "1")])
        let api = FakeTasksAPI()
        api.listTasksResult = .success([])

        let outcome = await TaskWidgetCompletionCoordinator.complete(
            listID: "list-1", taskID: "t1", store: store, keychain: InMemoryKeychainService(), api: api
        )
        XCTAssertEqual(outcome.result, .success)

        // Simulate a slower app-wide refresh that *started* before the
        // completion but is only being published (i.e. finishing) now,
        // still carrying the task as open.
        let staleRequestStartedAt = Date().addingTimeInterval(-60)
        let accepted = try? store.replaceList(
            TaskWidgetListSnapshot(id: "list-1", title: "Errands", refreshedAt: Date(), tasks: [
                TaskWidgetTaskSnapshot(id: "t1", title: "Buy milk", position: "1"),
            ]),
            requestStartedAt: staleRequestStartedAt
        )

        XCTAssertEqual(accepted, false, "a request that started before the completion must be rejected")
        XCTAssertTrue(store.read().lists.first?.tasks.isEmpty ?? false, "the completed task must not resurface")
    }

    func testDefinitiveAuthFailureClearsCredentialsAndCache() async {
        let store = makeStore()
        seedSignedInList(store, tasks: [TaskWidgetTaskSnapshot(id: "t1", title: "Buy milk", position: "1")])
        let keychain = InMemoryKeychainService()
        try? keychain.save(key: SharedConstants.Keychain.refreshTokenKey, string: "refresh-token")
        let api = FakeTasksAPI()
        api.setTaskCompletedResults["t1"] = .failure(APIError.unauthorized)

        let outcome = await TaskWidgetCompletionCoordinator.complete(
            listID: "list-1", taskID: "t1", store: store, keychain: keychain, api: api
        )

        XCTAssertEqual(outcome.result, .authFailure)
        XCTAssertTrue(outcome.sharedStateChanged)
        XCTAssertNil(try? keychain.readString(key: SharedConstants.Keychain.refreshTokenKey))
        XCTAssertTrue(store.read().lists.isEmpty)
    }

    func testTaskNotInCachedListRefusesToMutate() async {
        let store = makeStore()
        seedSignedInList(store, tasks: [TaskWidgetTaskSnapshot(id: "t1", title: "Buy milk", position: "1")])
        let api = FakeTasksAPI()

        let outcome = await TaskWidgetCompletionCoordinator.complete(
            listID: "list-1", taskID: "unknown-task", store: store, keychain: InMemoryKeychainService(), api: api
        )

        XCTAssertEqual(outcome.result, .taskNotInList)
        XCTAssertFalse(outcome.sharedStateChanged)
        XCTAssertTrue(api.completedTaskIDs.isEmpty, "must never call Google for an id the widget's cache never confirmed")
    }

    func testNoCredentialsRefusesToMutateWithoutChangingSharedState() async {
        // `CompleteTaskIntent` gates `WidgetCenter.reloadTimelines`/the
        // change signal on exactly `sharedStateChanged`; pin that it is
        // false for every no-write outcome, including "never signed in".
        let store = makeStore() // signed out
        let api = FakeTasksAPI()

        let outcome = await TaskWidgetCompletionCoordinator.complete(
            listID: "list-1", taskID: "t1", store: store, keychain: InMemoryKeychainService(), api: api
        )

        XCTAssertEqual(outcome.result, .authFailure)
        XCTAssertFalse(outcome.sharedStateChanged)
        XCTAssertTrue(api.completedTaskIDs.isEmpty)
    }
}
