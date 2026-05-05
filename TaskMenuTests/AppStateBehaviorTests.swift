import XCTest
@testable import TaskMenu

/// Tests for AppState behavior: toggleTask, loadTasks, refreshTasks, cache management, error handling.
/// Uses MockURLProtocol to simulate API responses without hitting the network.
/// Uses MockURLProtocol.requestLog to inspect requests (avoids captured var issues with Swift 6 concurrency).
@MainActor
final class AppStateBehaviorTests: XCTestCase {
    private var keychain: InMemoryKeychainService!
    private var state: AppState!
    private var userDefaults: UserDefaults!
    private var userDefaultsSuiteName: String!
    private var dueDateNotificationService: TestDueDateNotificationService!

    override func setUp() async throws {
        MockURLProtocol.reset()

        keychain = InMemoryKeychainService()
        userDefaultsSuiteName = "dev.crazytan.TaskMenu.tests.appstate.behavior.\(UUID().uuidString)"
        userDefaults = UserDefaults(suiteName: userDefaultsSuiteName)
        userDefaults.removePersistentDomain(forName: userDefaultsSuiteName)
        dueDateNotificationService = TestDueDateNotificationService()
        // Pre-load valid tokens so validAccessToken() returns immediately
        try? keychain.save(key: Constants.Keychain.accessTokenKey, string: "test-access-token")
        try? keychain.save(key: Constants.Keychain.refreshTokenKey, string: "test-refresh-token")
        let futureExpiration = String(Date().addingTimeInterval(3600).timeIntervalSince1970)
        try? keychain.save(key: Constants.Keychain.expirationKey, string: futureExpiration)

        let session = MockURLProtocol.mockSession()
        let authService = GoogleAuthService(keychain: keychain, session: session)
        let api = GoogleTasksAPI(authService: authService, session: session)
        state = AppState(
            authService: authService,
            api: api,
            userDefaults: userDefaults,
            dueDateNotificationService: dueDateNotificationService
        )
    }

    override func tearDown() async throws {
        MockURLProtocol.reset()
        try? keychain.deleteAll()
        if let userDefaultsSuiteName {
            userDefaults.removePersistentDomain(forName: userDefaultsSuiteName)
        }
        userDefaults = nil
        userDefaultsSuiteName = nil
        dueDateNotificationService = nil
    }

    // MARK: - Helpers

    private func makeTask(
        id: String = "t1",
        title: String = "Test",
        status: TaskItem.TaskStatus = .needsAction,
        parent: String? = nil,
        position: String? = nil
    ) -> TaskItem {
        TaskItem(
            id: id,
            title: title,
            notes: nil,
            status: status,
            due: nil,
            selfLink: nil,
            parent: parent,
            position: position,
            updated: nil
        )
    }

