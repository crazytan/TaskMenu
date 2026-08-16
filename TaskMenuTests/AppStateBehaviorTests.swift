import XCTest
@testable import TaskMenu

/// Tests for AppState behavior: toggleTask, refreshTasks, cache management, error handling.
/// Uses MockURLProtocol to simulate API responses without hitting the network.
/// Uses MockURLProtocol.requestLog to inspect requests (avoids captured var issues with Swift 6 concurrency).
@MainActor
final class AppStateBehaviorTests: XCTestCase {
    nonisolated(unsafe) private static var capturedCreateTaskListBody: Data?
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

    private func makeState(
        api: any TasksAPIProtocol,
        menuBarCountRefreshInterval: Duration = .seconds(300)
    ) -> AppState {
        let authService = GoogleAuthService(keychain: keychain, session: MockURLProtocol.mockSession())
        return AppState(
            authService: authService,
            api: api,
            userDefaults: userDefaults,
            dueDateNotificationService: dueDateNotificationService,
            menuBarCountRefreshInterval: menuBarCountRefreshInterval
        )
    }

    private func waitUntil(_ condition: @MainActor @escaping () -> Bool) async {
        for _ in 0..<50 {
            if condition() { return }
            await Task.yield()
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    private func waitUntil(_ condition: @escaping () async -> Bool) async {
        for _ in 0..<50 {
            if await condition() { return }
            await Task.yield()
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
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

    // MARK: - toggleTask: Subtask Cascade

    func testToggleTaskCompletingParentCascadesToIncompleteSubtasks() async {
        state.selectedListId = "list1"
        state.tasks = [
            makeTask(id: "parent"),
            makeTask(id: "child-open", parent: "parent"),
            makeTask(id: "child-done", status: .completed, parent: "parent")
        ]

        MockURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            let json: String
            if request.url!.absoluteString.contains("/tasks/parent") {
                json = #"{"id":"parent","title":"Test","status":"completed"}"#
            } else {
                json = #"{"id":"child-open","title":"Test","status":"completed","parent":"parent"}"#
            }
            return (response, json.data(using: .utf8)!)
        }

        await state.toggleTask(state.tasks[0])

        XCTAssertTrue(state.tasks.allSatisfy(\.isCompleted))
        XCTAssertNil(state.errorMessage)
        // Parent is patched first, then the cascaded child; already-completed child is untouched.
        let patchedURLs = MockURLProtocol.requestLog.compactMap { $0.url?.absoluteString }
        XCTAssertEqual(patchedURLs.count, 2)
        XCTAssertTrue(patchedURLs[0].contains("/tasks/parent"))
        XCTAssertTrue(patchedURLs[1].contains("/tasks/child-open"))
    }

    func testToggleTaskParentFailureRevertsCascadeAndSkipsChildUpdates() async {
        state.selectedListId = "list1"
        state.tasks = [
            makeTask(id: "parent"),
            makeTask(id: "child-open", parent: "parent")
        ]

        stubResponse(statusCode: 500, json: #"{"error":"Internal Server Error"}"#)

        await state.toggleTask(state.tasks[0])

        XCTAssertFalse(state.tasks[0].isCompleted)
        XCTAssertFalse(state.tasks[1].isCompleted)
        XCTAssertNotNil(state.errorMessage)
        XCTAssertEqual(MockURLProtocol.requestLog.count, 1)
    }

    func testToggleTaskUncompletingParentDoesNotCascade() async {
        state.selectedListId = "list1"
        state.tasks = [
            makeTask(id: "parent", status: .completed),
            makeTask(id: "child-done", status: .completed, parent: "parent")
        ]

        stubResponse(json: #"{"id":"parent","title":"Test","status":"needsAction"}"#)

        await state.toggleTask(state.tasks[0])

        XCTAssertFalse(state.tasks[0].isCompleted)
        XCTAssertTrue(state.tasks[1].isCompleted)
        XCTAssertEqual(MockURLProtocol.requestLog.count, 1)
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

    // MARK: - refreshTasks: Always Fresh

    func testRefreshTasksFetchesFresh() async {
        state.selectedListId = "list1"
        state.taskLists = [TaskList(id: "list1", title: "Inbox", selfLink: nil, updated: nil)]

        stubResponse(json: #"{"items":[{"id":"t1","title":"Task","status":"needsAction"},{"id":"t2","title":"Done","status":"completed"}]}"#)

        await state.refreshTasks()

        XCTAssertEqual(state.tasks.count, 2)
        XCTAssertFalse(state.isLoading)
    }

    func testRefreshTasksGuardWithNoSelectedList() async {
        state.selectedListId = nil

        await state.refreshTasks()

        XCTAssertTrue(state.tasks.isEmpty)
        XCTAssertFalse(state.isLoading)
    }

    // MARK: - createTaskList

    /// `POST …/users/@me/lists` creates the list and its JSON body is captured
    /// in `capturedCreateTaskListBody`; a fetch for the new list's tasks is
    /// empty; every other request (a switch back to list1) is served by
    /// `otherJSON`.
    private func stubCreateTaskListResponses(
        createStatusCode: Int = 200,
        createJSON: String = #"{"id":"list-new","title":"Errands"}"#,
        otherJSON: String = #"{"items":[]}"#
    ) {
        Self.capturedCreateTaskListBody = nil
        MockURLProtocol.requestHandler = { request in
            let path = request.url?.path ?? ""
            let response = { (status: Int) in
                HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
            }
            if request.httpMethod == "POST", path.hasSuffix("/users/@me/lists") {
                Self.capturedCreateTaskListBody = requestBodyData(from: request)
                return (response(createStatusCode), Data(createJSON.utf8))
            }
            if path.contains("/lists/list-new/") {
                return (response(200), Data(#"{"items":[]}"#.utf8))
            }
            return (response(200), Data(otherJSON.utf8))
        }
    }

    func testCreateTaskListAppendsSelectsAndLoadsTheNewList() async throws {
        state.isSignedIn = true
        state.taskLists = [TaskList(id: "list1", title: "Inbox", selfLink: nil, updated: nil)]
        state.selectedListId = "list1"
        state.tasks = [makeTask()]
        stubCreateTaskListResponses(otherJSON: #"{"items":[{"id":"t1","title":"Test","status":"needsAction"}]}"#)

        let created = await state.createTaskList(title: "  Errands ")

        XCTAssertEqual(created?.id, "list-new")
        XCTAssertEqual(state.taskLists.map(\.id), ["list1", "list-new"])
        XCTAssertEqual(state.selectedListId, "list-new")
        XCTAssertTrue(state.tasks.isEmpty)
        XCTAssertNil(state.errorMessage)

        XCTAssertEqual(MockURLProtocol.requestLog.filter { $0.httpMethod == "POST" }.count, 1)
        let body = try XCTUnwrap(Self.capturedCreateTaskListBody)
        XCTAssertEqual(try JSONSerialization.jsonObject(with: body) as? [String: String], ["title": "Errands"])
        let paths = MockURLProtocol.requestLog.compactMap { $0.url?.path }
        XCTAssertEqual(paths.count, 2)
        XCTAssertTrue(paths[0].hasSuffix("/users/@me/lists"), paths[0])
        XCTAssertTrue(paths[1].contains("/lists/list-new/tasks"), paths[1])

        // Switching back goes through the normal cache/refresh path.
        await state.selectList("list1")
        XCTAssertEqual(state.selectedListId, "list1")
        XCTAssertEqual(state.tasks.map(\.id), ["t1"])
    }

    func testCreateTaskListIgnoresBlankTitle() async {
        state.isSignedIn = true
        state.taskLists = [TaskList(id: "list1", title: "Inbox", selfLink: nil, updated: nil)]
        state.selectedListId = "list1"
        stubCreateTaskListResponses()

        let created = await state.createTaskList(title: "   ")

        XCTAssertNil(created)
        XCTAssertTrue(MockURLProtocol.requestLog.isEmpty)
        XCTAssertEqual(state.taskLists.map(\.id), ["list1"])
        XCTAssertEqual(state.selectedListId, "list1")
    }

    func testCreateTaskListFailureSetsErrorAndKeepsSelection() async {
        state.isSignedIn = true
        state.taskLists = [TaskList(id: "list1", title: "Inbox", selfLink: nil, updated: nil)]
        state.selectedListId = "list1"
        state.tasks = [makeTask()]
        stubCreateTaskListResponses(createStatusCode: 500, createJSON: "boom")

        let created = await state.createTaskList(title: "Errands")

        XCTAssertNil(created)
        XCTAssertEqual(state.errorMessage?.hasPrefix("Server error 500"), true)
        XCTAssertEqual(state.taskLists.map(\.id), ["list1"])
        XCTAssertEqual(state.selectedListId, "list1")
        XCTAssertEqual(state.tasks.map(\.id), ["t1"])
    }

    func testCreateTaskListResultIsDiscardedAfterSignOut() async {
        let api = DelayedTasksAPI(
            taskLists: [TaskList(id: "list1", title: "Inbox", selfLink: nil, updated: nil)],
            tasksByListID: ["list1": []]
        )
        await api.setCreateTaskListDelay(.milliseconds(200))
        let state = makeState(api: api)
        state.isSignedIn = true
        state.taskLists = [TaskList(id: "list1", title: "Inbox", selfLink: nil, updated: nil)]
        state.selectedListId = "list1"

        let creation = Task { await state.createTaskList(title: "Errands") }
        // Sign out only once the request is in flight, so the guard under test
        // is the one after the await, not the entry guard.
        await waitUntil { await api.createTaskListCallCount == 1 }
        XCTAssertTrue(state.isSignedIn)
        state.signOut()
        let created = await creation.value

        XCTAssertNil(created)
        XCTAssertFalse(state.isSignedIn)
        XCTAssertTrue(state.taskLists.isEmpty)
        XCTAssertNil(state.selectedListId)
        XCTAssertNil(state.errorMessage)
    }

    func testCreateTaskListDoesNothingWhenSignedOut() async {
        state.isSignedIn = false
        stubCreateTaskListResponses()

        let created = await state.createTaskList(title: "Errands")

        XCTAssertNil(created)
        XCTAssertTrue(MockURLProtocol.requestLog.isEmpty)
        XCTAssertTrue(state.taskLists.isEmpty)
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

    func testAddTaskReturnsCreatedTask() async {
        state.selectedListId = "list1"

        stubResponse(json: #"{"id":"new1","title":"New Task","status":"needsAction"}"#)

        let created = await state.addTask(title: "New Task")

        XCTAssertEqual(created?.id, "new1")
    }

    func testAddTaskReturnsNilOnFailure() async {
        state.selectedListId = "list1"

        stubResponse(statusCode: 500, json: "")

        let created = await state.addTask(title: "New Task")

        XCTAssertNil(created)
        XCTAssertTrue(state.tasks.isEmpty)
        XCTAssertNotNil(state.errorMessage)
    }

    // MARK: - addSubtask

    /// A right-click "Add Subtask" hits `tasks.insert` with a parent and no
    /// `previous`, which Google stores as the first child while renumbering
    /// the siblings. The response only carries the new task's position, so it
    /// ties with the former first child's stale position; the subtask still
    /// has to show up first, where the server (and a refresh) put it.
    func testAddSubtaskShowsNewSubtaskFirstDespiteStaleSiblingPositions() async {
        state.selectedListId = "list1"
        state.tasks = [
            makeTask(id: "parent", position: "00000000000000000000"),
            makeTask(id: "child-a", parent: "parent", position: "00000000000000000000"),
            makeTask(id: "child-b", parent: "parent", position: "00000000000000000001"),
            makeTask(id: "other", position: "00000000000000000001"),
        ]

        stubResponse(json: #"{"id":"new","title":"New Sub","status":"needsAction","parent":"parent","position":"00000000000000000000"}"#)

        let created = await state.addSubtask(title: "New Sub", parentId: "parent")

        XCTAssertEqual(created?.id, "new")
        XCTAssertEqual(state.subtasks(of: "parent").map(\.id), ["new", "child-a", "child-b"])
        XCTAssertEqual(state.rootTasks.map(\.id), ["parent", "other"])
        XCTAssertNil(state.errorMessage)

        let request = MockURLProtocol.requestLog.last
        XCTAssertEqual(request?.httpMethod, "POST")
        XCTAssertEqual(request?.url?.query, "parent=parent")
    }

    func testAddSubtaskFilesTaskUnderRequestedParent() async {
        state.selectedListId = "list1"
        state.tasks = [makeTask(id: "parent", position: "00000000000000000000")]

        stubResponse(json: #"{"id":"new","title":"New Sub","status":"needsAction","position":"00000000000000000000"}"#)

        await state.addSubtask(title: "New Sub", parentId: "parent")

        XCTAssertEqual(state.subtasks(of: "parent").map(\.id), ["new"])
        XCTAssertEqual(state.rootTasks.map(\.id), ["parent"])
        XCTAssertEqual(state.tasks.map(\.id), ["parent", "new"])
    }

    func testAddSubtaskReturnsNilOnFailureAndLeavesTasksAlone() async {
        state.selectedListId = "list1"
        state.tasks = [
            makeTask(id: "parent", position: "00000000000000000000"),
            makeTask(id: "child-a", parent: "parent", position: "00000000000000000000"),
        ]

        stubResponse(statusCode: 500, json: "")

        let created = await state.addSubtask(title: "New Sub", parentId: "parent")

        XCTAssertNil(created)
        XCTAssertEqual(state.subtasks(of: "parent").map(\.id), ["child-a"])
        XCTAssertNotNil(state.errorMessage)
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

    func testUpdateTaskStoresServerDueDateResponse() async {
        state.selectedListId = "list1"
        var task = makeTask()
        task.due = "2026-04-01T00:00:00.000Z"
        state.tasks = [makeTask()]

        stubResponse(json: #"{"id":"t1","title":"Test","status":"needsAction","due":"2026-04-02T00:00:00.000Z"}"#)

        await state.updateTask(task)

        XCTAssertEqual(state.tasks[0].due, "2026-04-02T00:00:00.000Z")
    }

    func testUpdateTaskStoresClearedServerDueDateResponse() async {
        state.selectedListId = "list1"
        var existingTask = makeTask()
        existingTask.due = "2026-04-01T00:00:00.000Z"
        var updatedTask = existingTask
        updatedTask.clearDueDate()
        state.tasks = [existingTask]

        stubResponse(json: #"{"id":"t1","title":"Test","status":"needsAction"}"#)

        await state.updateTask(updatedTask)

        XCTAssertNil(state.tasks[0].due)
        XCTAssertNil(state.tasks[0].dueDate)
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

    // MARK: - launch bootstrap

    func testBootstrapSignedInStateLoadsListsAndTasksOnLaunch() async {
        state.isSignedIn = true

        MockURLProtocol.requestHandler = { request in
            let url = request.url!.absoluteString
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!

            if url.contains("/users/@me/lists") {
                let json = #"{"items":[{"id":"l1","title":"My Tasks"}]}"#
                return (response, json.data(using: .utf8)!)
            } else {
                let json = #"{"items":[{"id":"t1","title":"Launch Task","status":"needsAction"}]}"#
                return (response, json.data(using: .utf8)!)
            }
        }

        await state.bootstrapSignedInState()

        XCTAssertEqual(state.selectedListId, "l1")
        XCTAssertEqual(state.tasks.map(\.id), ["t1"])
        XCTAssertTrue(state.hasCompletedInitialTaskLoad)
        XCTAssertFalse(state.isShowingInitialTaskLoad)
    }

    func testBootstrapSignedInStateDoesNothingWhenSignedOut() async {
        state.isSignedIn = false

        await state.bootstrapSignedInState()

        XCTAssertTrue(MockURLProtocol.requestLog.isEmpty)
        XCTAssertFalse(state.hasCompletedInitialTaskLoad)
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

    // MARK: - moveTask

    func testMoveTaskAppliesOptimisticReorderAndCallsMoveEndpoint() async {
        state.selectedListId = "list1"
        state.tasks = [
            makeTask(id: "first", position: "00000001"),
            makeTask(id: "second", position: "00000002"),
            makeTask(id: "third", position: "00000003")
        ]

        stubResponse(json: #"{"id":"third","title":"Test","status":"needsAction","position":"00000000000000000001"}"#)

        await state.moveTask(state.tasks[2], toParent: nil, after: "first")

        XCTAssertEqual(state.rootTasks.map(\.id), ["first", "third", "second"])
        XCTAssertNil(state.errorMessage)

        let request = MockURLProtocol.requestLog.last
        XCTAssertEqual(request?.httpMethod, "POST")
        let url = request?.url?.absoluteString ?? ""
        XCTAssertTrue(url.contains("/lists/list1/tasks/third/move"))
        XCTAssertTrue(url.contains("previous=first"))
        XCTAssertFalse(url.contains("parent="))
    }

    func testMoveTaskReparentsSubtaskAndSendsParentParam() async {
        state.selectedListId = "list1"
        state.tasks = [
            makeTask(id: "parent-a", position: "00000001"),
            makeTask(id: "child", parent: "parent-a", position: "00000001"),
            makeTask(id: "parent-b", position: "00000002")
        ]

        stubResponse(json: #"{"id":"child","title":"Test","status":"needsAction","parent":"parent-b","position":"00000000000000000000"}"#)

        await state.moveTask(state.tasks[1], toParent: "parent-b", after: nil)

        XCTAssertEqual(state.subtasks(of: "parent-a").map(\.id), [])
        XCTAssertEqual(state.subtasks(of: "parent-b").map(\.id), ["child"])
        XCTAssertNil(state.errorMessage)

        let url = MockURLProtocol.requestLog.last?.url?.absoluteString ?? ""
        XCTAssertTrue(url.contains("/lists/list1/tasks/child/move"))
        XCTAssertTrue(url.contains("parent=parent-b"))
        XCTAssertFalse(url.contains("previous="))
    }

    func testMoveTaskRollsBackOnServerError() async {
        state.selectedListId = "list1"
        state.tasks = [
            makeTask(id: "first", position: "00000001"),
            makeTask(id: "second", position: "00000002")
        ]

        stubResponse(statusCode: 500, json: #"{"error":"boom"}"#)

        await state.moveTask(state.tasks[1], toParent: nil, after: nil)

        XCTAssertEqual(state.rootTasks.map(\.id), ["first", "second"])
        XCTAssertNotNil(state.errorMessage)
    }

    func testMoveTaskSkipsDropThatDoesNotChangeOrder() async {
        state.selectedListId = "list1"
        state.tasks = [
            makeTask(id: "first", position: "00000001"),
            makeTask(id: "second", position: "00000002")
        ]

        await state.moveTask(state.tasks[1], toParent: nil, after: "first")

        XCTAssertEqual(state.rootTasks.map(\.id), ["first", "second"])
        XCTAssertTrue(MockURLProtocol.requestLog.isEmpty)
        XCTAssertNil(state.errorMessage)
    }

    func testMoveTaskIsIgnoredWhileSortedByDueDate() async {
        state.selectedListId = "list1"
        state.taskSortOrder = .dueDate
        state.tasks = [
            makeTask(id: "first", position: "00000001"),
            makeTask(id: "second", position: "00000002"),
            makeTask(id: "third", position: "00000003")
        ]

        await state.moveTask(state.tasks[2], toParent: nil, after: "first")

        XCTAssertEqual(state.tasks.map(\.id), ["first", "second", "third"])
        XCTAssertTrue(MockURLProtocol.requestLog.isEmpty)
        XCTAssertNil(state.errorMessage)
    }

    func testMoveTaskIgnoresInvalidMove() async {
        state.selectedListId = "list1"
        state.tasks = [
            makeTask(id: "parent", position: "00000001"),
            makeTask(id: "child", parent: "parent", position: "00000001")
        ]

        await state.moveTask(state.tasks[0], toParent: "child", after: nil)

        XCTAssertEqual(state.rootTasks.map(\.id), ["parent"])
        XCTAssertTrue(MockURLProtocol.requestLog.isEmpty)
        XCTAssertNil(state.errorMessage)
    }

    // MARK: - moveTask(_:toList:)

    private var crossListLists: [TaskList] {
        [
            TaskList(id: "list1", title: "Inbox", selfLink: nil, updated: nil),
            TaskList(id: "list2", title: "Later", selfLink: nil, updated: nil)
        ]
    }

    private var crossListSourceTasks: [TaskItem] {
        [
            makeTask(id: "first", position: "00000000000000000001"),
            makeTask(id: "parent", position: "00000000000000000002"),
            makeTask(id: "child", parent: "parent", position: "00000000000000000001"),
            makeTask(id: "other", position: "00000000000000000003")
        ]
    }

    func testMoveTaskToListRemovesTreeFromSourceInsertsFirstInDestinationAndCallsMoveEndpoint() async {
        state.taskLists = crossListLists
        state.selectedListId = "list1"
        state.tasks = crossListSourceTasks
        stubResponse(json: #"{"id":"parent","title":"Test","status":"needsAction","position":"00000000000000000000"}"#)

        await state.moveTask(state.tasks[1], toList: "list2")

        XCTAssertEqual(state.tasks.map(\.id), ["first", "other"])
        let destination = state.cachedTasks(forListID: "list2")
        XCTAssertEqual(destination?.map(\.id), ["parent", "child"])
        XCTAssertEqual(destination?.first?.position, "00000000000000000000")
        XCTAssertNil(destination?.first?.parent)
        XCTAssertEqual(destination?.last?.parent, "parent")
        XCTAssertNil(state.errorMessage)

        let request = MockURLProtocol.requestLog.last
        XCTAssertEqual(request?.httpMethod, "POST")
        let url = request?.url?.absoluteString ?? ""
        XCTAssertTrue(url.contains("/lists/list1/tasks/parent/move"))
        XCTAssertTrue(url.contains("destinationTasklist=list2"))
        XCTAssertFalse(url.contains("parent="))
        XCTAssertFalse(url.contains("previous="))
    }

    func testMoveTaskToListLandsFirstAmongExistingDestinationRoots() async {
        let api = DelayedTasksAPI(
            taskLists: crossListLists,
            tasksByListID: [
                "list1": [makeTask(id: "a", position: "00000000000000000000"), makeTask(id: "b", position: "00000000000000000001")],
                "list2": [makeTask(id: "x", position: "00000000000000000000"), makeTask(id: "y", position: "00000000000000000001")]
            ]
        )
        await api.setMoveTaskSuccess()
        let state = makeState(api: api)
        state.isSignedIn = true
        state.taskLists = crossListLists
        await state.selectList("list2")
        await state.selectList("list1")

        await state.moveTask(state.tasks[0], toList: "list2")

        let destinationRoots = tasksSortedByGooglePosition(
            (state.cachedTasks(forListID: "list2") ?? []).filter { $0.parent == nil }
        )
        XCTAssertEqual(destinationRoots.map(\.id), ["a", "x", "y"])
        XCTAssertEqual(
            destinationRoots.map(\.position),
            ["00000000000000000000", "00000000000000000001", "00000000000000000002"]
        )
        XCTAssertEqual(state.tasks.map(\.id), ["b"])
        let moveCalls = await api.moveCalls
        XCTAssertEqual(moveCalls.last?.destinationListId, "list2")
        XCTAssertEqual(moveCalls.last?.listId, "list1")
        XCTAssertNil(moveCalls.last?.parentId)
        XCTAssertNil(moveCalls.last?.previousTaskId)
        // The fake applied the move server-side too, so a refresh agrees.
        let serverDestination = await api.tasks(for: "list2")
        XCTAssertEqual(tasksSortedByGooglePosition(serverDestination).map(\.id), ["a", "x", "y"])
        XCTAssertNil(state.errorMessage)
    }

    func testMoveTaskToListRollsBackBothListsOnServerError() async {
        state.taskLists = crossListLists
        state.selectedListId = "list1"
        state.tasks = crossListSourceTasks
        stubResponse(statusCode: 500, json: #"{"error":"boom"}"#)

        await state.moveTask(state.tasks[1], toList: "list2")

        XCTAssertEqual(state.rootTasks.map(\.id), ["first", "parent", "other"])
        XCTAssertEqual(state.subtasks(of: "parent").map(\.id), ["child"])
        XCTAssertFalse((state.cachedTasks(forListID: "list2") ?? []).contains { $0.id == "parent" })
        XCTAssertNotNil(state.errorMessage)
    }

    func testMoveTaskToListIgnoresSubtasksAndSameList() async {
        state.taskLists = crossListLists
        state.selectedListId = "list1"
        state.tasks = crossListSourceTasks
        let originalIDs = state.tasks.map(\.id)

        await state.moveTask(state.tasks[2], toList: "list2")
        await state.moveTask(state.tasks[1], toList: "list1")

        XCTAssertTrue(MockURLProtocol.requestLog.isEmpty)
        XCTAssertEqual(state.tasks.map(\.id), originalIDs)
        XCTAssertNil(state.cachedTasks(forListID: "list2"))
        XCTAssertNil(state.errorMessage)
    }

    func testMoveTaskToListRemovesSourceRemindersAndSyncsBothLists() async {
        let api = DelayedTasksAPI(
            taskLists: crossListLists,
            tasksByListID: ["list1": crossListSourceTasks, "list2": [makeTask(id: "x", position: "00000000000000000000")]]
        )
        await api.setMoveTaskSuccess()
        let state = makeState(api: api)
        state.isSignedIn = true
        state.taskLists = crossListLists
        await state.selectList("list2")
        await state.selectList("list1")
        let notificationService: TestDueDateNotificationService = dueDateNotificationService
        let eventsBefore = await notificationService.eventLog.count

        await state.moveTask(state.tasks[1], toList: "list2")

        await waitUntil { await notificationService.eventLog.count >= eventsBefore + 3 }
        let events = await notificationService.eventLog
        XCTAssertEqual(Array(events.suffix(3)), ["removeTasks", "sync", "sync"])
        let removedListIDs = await notificationService.removedListIDs
        let removedTaskIDs = await notificationService.removedTaskIDs
        XCTAssertEqual(removedListIDs.last, "list1")
        XCTAssertEqual(removedTaskIDs.last, ["parent", "child"])
        let syncCalls = await notificationService.syncCalls
        XCTAssertEqual(syncCalls.suffix(2).map(\.list.id), ["list1", "list2"])
        XCTAssertFalse(syncCalls.suffix(2).first?.tasks.contains { $0.id == "parent" } ?? true)
        XCTAssertTrue(syncCalls.last?.tasks.contains { $0.id == "parent" } ?? false)
    }

    func testMoveTaskToListSkipsDestinationSyncWithoutDestinationCache() async {
        let api = DelayedTasksAPI(
            taskLists: crossListLists,
            tasksByListID: ["list1": crossListSourceTasks, "list2": []]
        )
        await api.setMoveTaskSuccess()
        let state = makeState(api: api)
        state.isSignedIn = true
        state.taskLists = crossListLists
        await state.selectList("list1")
        let notificationService: TestDueDateNotificationService = dueDateNotificationService
        let eventsBefore = await notificationService.eventLog.count

        await state.moveTask(state.tasks[1], toList: "list2")

        await waitUntil { await notificationService.eventLog.count >= eventsBefore + 2 }
        // Give a stray destination sync a chance to land before asserting it did not.
        try? await Task.sleep(nanoseconds: 50_000_000)
        let events = await notificationService.eventLog
        XCTAssertEqual(Array(events.suffix(2)), ["removeTasks", "sync"])
        XCTAssertEqual(events.count, eventsBefore + 2)
        let syncCalls = await notificationService.syncCalls
        XCTAssertEqual(syncCalls.last?.list.id, "list1")
        XCTAssertEqual(state.cachedTasks(forListID: "list2")?.map(\.id), ["parent", "child"])
    }

    /// A second move into a list whose cache was only seeded by the first
    /// move must not sync that partial cache either (it would wipe the
    /// list's other reminders); once the list is actually loaded, syncs resume.
    func testMoveTaskToListKeepsSkippingDestinationSyncWhileCacheIsOnlyMovedTrees() async {
        let api = DelayedTasksAPI(
            taskLists: crossListLists,
            tasksByListID: ["list1": crossListSourceTasks, "list2": [makeTask(id: "x", position: "00000000000000000000")]]
        )
        await api.setMoveTaskSuccess()
        let state = makeState(api: api)
        state.isSignedIn = true
        state.taskLists = crossListLists
        await state.selectList("list1")
        let notificationService: TestDueDateNotificationService = dueDateNotificationService

        await state.moveTask(state.tasks[1], toList: "list2")
        let eventsBetween = await notificationService.eventLog.count
        await state.moveTask(state.tasks[0], toList: "list2")

        await waitUntil { await notificationService.eventLog.count >= eventsBetween + 2 }
        try? await Task.sleep(nanoseconds: 50_000_000)
        let events = await notificationService.eventLog
        XCTAssertEqual(Array(events.suffix(2)), ["removeTasks", "sync"], "still only the source list is synced")
        XCTAssertEqual(events.count, eventsBetween + 2)
        let syncCalls = await notificationService.syncCalls
        XCTAssertFalse(syncCalls.contains { $0.list.id == "list2" })
        XCTAssertEqual(state.cachedTasks(forListID: "list2")?.map(\.id), ["first", "parent", "child"])

        // Loading the list replaces the partial cache with the server's, and
        // that load's own sync covers every task in it.
        await state.selectList("list2")
        let list2Sync = await notificationService.syncCalls.last { $0.list.id == "list2" }
        XCTAssertEqual(
            Set(list2Sync?.tasks.map(\.id) ?? []),
            ["first", "parent", "child", "x"],
            "the full list is synced once fetched"
        )
    }

    func testMoveTaskToListWithDemoAPIShowsTaskFirstInDestinationAfterRefresh() async {
        let state = makeState(api: DemoTasksAPI())
        state.isSignedIn = true
        state.selectedListId = "demo-today"
        await state.refreshTasks()
        guard let review = state.tasks.first(where: { $0.id == "today-review" }) else {
            return XCTFail("Expected the seeded demo task")
        }
        XCTAssertEqual(state.subtasks(of: "today-review").count, 2)

        await state.moveTask(review, toList: "demo-work")

        XCTAssertFalse(state.tasks.contains { $0.id == "today-review" || $0.parent == "today-review" })
        XCTAssertNil(state.errorMessage)

        await state.selectList("demo-work")
        XCTAssertEqual(state.rootTasks.first?.id, "today-review")
        XCTAssertEqual(state.subtasks(of: "today-review").map(\.id), ["today-review-api", "today-review-tests"])
        XCTAssertEqual(
            state.rootTasks.map(\.id),
            ["today-review", "work-launch", "work-roadmap", "work-onemore", "work-retro"]
        )
    }

    func testMoveTaskToListDiscardsResultAfterSignOut() async {
        let api = DelayedTasksAPI(taskLists: crossListLists, tasksByListID: ["list1": crossListSourceTasks, "list2": []])
        await api.setMoveTaskSuccess(delay: .milliseconds(200))
        let state = makeState(api: api)
        state.taskLists = crossListLists
        state.selectedListId = "list1"
        state.tasks = crossListSourceTasks

        let moveHandle = Task { await state.moveTask(state.tasks[1], toList: "list2") }
        await Task.yield()
        XCTAssertEqual(state.tasks.map(\.id), ["first", "other"])

        state.signOut()
        await moveHandle.value

        XCTAssertTrue(state.tasks.isEmpty)
        XCTAssertNil(state.cachedTasks(forListID: "list2"))
        XCTAssertNil(state.errorMessage)
    }

    // MARK: - deleteTask: Transitive Descendants

    func testDeleteTaskRemovesTransitiveDescendants() async {
        state.selectedListId = "list1"
        state.taskLists = [TaskList(id: "list1", title: "Inbox", selfLink: nil, updated: nil)]
        state.tasks = [
            makeTask(id: "parent"),
            makeTask(id: "child", parent: "parent"),
            makeTask(id: "grandchild", parent: "child"),
            makeTask(id: "unrelated")
        ]

        MockURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, Data())
        }

        await state.deleteTask(state.tasks[0])

        // The nested grandchild must not linger as an invisible orphan, and
        // its due-date notification must be removed with the rest.
        XCTAssertEqual(state.tasks.map(\.id), ["unrelated"])
        let removedTaskIDs = await dueDateNotificationService.removedTaskIDs
        XCTAssertEqual(removedTaskIDs, [["parent", "child", "grandchild"]])
    }

    // MARK: - Interleaving: mutations vs. loads

    func testRefreshTasksDoesNotClobberTaskAddedDuringFetch() async {
        let api = DelayedTasksAPI(
            taskLists: [TaskList(id: "list1", title: "Inbox", selfLink: nil, updated: nil)],
            tasksByListID: ["list1": [makeTask(id: "existing", title: "Existing")]],
            delaysByListID: ["list1": .milliseconds(200)]
        )
        let state = makeState(api: api)
        state.taskLists = [TaskList(id: "list1", title: "Inbox", selfLink: nil, updated: nil)]
        state.selectedListId = "list1"
        state.tasks = [makeTask(id: "existing", title: "Existing")]

        let refreshTask = Task { await state.refreshTasks() }
        await waitUntil { state.isLoading }

        await state.addTask(title: "Quick Add")
        XCTAssertEqual(state.tasks.first?.id, "created-Quick Add")

        await refreshTask.value

        // The fetch snapshot predates the add and must be discarded.
        XCTAssertEqual(state.tasks.map(\.id), ["created-Quick Add", "existing"])
        XCTAssertFalse(state.isLoading)
    }

    func testAddTaskDuringListSwitchCommitsToOriginalList() async {
        let lists = [
            TaskList(id: "list1", title: "Inbox", selfLink: nil, updated: nil),
            TaskList(id: "list2", title: "Work", selfLink: nil, updated: nil)
        ]
        let api = DelayedTasksAPI(
            taskLists: lists,
            tasksByListID: [
                "list1": [makeTask(id: "list1-task")],
                "list2": [makeTask(id: "list2-task")]
            ]
        )
        await api.setCreateTaskDelay(.milliseconds(200))
        let state = makeState(api: api)
        state.taskLists = lists
        state.selectedListId = "list1"
        state.tasks = [makeTask(id: "list1-task")]

        let addTaskHandle = Task { await state.addTask(title: "For List 1") }
        await Task.yield()

        await state.selectList("list2")
        XCTAssertEqual(state.tasks.map(\.id), ["list2-task"])

        _ = await addTaskHandle.value

        // The created task belongs to list1 and must not leak into list2.
        XCTAssertEqual(state.selectedListId, "list2")
        XCTAssertFalse(state.tasks.contains { $0.id == "created-For List 1" })

        // Switching back surfaces it from list1's cache before the refresh lands.
        await api.setDelay(.milliseconds(200), for: "list1")
        let switchBack = Task { await state.selectList("list1") }
        await waitUntil { state.selectedListId == "list1" }
        XCTAssertTrue(state.tasks.contains { $0.id == "created-For List 1" })
        await switchBack.value
    }

    func testToggleTaskFailureRevertPreservesEditCommittedDuringRequest() async {
        let task = makeTask(id: "t1", title: "Old Title")
        let api = DelayedTasksAPI(
            taskLists: [TaskList(id: "list1", title: "Inbox", selfLink: nil, updated: nil)],
            tasksByListID: ["list1": [task]]
        )
        // First update (the toggle) fails slowly; second (the edit) succeeds.
        await api.addUpdateStub(
            forTaskID: "t1",
            delay: .milliseconds(200),
            result: .failure(.serverError(500, "boom"))
        )
        await api.addUpdateStub(
            forTaskID: "t1",
            result: .success(makeTask(id: "t1", title: "New Title", status: .completed))
        )
        let state = makeState(api: api)
        state.taskLists = [TaskList(id: "list1", title: "Inbox", selfLink: nil, updated: nil)]
        state.selectedListId = "list1"
        state.tasks = [task]

        let toggleHandle = Task { await state.toggleTask(task) }
        await waitUntil { await api.updateTaskCallCount == 1 }
        XCTAssertTrue(state.tasks[0].isCompleted)

        var edited = state.tasks[0]
        edited.title = "New Title"
        await state.updateTask(edited)
        XCTAssertEqual(state.tasks[0].title, "New Title")

        await toggleHandle.value

        // The failed toggle rewinds only the completion status; the title
        // edit committed while the toggle was in flight survives.
        XCTAssertEqual(state.tasks[0].title, "New Title")
        XCTAssertFalse(state.tasks[0].isCompleted)
        XCTAssertNotNil(state.errorMessage)
    }

    func testMoveTaskFailureRollbackPreservesToggleCommittedDuringMove() async {
        let api = DelayedTasksAPI(
            taskLists: [TaskList(id: "list1", title: "Inbox", selfLink: nil, updated: nil)],
            tasksByListID: [:]
        )
        await api.setMoveTaskFailure(delay: .milliseconds(200), error: .serverError(500, "boom"))
        await api.addUpdateStub(
            forTaskID: "second",
            result: .success(makeTask(id: "second", status: .completed, position: "00000000000000000002"))
        )
        let state = makeState(api: api)
        state.taskLists = [TaskList(id: "list1", title: "Inbox", selfLink: nil, updated: nil)]
        state.selectedListId = "list1"
        state.tasks = [
            makeTask(id: "first", position: "00000001"),
            makeTask(id: "second", position: "00000002"),
            makeTask(id: "third", position: "00000003")
        ]

        let moveHandle = Task { await state.moveTask(state.tasks[2], toParent: nil, after: "first") }
        await Task.yield()
        XCTAssertEqual(state.rootTasks.map(\.id), ["first", "third", "second"])

        await state.toggleTask(state.tasks.first { $0.id == "second" }!)
        XCTAssertTrue(state.tasks.first { $0.id == "second" }!.isCompleted)

        await moveHandle.value

        // The rollback undoes only the move; the toggle that committed while
        // the move was in flight survives.
        XCTAssertEqual(state.rootTasks.map(\.id), ["first", "second", "third"])
        XCTAssertTrue(state.tasks.first { $0.id == "second" }!.isCompleted)
        XCTAssertNotNil(state.errorMessage)
    }

    // MARK: - Interleaving: sign-out vs. in-flight work

    func testSignOutDuringLoadTaskListsDiscardsResponse() async {
        let api = DelayedTasksAPI(
            taskLists: [TaskList(id: "list1", title: "Inbox", selfLink: nil, updated: nil)],
            tasksByListID: [:]
        )
        await api.setListTaskListsDelay(.milliseconds(200))
        let state = makeState(api: api)
        XCTAssertTrue(state.isSignedIn)

        let loadHandle = Task { await state.loadTaskLists() }
        await waitUntil { state.isLoading }

        state.signOut()
        await loadHandle.value

        // The stale response must not repopulate signed-out state or surface
        // a "session expired" error to a user who deliberately signed out.
        XCTAssertFalse(state.isSignedIn)
        XCTAssertTrue(state.taskLists.isEmpty)
        XCTAssertNil(state.selectedListId)
        XCTAssertNil(state.errorMessage)
        XCTAssertFalse(state.hasCompletedInitialTaskLoad)
        XCTAssertFalse(state.isLoading)
    }

    func testSignOutDuringAddTaskDoesNotRestoreClearedState() async {
        let api = DelayedTasksAPI(
            taskLists: [TaskList(id: "list1", title: "Inbox", selfLink: nil, updated: nil)],
            tasksByListID: ["list1": []]
        )
        await api.setCreateTaskDelay(.milliseconds(200))
        let state = makeState(api: api)
        state.taskLists = [TaskList(id: "list1", title: "Inbox", selfLink: nil, updated: nil)]
        state.selectedListId = "list1"

        let addHandle = Task { await state.addTask(title: "Ghost") }
        await Task.yield()

        state.signOut()
        let created = await addHandle.value

        XCTAssertNil(created)
        XCTAssertTrue(state.tasks.isEmpty)
        XCTAssertNil(state.selectedListId)

        // The sign-out's removeAll must be the final notification operation;
        // no sync may be enqueued after it.
        let notificationService: TestDueDateNotificationService = dueDateNotificationService
        await waitUntil { await notificationService.removeAllCallCount == 1 }
        let events = await dueDateNotificationService.eventLog
        XCTAssertEqual(events, ["removeAll"])
    }

    // MARK: - Menu-bar counter: background sweep and periodic refresh

    private var counterLists: [TaskList] {
        [
            TaskList(id: "l1", title: "Inbox", selfLink: nil, updated: nil),
            TaskList(id: "l2", title: "Work", selfLink: nil, updated: nil),
            TaskList(id: "l3", title: "Home", selfLink: nil, updated: nil)
        ]
    }

    private func makeDueTask(id: String, dueInDays: Int) -> TaskItem {
        var task = makeTask(id: id)
        task.due = DateFormatting.formatGoogleTaskDueDate(
            Calendar.current.date(byAdding: .day, value: dueInDays, to: Date()) ?? Date()
        )
        return task
    }

    /// l1: 2 open + 1 completed; l2: 3 open (one overdue); l3: 1 open.
    private func makeCounterAPI(delaysByListID: [String: Duration] = [:]) -> DelayedTasksAPI {
        DelayedTasksAPI(
            taskLists: counterLists,
            tasksByListID: [
                "l1": [makeTask(id: "a1"), makeTask(id: "a2"), makeTask(id: "a-done", status: .completed)],
                "l2": [makeTask(id: "b1"), makeTask(id: "b2"), makeDueTask(id: "b-overdue", dueInDays: -1)],
                "l3": [makeTask(id: "c1")]
            ],
            delaysByListID: delaysByListID
        )
    }

    func testLoadTaskListsFetchesOtherListsForMenuBarCounterWithoutDelayingTheSelectedList() async {
        let api = makeCounterAPI(delaysByListID: ["l2": .milliseconds(200)])
        let state = makeState(api: api)
        state.menuBarCounterMode = .openTasks
        defer { state.menuBarCounterMode = .off }

        await state.loadTaskLists()

        // The visible load returns as soon as the selected list is in.
        XCTAssertEqual(state.tasks.map(\.id), ["a1", "a2", "a-done"])
        XCTAssertFalse(state.isLoading)
        XCTAssertEqual(state.menuBarPendingCount, 2)
        XCTAssertTrue(state.isMenuBarCountRefreshLoopRunning)

        await waitUntil { state.menuBarPendingCount == 6 }
        XCTAssertEqual(state.menuBarPendingCount, 6)
        XCTAssertFalse(state.isLoading)
        XCTAssertNil(state.errorMessage)
        let calls = await api.listTasksCallsByListID
        XCTAssertEqual(calls["l1"], 1)
        XCTAssertEqual(calls["l2"], 1)
        XCTAssertEqual(calls["l3"], 1)
    }

    func testLoadTaskListsDoesNotFetchOtherListsWhenMenuBarCounterIsOff() async {
        let api = makeCounterAPI()
        let state = makeState(api: api)
        XCTAssertEqual(state.menuBarCounterMode, .off)

        await state.loadTaskLists()
        try? await Task.sleep(for: .milliseconds(50))

        let calls = await api.listTasksCallsByListID
        XCTAssertEqual(calls["l1"], 1)
        XCTAssertNil(calls["l2"])
        XCTAssertNil(calls["l3"])
        XCTAssertEqual(state.menuBarPendingCount, 0)
        XCTAssertFalse(state.isMenuBarCountRefreshLoopRunning)
    }

    func testEnablingMenuBarCounterFetchesOtherListsAndStartsTheLoop() async {
        let api = makeCounterAPI()
        let state = makeState(api: api)
        await state.loadTaskLists()
        XCTAssertFalse(state.isMenuBarCountRefreshLoopRunning)

        state.menuBarCounterMode = .openTasks
        defer { state.menuBarCounterMode = .off }
        XCTAssertTrue(state.isMenuBarCountRefreshLoopRunning)

        await waitUntil { state.menuBarPendingCount == 6 }
        XCTAssertEqual(state.menuBarPendingCount, 6)
        let calls = await api.listTasksCallsByListID
        XCTAssertEqual(calls["l2"], 1)
        XCTAssertEqual(calls["l3"], 1)
    }

    func testSwitchingBetweenOpenAndDueTodayDoesNotRefetch() async {
        let api = makeCounterAPI()
        let state = makeState(api: api)
        state.menuBarCounterMode = .openTasks
        defer { state.menuBarCounterMode = .off }
        await state.loadTaskLists()
        await waitUntil { state.menuBarPendingCount == 6 }
        let callsBefore = await api.listTasksCallsByListID

        state.menuBarCounterMode = .dueToday
        XCTAssertEqual(state.menuBarPendingCount, 1)
        try? await Task.sleep(for: .milliseconds(50))

        let callsAfter = await api.listTasksCallsByListID
        XCTAssertEqual(callsAfter, callsBefore)
        XCTAssertTrue(state.isMenuBarCountRefreshLoopRunning)

        state.menuBarCounterMode = .openTasks
        XCTAssertEqual(state.menuBarPendingCount, 6)
    }

    func testMenuBarCounterRefreshesPeriodicallyAndStopsWhenDisabled() async {
        let api = makeCounterAPI()
        let state = makeState(api: api, menuBarCountRefreshInterval: .milliseconds(20))
        state.menuBarCounterMode = .openTasks
        await state.loadTaskLists()
        await waitUntil { state.menuBarPendingCount == 6 }

        // Ticks re-fetch every list, the selected one included.
        await waitUntil {
            let calls = await api.listTasksCallsByListID
            return (calls["l2"] ?? 0) >= 3 && (calls["l1"] ?? 0) >= 2
        }
        let callsDuring = await api.listTasksCallsByListID
        XCTAssertGreaterThanOrEqual(callsDuring["l2"] ?? 0, 3)
        XCTAssertGreaterThanOrEqual(callsDuring["l1"] ?? 0, 2)

        // A remote change on a non-selected list shows up after the next tick.
        await api.setTasks([makeTask(id: "b1")], for: "l2")
        await waitUntil { state.menuBarPendingCount == 4 }
        XCTAssertEqual(state.menuBarPendingCount, 4)

        state.menuBarCounterMode = .off
        XCTAssertFalse(state.isMenuBarCountRefreshLoopRunning)
        XCTAssertEqual(state.menuBarPendingCount, 0)
        // Let any tick that was mid-flight drain, then the counts must freeze.
        try? await Task.sleep(for: .milliseconds(60))
        let callsAtOff = await api.listTasksCallsByListID
        try? await Task.sleep(for: .milliseconds(100))
        let callsLater = await api.listTasksCallsByListID
        XCTAssertEqual(callsLater, callsAtOff)
    }

    func testPeriodicTickUpdatesSelectedListTasks() async {
        let api = makeCounterAPI()
        let state = makeState(api: api, menuBarCountRefreshInterval: .milliseconds(20))
        state.menuBarCounterMode = .openTasks
        defer { state.menuBarCounterMode = .off }
        await state.loadTaskLists()
        XCTAssertEqual(state.tasks.map(\.id), ["a1", "a2", "a-done"])

        await api.setTasks([makeTask(id: "a-new")], for: "l1")
        await waitUntil { state.tasks.map(\.id) == ["a-new"] }

        XCTAssertEqual(state.tasks.map(\.id), ["a-new"])
        XCTAssertFalse(state.isLoading)
        XCTAssertNil(state.errorMessage)
    }

    func testSignOutStopsMenuBarCounterRefresh() async {
        let api = makeCounterAPI()
        let state = makeState(api: api, menuBarCountRefreshInterval: .milliseconds(20))
        state.menuBarCounterMode = .openTasks
        defer { state.menuBarCounterMode = .off }
        await state.loadTaskLists()
        await waitUntil { state.menuBarPendingCount == 6 }

        state.signOut()

        XCTAssertEqual(state.menuBarPendingCount, 0)
        XCTAssertFalse(state.isMenuBarCountRefreshLoopRunning)
        try? await Task.sleep(for: .milliseconds(60))
        let callsAfterSignOut = await api.listTasksCallsByListID
        try? await Task.sleep(for: .milliseconds(100))
        let callsLater = await api.listTasksCallsByListID
        XCTAssertEqual(callsLater, callsAfterSignOut)
    }

    func testMenuBarCounterBackgroundFetchSwallowsErrors() async {
        let api = makeCounterAPI()
        await api.setListTasksError(.serverError(500, "boom"), for: "l2")
        let state = makeState(api: api)
        state.menuBarCounterMode = .openTasks
        defer { state.menuBarCounterMode = .off }

        await state.loadTaskLists()
        await waitUntil { state.menuBarPendingCount == 3 }

        XCTAssertEqual(state.menuBarPendingCount, 3)
        XCTAssertNil(state.errorMessage)
        XCTAssertFalse(state.isLoading)
        XCTAssertTrue(state.isSignedIn)
    }

    func testMenuBarCounterBackgroundUnauthorizedDoesNotSignOut() async {
        let api = makeCounterAPI()
        await api.setListTasksError(.unauthorized, for: "l2")
        let state = makeState(api: api)
        state.menuBarCounterMode = .openTasks
        defer { state.menuBarCounterMode = .off }

        await state.loadTaskLists()
        await waitUntil { state.menuBarPendingCount == 3 }

        XCTAssertEqual(state.menuBarPendingCount, 3)
        XCTAssertTrue(state.isSignedIn)
        XCTAssertNil(state.errorMessage)
    }

    func testBackgroundSnapshotTakenBeforeALocalChangeIsDiscarded() async {
        let api = makeCounterAPI(delaysByListID: ["l2": .milliseconds(150)])
        let state = makeState(api: api)
        state.menuBarCounterMode = .openTasks
        defer { state.menuBarCounterMode = .off }

        await state.loadTaskLists()
        // The sweep fetches l2 first (150 ms), then l3.
        await waitUntil {
            let calls = await api.listTasksCallsByListID
            return calls["l2"] == 1
        }

        // A local change while l2 is in flight makes that snapshot stale.
        await state.addTask(title: "New")
        XCTAssertEqual(state.menuBarPendingCount, 3)

        // l3 (fetched after the change) counts; the stale l2 snapshot does not.
        await waitUntil { state.menuBarPendingCount == 4 }
        try? await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(state.menuBarPendingCount, 4)

        // The next sweep repairs it (a tick would do the same; re-enabling
        // triggers one deterministically).
        state.menuBarCounterMode = .off
        state.menuBarCounterMode = .openTasks
        await waitUntil { state.menuBarPendingCount == 7 }
        XCTAssertEqual(state.menuBarPendingCount, 7)
    }

    /// Off → On while a sweep is mid-flight cancels it and starts a fresh one;
    /// the cancelled sweep unwinding afterwards must not mark the new sweep as
    /// finished (a later tick would then run a duplicate sweep alongside it).
    func testReenablingDuringASweepKeepsTheReplacementSweepTracked() async {
        let api = makeCounterAPI(delaysByListID: ["l2": .milliseconds(150)])
        let state = makeState(api: api)
        state.menuBarCounterMode = .openTasks
        defer { state.menuBarCounterMode = .off }

        await state.loadTaskLists()
        await waitUntil {
            let calls = await api.listTasksCallsByListID
            return calls["l2"] == 1
        }
        XCTAssertTrue(state.isMenuBarCountSweepInFlight)

        // Cancel the in-flight sweep and start its replacement immediately.
        state.menuBarCounterMode = .off
        XCTAssertFalse(state.isMenuBarCountSweepInFlight)
        state.menuBarCounterMode = .openTasks
        XCTAssertTrue(state.isMenuBarCountSweepInFlight)

        // Let the cancelled sweep unwind; the replacement is still on l2's delay.
        try? await Task.sleep(for: .milliseconds(40))
        XCTAssertTrue(state.isMenuBarCountSweepInFlight)

        await waitUntil { state.menuBarPendingCount == 6 }
        await waitUntil { !state.isMenuBarCountSweepInFlight }
        XCTAssertFalse(state.isMenuBarCountSweepInFlight)
        let calls = await api.listTasksCallsByListID
        XCTAssertEqual(calls["l2"], 2)
        XCTAssertEqual(calls["l3"], 1)
    }

    // MARK: - Notification preference toggling

    func testRapidNotificationPreferenceTogglingEndingDisabledRemovesNotifications() async {
        state.selectedListId = "list1"
        state.taskLists = [TaskList(id: "list1", title: "Inbox", selfLink: nil, updated: nil)]
        state.tasks = [makeTask()]

        state.dueDateNotificationsEnabled = false
        state.dueDateNotificationsEnabled = true
        state.dueDateNotificationsEnabled = false

        let notificationService: TestDueDateNotificationService = dueDateNotificationService
        await waitUntil { await notificationService.eventLog.count == 3 }

        // Every operation re-reads the final (disabled) preference, so no
        // sync may run and notifications end up removed.
        let events = await dueDateNotificationService.eventLog
        XCTAssertEqual(events, ["removeAll", "removeAll", "removeAll"])
        let syncCallCount = await dueDateNotificationService.syncCalls.count
        XCTAssertEqual(syncCallCount, 0)
    }

    func testRapidNotificationPreferenceTogglingEndingEnabledSyncs() async {
        state.selectedListId = "list1"
        state.taskLists = [TaskList(id: "list1", title: "Inbox", selfLink: nil, updated: nil)]
        state.tasks = [makeTask()]

        state.dueDateNotificationsEnabled = false
        state.dueDateNotificationsEnabled = true

        let notificationService: TestDueDateNotificationService = dueDateNotificationService
        await waitUntil { await notificationService.eventLog.count == 2 }

        // Every operation re-reads the final (enabled) preference, so the
        // notifications end up scheduled rather than removed.
        let events = await dueDateNotificationService.eventLog
        XCTAssertEqual(events, ["sync", "sync"])
        let removeAllCallCount = await dueDateNotificationService.removeAllCallCount
        XCTAssertEqual(removeAllCallCount, 0)
    }
}

private actor DelayedTasksAPI: TasksAPIProtocol {
    struct UpdateStub {
        let delay: Duration?
        let result: Result<TaskItem, APIError>
    }

    struct MoveCall: Sendable, Equatable {
        let listId: String
        let taskId: String
        let parentId: String?
        let previousTaskId: String?
        let destinationListId: String?
    }

    private var taskLists: [TaskList]
    private var tasksByListID: [String: [TaskItem]]
    private var delaysByListID: [String: Duration]
    private var listTaskListsDelay: Duration?
    private var createTaskListDelay: Duration?
    private var createTaskListError: APIError?
    private var createTaskDelay: Duration?
    private var updateStubsByTaskID: [String: [UpdateStub]] = [:]
    private var moveTaskDelay: Duration?
    private var moveTaskError: APIError?
    private var moveTaskSucceeds = false
    private(set) var moveCalls: [MoveCall] = []
    private(set) var updateTaskCallCount = 0
    private(set) var createTaskListCallCount = 0
    private(set) var listTasksCallsByListID: [String: Int] = [:]
    private var listTasksErrorsByListID: [String: APIError] = [:]

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

    func setListTaskListsDelay(_ delay: Duration) {
        listTaskListsDelay = delay
    }

    func setCreateTaskDelay(_ delay: Duration) {
        createTaskDelay = delay
    }

    func setCreateTaskListDelay(_ delay: Duration) {
        createTaskListDelay = delay
    }

    func setCreateTaskListFailure(_ error: APIError) {
        createTaskListError = error
    }

    /// Makes `listTasks` throw `error` for `listID` until cleared with `nil`.
    func setListTasksError(_ error: APIError?, for listID: String) {
        listTasksErrorsByListID[listID] = error
    }

    /// Queues one updateTask response for the task; stubs are consumed in call order.
    func addUpdateStub(forTaskID taskID: String, delay: Duration? = nil, result: Result<TaskItem, APIError>) {
        updateStubsByTaskID[taskID, default: []].append(UpdateStub(delay: delay, result: result))
    }

    func setMoveTaskFailure(delay: Duration? = nil, error: APIError) {
        moveTaskDelay = delay
        moveTaskError = error
    }

    /// Makes `moveTask` apply the move to the in-memory lists (after the
    /// optional delay) and return the moved task instead of throwing 501.
    func setMoveTaskSuccess(delay: Duration? = nil) {
        moveTaskDelay = delay
        moveTaskError = nil
        moveTaskSucceeds = true
    }

    func tasks(for listID: String) -> [TaskItem] {
        tasksByListID[listID] ?? []
    }

    func listTaskLists() async throws -> [TaskList] {
        if let listTaskListsDelay {
            try? await Task.sleep(for: listTaskListsDelay)
        }
        return taskLists
    }

    func createTaskList(title: String) async throws -> TaskList {
        createTaskListCallCount += 1
        if let createTaskListDelay {
            try? await Task.sleep(for: createTaskListDelay)
        }
        if let createTaskListError {
            throw createTaskListError
        }
        let list = TaskList(id: "created-list-\(title)", title: title, selfLink: nil, updated: nil)
        taskLists.append(list)
        tasksByListID[list.id] = []
        return list
    }

    func listTasks(listId: String, showCompleted: Bool, showHidden: Bool) async throws -> [TaskItem] {
        listTasksCallsByListID[listId, default: 0] += 1
        // Snapshot before the delay to model a server response computed when
        // the request arrived, not when the response lands.
        let tasks = tasksByListID[listId] ?? []
        if let delay = delaysByListID[listId] {
            try? await Task.sleep(for: delay)
        }
        if let error = listTasksErrorsByListID[listId] {
            throw error
        }

        if showCompleted {
            return tasks
        }
        return tasks.filter { !$0.isCompleted }
    }

    func createTask(listId: String, title: String, notes: String?, due: String?, parentId: String?) async throws -> TaskItem {
        if let createTaskDelay {
            try? await Task.sleep(for: createTaskDelay)
        }
        return TaskItem(
            id: "created-\(title)",
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
        updateTaskCallCount += 1
        guard var stubs = updateStubsByTaskID[taskId], !stubs.isEmpty else {
            throw APIError.serverError(501, "Not implemented")
        }
        let stub = stubs.removeFirst()
        updateStubsByTaskID[taskId] = stubs
        if let delay = stub.delay {
            try? await Task.sleep(for: delay)
        }
        switch stub.result {
        case .success(let updatedTask):
            return updatedTask
        case .failure(let error):
            throw error
        }
    }

    func deleteTask(listId: String, taskId: String) async throws {
        throw APIError.serverError(501, "Not implemented")
    }

    func moveTask(
        listId: String,
        taskId: String,
        parentId: String?,
        previousTaskId: String?,
        destinationListId: String?
    ) async throws -> TaskItem {
        moveCalls.append(MoveCall(
            listId: listId,
            taskId: taskId,
            parentId: parentId,
            previousTaskId: previousTaskId,
            destinationListId: destinationListId
        ))
        if let moveTaskDelay {
            try? await Task.sleep(for: moveTaskDelay)
        }
        if let moveTaskError {
            throw moveTaskError
        }
        guard moveTaskSucceeds else {
            throw APIError.serverError(501, "Not implemented")
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

private func requestBodyData(from request: URLRequest) -> Data? {
    if let body = request.httpBody {
        return body
    }
    guard let stream = request.httpBodyStream else { return nil }
    stream.open()
    defer { stream.close() }
    var data = Data()
    var buffer = [UInt8](repeating: 0, count: 1024)
    while stream.hasBytesAvailable {
        let read = stream.read(&buffer, maxLength: buffer.count)
        guard read > 0 else { break }
        data.append(buffer, count: read)
    }
    return data
}
