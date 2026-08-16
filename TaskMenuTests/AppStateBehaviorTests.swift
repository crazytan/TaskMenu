import XCTest
@testable import TaskMenu

/// Tests for AppState behavior: toggleTask, refreshTasks, cache management, error handling.
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

    private func makeState(api: any TasksAPIProtocol) -> AppState {
        let authService = GoogleAuthService(keychain: keychain, session: MockURLProtocol.mockSession())
        return AppState(
            authService: authService,
            api: api,
            userDefaults: userDefaults,
            dueDateNotificationService: dueDateNotificationService
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

    private var taskLists: [TaskList]
    private var tasksByListID: [String: [TaskItem]]
    private var delaysByListID: [String: Duration]
    private var listTaskListsDelay: Duration?
    private var createTaskDelay: Duration?
    private var updateStubsByTaskID: [String: [UpdateStub]] = [:]
    private var moveTaskDelay: Duration?
    private var moveTaskError: APIError?
    private(set) var updateTaskCallCount = 0

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

    /// Queues one updateTask response for the task; stubs are consumed in call order.
    func addUpdateStub(forTaskID taskID: String, delay: Duration? = nil, result: Result<TaskItem, APIError>) {
        updateStubsByTaskID[taskID, default: []].append(UpdateStub(delay: delay, result: result))
    }

    func setMoveTaskFailure(delay: Duration? = nil, error: APIError) {
        moveTaskDelay = delay
        moveTaskError = error
    }

    func listTaskLists() async throws -> [TaskList] {
        if let listTaskListsDelay {
            try? await Task.sleep(for: listTaskListsDelay)
        }
        return taskLists
    }

    func listTasks(listId: String, showCompleted: Bool, showHidden: Bool) async throws -> [TaskItem] {
        // Snapshot before the delay to model a server response computed when
        // the request arrived, not when the response lands.
        let tasks = tasksByListID[listId] ?? []
        if let delay = delaysByListID[listId] {
            try? await Task.sleep(for: delay)
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

    func moveTask(listId: String, taskId: String, parentId: String?, previousTaskId: String?) async throws -> TaskItem {
        if let moveTaskDelay {
            try? await Task.sleep(for: moveTaskDelay)
        }
        if let moveTaskError {
            throw moveTaskError
        }
        throw APIError.serverError(501, "Not implemented")
    }
}