    private func stubResponse(statusCode: Int = 200, json: String) {
        MockURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: statusCode, httpVersion: nil, headerFields: nil)!
            return (response, json.data(using: .utf8)!)
        }
    }

    private func stubTaskListResponses() {
        MockURLProtocol.requestHandler = { request in
            let url = request.url!.absoluteString
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!

            if url.contains("showCompleted=false") {
                let json = #"{"items":[{"id":"t1","title":"Active","status":"needsAction"}]}"#
                return (response, json.data(using: .utf8)!)
            } else if url.contains("/tasks") {
                let json = #"{"items":[{"id":"t1","title":"Active","status":"needsAction"},{"id":"t2","title":"Done","status":"completed"}]}"#
                return (response, json.data(using: .utf8)!)
            } else {
                return (response, #"{"items":[]}"#.data(using: .utf8)!)
            }
        }
    }

    private func makeState(api: any TasksAPIProtocol) -> AppState {
        let authService = GoogleAuthService(keychain: keychain, session: MockURLProtocol.mockSession())
        return AppState(
            authService: authService,
            api: api,
            userDefaults: userDefaults,
            dueDateNotificationService: dueDateNotificationService
        )
    }

    // MARK: - toggleTask: Optimistic Update

    func testToggleTaskCompletesSuccessfully() async {
        state.selectedListId = "list1"
        state.tasks = [makeTask()]

        stubResponse(json: #"{"id":"t1","title":"Test","status":"completed"}"#)

        await state.toggleTask(state.tasks[0])

        XCTAssertTrue(state.tasks[0].isCompleted)
        XCTAssertNil(state.errorMessage)
    }

    func testToggleTaskUncompletesSuccessfully() async {
        state.selectedListId = "list1"
        state.tasks = [makeTask(status: .completed)]

        stubResponse(json: #"{"id":"t1","title":"Test","status":"needsAction"}"#)

        await state.toggleTask(state.tasks[0])

        XCTAssertFalse(state.tasks[0].isCompleted)
        XCTAssertNil(state.errorMessage)
    }

    // MARK: - toggleTask: Revert on Failure

    func testToggleTaskRevertsOnServerError() async {
        state.selectedListId = "list1"
        let task = makeTask()
        state.tasks = [task]

        stubResponse(statusCode: 500, json: #"{"error":"Internal Server Error"}"#)

        await state.toggleTask(task)

        // Should revert to original needsAction status
        XCTAssertFalse(state.tasks[0].isCompleted)
        XCTAssertEqual(state.tasks[0].status, .needsAction)
        XCTAssertNotNil(state.errorMessage)
        XCTAssertTrue(state.errorMessage!.contains("500"))
    }

    func testToggleTaskRevertsCompletedTaskOnFailure() async {
        state.selectedListId = "list1"
        let task = makeTask(status: .completed)
        state.tasks = [task]

        stubResponse(statusCode: 500, json: "")

        await state.toggleTask(task)

        // Should revert to original completed status
        XCTAssertTrue(state.tasks[0].isCompleted)
    }

    // MARK: - toggleTask: Cache Management

    func testToggleTaskCompletingKeepsTaskInList() async {
        state.selectedListId = "list1"
        let task = makeTask()
        state.tasks = [task]

        stubResponse(json: #"{"id":"t1","title":"Test","status":"completed"}"#)

        await state.toggleTask(task)

        XCTAssertTrue(state.tasks.contains(where: { $0.id == "t1" && $0.isCompleted }))
    }

    func testToggleTaskRemovesFromCacheWhenUncompleting() async {
        state.selectedListId = "list1"
        let task = makeTask(id: "t1", status: .completed)
        state.tasks = [task]

        stubResponse(json: #"{"id":"t1","title":"Test","status":"needsAction"}"#)

        await state.toggleTask(task)

        XCTAssertFalse(state.tasks[0].isCompleted)
    }

    func testToggleTaskPreventsDuplicateCacheEntries() async {
        state.selectedListId = "list1"
        let task = makeTask()
        state.tasks = [task]

        // Toggle to completed
        stubResponse(json: #"{"id":"t1","title":"Test","status":"completed"}"#)
        await state.toggleTask(task)

        // Toggle back
        stubResponse(json: #"{"id":"t1","title":"Test","status":"needsAction"}"#)
        await state.toggleTask(state.tasks[0])

        // Toggle to completed again
        stubResponse(json: #"{"id":"t1","title":"Test","status":"completed"}"#)
        await state.toggleTask(state.tasks[0])

        // Task should appear exactly once
        let matchingTasks = state.tasks.filter { $0.id == "t1" }
        XCTAssertEqual(matchingTasks.count, 1)
    }

    // MARK: - toggleTask: Guard

    func testToggleTaskWithNoSelectedListDoesNothing() async {
        state.selectedListId = nil
        let task = makeTask()
        state.tasks = [task]

        await state.toggleTask(task)

        // Task should remain unchanged
        XCTAssertFalse(state.tasks[0].isCompleted)
    }

    // MARK: - loadTasks: First Load (Full Fetch)

    func testLoadTasksFirstLoadFetchesActiveAndCompleted() async {
        state.selectedListId = "list1"
        stubTaskListResponses()

        await state.loadTasks()

        // Should have both active and completed tasks
        XCTAssertEqual(state.tasks.count, 2)
        XCTAssertTrue(state.tasks.contains(where: { $0.id == "t1" && !$0.isCompleted }))
        XCTAssertTrue(state.tasks.contains(where: { $0.id == "t2" && $0.isCompleted }))
        // Two API calls: one for active, one for all (to get completed)
        XCTAssertEqual(MockURLProtocol.requestLog.count, 2)
    }

    // MARK: - loadTasks: Cached (Active-Only Fetch)

    func testLoadTasksUsesCacheOnSecondCall() async {
        state.selectedListId = "list1"
        stubTaskListResponses()

        // First load: fetches both active and completed
        await state.loadTasks()
        let firstLoadRequestCount = MockURLProtocol.requestLog.count
        XCTAssertEqual(firstLoadRequestCount, 2) // active + completed

        // Reset log to count only second call's requests
        MockURLProtocol.requestLog = []

        // Second load: should only fetch active (cache for completed)
        await state.loadTasks()
        let secondLoadRequestCount = MockURLProtocol.requestLog.count
        XCTAssertEqual(secondLoadRequestCount, 1) // active only

        // Should still have both active and cached completed tasks
        XCTAssertTrue(state.tasks.contains(where: { $0.id == "t1" }))
        XCTAssertTrue(state.tasks.contains(where: { $0.id == "t2" }))
    }

    // MARK: - refreshTasks: Always Fresh

    func testRefreshTasksFetchesFresh() async {
        state.selectedListId = "list1"
        state.taskLists = [TaskList(id: "list1", title: "Inbox", selfLink: nil, updated: nil)]

        stubResponse(json: #"{"items":[{"id":"t1","title":"Task","status":"needsAction"},{"id":"t2","title":"Done","status":"completed"}]}"#)

        await state.refreshTasks()

        XCTAssertEqual(state.tasks.count, 2)
        XCTAssertFalse(state.isLoading)
    }

    func testRefreshTasksUpdatesCacheAndSubsequentLoadUsesIt() async {
        state.selectedListId = "list1"
        state.taskLists = [TaskList(id: "list1", title: "Inbox", selfLink: nil, updated: nil)]

        // Refresh fetches everything
        stubResponse(json: #"{"items":[{"id":"t1","title":"Active","status":"needsAction"},{"id":"t2","title":"Done","status":"completed"}]}"#)
        await state.refreshTasks()

        // Reset log, then loadTasks should use cache
        MockURLProtocol.requestLog = []
        stubResponse(json: #"{"items":[{"id":"t1","title":"Active","status":"needsAction"}]}"#)

        await state.loadTasks()

        // Only one call (active tasks only, completed from cache)
        XCTAssertEqual(MockURLProtocol.requestLog.count, 1)
        XCTAssertEqual(state.tasks.count, 2) // active + cached completed
    }

    func testRefreshTasksGuardWithNoSelectedList() async {
        state.selectedListId = nil

        await state.refreshTasks()

        XCTAssertTrue(state.tasks.isEmpty)
        XCTAssertFalse(state.isLoading)
    }

    // MARK: - selectList: Per-list Cache

    func testSelectListLoadsFreshListWithoutReusingPreviousListCache() async {
        state.selectedListId = "list1"

        // Initial load for list1
        stubResponse(json: #"{"items":[{"id":"t1","title":"List1 Task","status":"needsAction"}]}"#)
        await state.refreshTasks()

        // Reset log, then select list2
        MockURLProtocol.requestLog = []
        MockURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            let json = #"{"items":[{"id":"t3","title":"List2 Active","status":"needsAction"},{"id":"t4","title":"List2 Done","status":"completed"}]}"#
            return (response, json.data(using: .utf8)!)
        }

        await state.selectList("list2")

        // Should fetch the new list directly instead of showing list1's cached tasks.
        XCTAssertEqual(MockURLProtocol.requestLog.count, 1)
        XCTAssertEqual(state.selectedListId, "list2")
        XCTAssertFalse(state.tasks.contains(where: { $0.id == "t1" }))
        XCTAssertTrue(state.tasks.contains(where: { $0.id == "t3" }))
    }

    func testSelectListShowsCachedTasksBeforeRefreshCompletes() async {
        let cachedList1Task = makeTask(id: "list1-cached", title: "Cached List 1")
        let freshList1Task = makeTask(id: "list1-fresh", title: "Fresh List 1")
        let list2Task = makeTask(id: "list2-task", title: "List 2")
        let api = DelayedTasksAPI(
            taskLists: [
                TaskList(id: "list1", title: "Inbox", selfLink: nil, updated: nil),
                TaskList(id: "list2", title: "Work", selfLink: nil, updated: nil),
            ],
            tasksByListID: [
                "list1": [cachedList1Task],
                "list2": [list2Task],
            ]
        )
        let state = makeState(api: api)
        state.taskLists = [
            TaskList(id: "list1", title: "Inbox", selfLink: nil, updated: nil),
            TaskList(id: "list2", title: "Work", selfLink: nil, updated: nil),
        ]

        state.selectedListId = "list1"
        await state.refreshTasks()
        state.selectedListId = "list2"
        await state.refreshTasks()

        await api.setTasks([freshList1Task], for: "list1")
        await api.setDelay(.milliseconds(100), for: "list1")

        let switchTask = Task { await state.selectList("list1") }
        await Task.yield()

        XCTAssertEqual(state.selectedListId, "list1")
        XCTAssertEqual(state.tasks.map(\.id), ["list1-cached"])

        await switchTask.value

        XCTAssertEqual(state.tasks.map(\.id), ["list1-fresh"])
    }

    func testStaleTaskRefreshDoesNotOverwriteCurrentSelection() async {
        let api = DelayedTasksAPI(
            taskLists: [
                TaskList(id: "list1", title: "Inbox", selfLink: nil, updated: nil),
                TaskList(id: "list2", title: "Work", selfLink: nil, updated: nil),
            ],
            tasksByListID: [
                "list1": [makeTask(id: "list1-fresh", title: "Fresh List 1")],
                "list2": [makeTask(id: "list2-current", title: "Current List 2")],
            ],
            delaysByListID: ["list1": .milliseconds(100)]
        )
        let state = makeState(api: api)
        state.taskLists = [
            TaskList(id: "list1", title: "Inbox", selfLink: nil, updated: nil),
            TaskList(id: "list2", title: "Work", selfLink: nil, updated: nil),
        ]
        state.selectedListId = "list1"
        state.tasks = [makeTask(id: "list1-stale", title: "Stale List 1")]

        let staleRefreshTask = Task { await state.refreshTasks() }
        await Task.yield()

        await state.selectList("list2")
        await staleRefreshTask.value

        XCTAssertEqual(state.selectedListId, "list2")
        XCTAssertEqual(state.tasks.map(\.id), ["list2-current"])
    }

    // MARK: - signIn / signOut State Transitions

    func testSignOutClearsAllStateIncludingCache() {
        state.taskLists = [TaskList(id: "l1", title: "Work", selfLink: nil, updated: nil)]
        state.selectedListId = "l1"
        state.tasks = [makeTask(), makeTask(id: "t2", status: .completed)]

        state.signOut()

        XCTAssertFalse(state.isSignedIn)
        XCTAssertTrue(state.taskLists.isEmpty)
        XCTAssertTrue(state.tasks.isEmpty)
        XCTAssertNil(state.selectedListId)
        XCTAssertNil(state.errorMessage)
    }

    func testSignOutAfterSignInResetsEverything() throws {
        XCTAssertTrue(state.isSignedIn) // Pre-loaded tokens

        state.signOut()

        XCTAssertFalse(state.isSignedIn)
    }

    // MARK: - Error Handling

    func testHandleErrorUnauthorizedSignsOut() async {
        state.selectedListId = "list1"
        state.tasks = [makeTask()]

        stubResponse(statusCode: 401, json: "")

        await state.toggleTask(state.tasks[0])

        // 401 should trigger signOut
        XCTAssertFalse(state.isSignedIn)
        XCTAssertTrue(state.tasks.isEmpty)
        XCTAssertNotNil(state.errorMessage)
        XCTAssertTrue(state.errorMessage!.contains("Session expired"))
    }

    func testHandleErrorServerErrorSetsMessage() async {
        state.selectedListId = "list1"

        stubResponse(statusCode: 503, json: #"Service Unavailable"#)

        await state.refreshTasks()

        XCTAssertNotNil(state.errorMessage)
        XCTAssertTrue(state.errorMessage!.contains("503"))
    }

    func testHandleErrorDecodingErrorSetsMessage() async {
        state.selectedListId = "list1"

        stubResponse(json: "not valid json {{{")

        await state.refreshTasks()

        XCTAssertNotNil(state.errorMessage)
        XCTAssertTrue(state.errorMessage!.contains("parse"))
    }

    func testHandleErrorNetworkErrorSetsMessage() async {
        state.selectedListId = "list1"

        MockURLProtocol.requestHandler = { _ in
            throw URLError(.notConnectedToInternet)
        }

        await state.refreshTasks()

        XCTAssertNotNil(state.errorMessage)
        XCTAssertTrue(state.errorMessage!.contains("Network error"))
    }

    // MARK: - addTask

    func testAddTaskInsertsAtBeginning() async {
        state.selectedListId = "list1"
        state.tasks = [makeTask(id: "existing")]

        stubResponse(json: #"{"id":"new1","title":"New Task","status":"needsAction"}"#)

        await state.addTask(title: "New Task")

        XCTAssertEqual(state.tasks.count, 2)
        XCTAssertEqual(state.tasks[0].id, "new1")
        XCTAssertEqual(state.tasks[0].title, "New Task")
    }

    // MARK: - deleteTask

    func testDeleteTaskRemovesFromTasksAndCache() async {
        state.selectedListId = "list1"
        state.taskLists = [TaskList(id: "list1", title: "Inbox", selfLink: nil, updated: nil)]
        state.tasks = [makeTask(id: "t1"), makeTask(id: "t2", status: .completed)]

        MockURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, Data())
        }

        await state.deleteTask(state.tasks[1]) // delete t2

        XCTAssertEqual(state.tasks.count, 1)
        XCTAssertEqual(state.tasks[0].id, "t1")
        let removedTaskIDs = await dueDateNotificationService.removedTaskIDs
        let removedListIDs = await dueDateNotificationService.removedListIDs
        XCTAssertEqual(removedTaskIDs, [["t2"]])
        XCTAssertEqual(removedListIDs, ["list1"])
    }

    // MARK: - updateTask

    func testUpdateTaskReplacesInTasksArray() async {
        state.selectedListId = "list1"
        var task = makeTask()
        task.title = "Updated Title"
        state.tasks = [makeTask()]

        stubResponse(json: #"{"id":"t1","title":"Updated Title","status":"needsAction"}"#)

        await state.updateTask(task)

        XCTAssertEqual(state.tasks[0].title, "Updated Title")
    }

    // MARK: - moveTask

    func testMoveTaskReordersActiveTasksAndPersistsMoveRequest() async {
        state.selectedListId = "list1"
        state.tasks = [
            makeTask(id: "t1", title: "One", parent: "parent1"),
            makeTask(id: "t2", title: "Two", parent: "parent1"),
            makeTask(id: "t3", title: "Three", parent: "parent1"),
            makeTask(id: "t4", title: "Done", status: .completed),
        ]

        stubResponse(json: #"{"id":"t1","title":"One","status":"needsAction","parent":"parent1","position":"00000002"}"#)

        await state.moveTask(state.tasks[0], toActiveIndex: 2)

        XCTAssertEqual(state.tasks.map(\.id), ["t2", "t1", "t3", "t4"])
        XCTAssertEqual(state.tasks[1].position, "00000002")

        let lastRequest = MockURLProtocol.requestLog.last!
        XCTAssertEqual(lastRequest.httpMethod, "POST")
        let url = lastRequest.url!.absoluteString
        XCTAssertTrue(url.contains("/lists/list1/tasks/t1/move"))
        XCTAssertTrue(url.contains("previous=t2"))
        XCTAssertTrue(url.contains("parent=parent1"))
    }

    func testMoveTaskToFirstPositionOmitsPreviousQueryParam() async {
        state.selectedListId = "list1"
        state.tasks = [
            makeTask(id: "t1", title: "One"),
            makeTask(id: "t2", title: "Two"),
            makeTask(id: "t3", title: "Three"),
        ]

        stubResponse(json: #"{"id":"t3","title":"Three","status":"needsAction","position":"00000000"}"#)

        await state.moveTask(state.tasks[2], toActiveIndex: 0)

        XCTAssertEqual(state.tasks.map(\.id), ["t3", "t1", "t2"])

        let components = URLComponents(url: MockURLProtocol.requestLog.last!.url!, resolvingAgainstBaseURL: false)
        XCTAssertNil(components?.queryItems?.first(where: { $0.name == "previous" }))
    }

    func testMoveTaskRevertsOrderOnFailure() async {
        state.selectedListId = "list1"
        state.tasks = [
            makeTask(id: "t1", title: "One"),
            makeTask(id: "t2", title: "Two"),
            makeTask(id: "t3", title: "Three"),
            makeTask(id: "t4", title: "Done", status: .completed),
        ]

        stubResponse(statusCode: 500, json: #"{"error":"Move failed"}"#)

        await state.moveTask(state.tasks[1], toActiveIndex: 3)

        XCTAssertEqual(state.tasks.map(\.id), ["t1", "t2", "t3", "t4"])
        XCTAssertNotNil(state.errorMessage)
        XCTAssertTrue(state.errorMessage!.contains("500"))
    }

    // MARK: - loadTaskLists

    func testLoadTaskListsAutoSelectsFirstList() async {
        MockURLProtocol.requestHandler = { request in
            let url = request.url!.absoluteString
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!

            if url.contains("/users/@me/lists") {
                let json = #"{"items":[{"id":"l1","title":"My Tasks"},{"id":"l2","title":"Work"}]}"#
                return (response, json.data(using: .utf8)!)
            } else {
                return (response, #"{"items":[]}"#.data(using: .utf8)!)
            }
        }

        await state.loadTaskLists()

        XCTAssertEqual(state.taskLists.count, 2)
        XCTAssertEqual(state.selectedListId, "l1")
        XCTAssertFalse(state.isLoading)
    }

    func testLoadTaskListsPreservesExistingSelection() async {
        state.selectedListId = "l2"

        MockURLProtocol.requestHandler = { request in
            let url = request.url!.absoluteString
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!

            if url.contains("/users/@me/lists") {
                let json = #"{"items":[{"id":"l1","title":"My Tasks"},{"id":"l2","title":"Work"}]}"#
                return (response, json.data(using: .utf8)!)
            } else {
                return (response, #"{"items":[]}"#.data(using: .utf8)!)
            }
        }

        await state.loadTaskLists()

        // Should keep l2 selected since selectedListId was already set
        XCTAssertEqual(state.selectedListId, "l2")
    }

    // MARK: - refreshForMenuPresentation

    func testRefreshForMenuPresentationLoadsListsWhenEmpty() async {
        state.isSignedIn = true

        MockURLProtocol.requestHandler = { request in
            let url = request.url!.absoluteString
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!

            if url.contains("/users/@me/lists") {
                let json = #"{"items":[{"id":"l1","title":"My Tasks"}]}"#
                return (response, json.data(using: .utf8)!)
            } else {
                let json = #"{"items":[{"id":"t1","title":"Fresh Task","status":"needsAction"}]}"#
                return (response, json.data(using: .utf8)!)
            }
        }

        await state.refreshForMenuPresentation()

        XCTAssertEqual(state.selectedListId, "l1")
        XCTAssertEqual(state.taskLists.map(\.id), ["l1"])
        XCTAssertEqual(state.tasks.map(\.title), ["Fresh Task"])
        XCTAssertEqual(MockURLProtocol.requestLog.count, 2)
    }

    func testRefreshForMenuPresentationRefreshesSelectedListWhenListsAlreadyLoaded() async {
        state.isSignedIn = true
        state.taskLists = [TaskList(id: "l1", title: "My Tasks", selfLink: nil, updated: nil)]
        state.selectedListId = "l1"
        state.tasks = [makeTask(id: "stale", title: "Stale Task")]

        MockURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            let json = #"{"items":[{"id":"fresh","title":"Fresh Task","status":"needsAction"}]}"#
            return (response, json.data(using: .utf8)!)
        }

        await state.refreshForMenuPresentation()

        XCTAssertEqual(state.tasks.map(\.id), ["fresh"])
        XCTAssertFalse(MockURLProtocol.requestLog.contains { $0.url?.absoluteString.contains("/users/@me/lists") == true })
        XCTAssertEqual(MockURLProtocol.requestLog.count, 1)
    }

    func testRefreshForMenuPresentationDoesNothingWhenSignedOut() async {
        state.isSignedIn = false
        state.taskLists = [TaskList(id: "l1", title: "My Tasks", selfLink: nil, updated: nil)]
        state.selectedListId = "l1"
        state.tasks = [makeTask(id: "existing")]

        await state.refreshForMenuPresentation()

        XCTAssertEqual(state.tasks.map(\.id), ["existing"])
        XCTAssertTrue(MockURLProtocol.requestLog.isEmpty)
    }

    func testRefreshTasksSyncsDueDateNotificationsForSelectedList() async {
        state.selectedListId = "list1"
        state.taskLists = [TaskList(id: "list1", title: "Inbox", selfLink: nil, updated: nil)]

        let dueTaskJSON = #"{"items":[{"id":"t1","title":"Due Task","status":"needsAction","due":"2026-03-15T00:00:00.000Z"}]}"#
        stubResponse(json: dueTaskJSON)

        await state.refreshTasks()

        let syncCall = await dueDateNotificationService.latestSyncCall()
        XCTAssertEqual(syncCall?.list.id, "list1")
        XCTAssertEqual(syncCall?.tasks.map(\.id), ["t1"])
    }
}

private actor DelayedTasksAPI: TasksAPIProtocol {
    private var taskLists: [TaskList]
    private var tasksByListID: [String: [TaskItem]]
    private var delaysByListID: [String: Duration]

    init(
        taskLists: [TaskList],
        tasksByListID: [String: [TaskItem]],
        delaysByListID: [String: Duration] = [:]
    ) {
        self.taskLists = taskLists
        self.tasksByListID = tasksByListID
        self.delaysByListID = delaysByListID
    }

    func setTasks(_ tasks: [TaskItem], for listID: String) {
        tasksByListID[listID] = tasks
    }

    func setDelay(_ delay: Duration, for listID: String) {
        delaysByListID[listID] = delay
    }

    func listTaskLists() async throws -> [TaskList] {
        taskLists
    }

    func listTasks(listId: String, showCompleted: Bool, showHidden: Bool) async throws -> [TaskItem] {
        if let delay = delaysByListID[listId] {
            try? await Task.sleep(for: delay)
        }

        let tasks = tasksByListID[listId] ?? []
        if showCompleted {
            return tasks
        }
        return tasks.filter { !$0.isCompleted }
    }

    func createTask(listId: String, title: String, notes: String?, due: String?, parentId: String?) async throws -> TaskItem {
        throw APIError.serverError(501, "Not implemented")
    }

    func updateTask(listId: String, taskId: String, task: TaskItem) async throws -> TaskItem {
        throw APIError.serverError(501, "Not implemented")
    }

    func deleteTask(listId: String, taskId: String) async throws {
        throw APIError.serverError(501, "Not implemented")
    }

    func moveTask(listId: String, taskId: String, previousId: String?, parentId: String?) async throws -> TaskItem {
        throw APIError.serverError(501, "Not implemented")
    }
}
