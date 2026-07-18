import XCTest
import AuthenticationServices
@testable import TaskMenu

@MainActor
final class AppStateTests: XCTestCase {
    private var keychain: InMemoryKeychainService!
    private var userDefaults: UserDefaults!
    private var userDefaultsSuiteName: String!
    private var dueDateNotificationService: TestDueDateNotificationService!

    override func setUp() async throws {
        MockURLProtocol.reset()
        keychain = InMemoryKeychainService()
        userDefaultsSuiteName = "dev.crazytan.TaskMenu.tests.appstate.\(UUID().uuidString)"
        userDefaults = UserDefaults(suiteName: userDefaultsSuiteName)
        userDefaults.removePersistentDomain(forName: userDefaultsSuiteName)
        dueDateNotificationService = TestDueDateNotificationService()
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

    private func makeState(
        authService: GoogleAuthService,
        dueDateNotificationService: TestDueDateNotificationService? = nil
    ) -> AppState {
        AppState(
            authService: authService,
            userDefaults: userDefaults,
            dueDateNotificationService: dueDateNotificationService ?? self.dueDateNotificationService
        )
    }

    private func makeTask(
        id: String,
        title: String = "Task",
        parent: String? = nil,
        status: TaskItem.TaskStatus = .needsAction,
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

    // MARK: - Initial State

    func testInitialStateWhenNotSignedIn() {
        let authService = GoogleAuthService(keychain: keychain)
        let state = makeState(authService: authService)

        XCTAssertFalse(state.isSignedIn)
        XCTAssertFalse(state.isLoading)
        XCTAssertNil(state.errorMessage)
        XCTAssertTrue(state.taskLists.isEmpty)
        XCTAssertTrue(state.tasks.isEmpty)
        XCTAssertNil(state.selectedListId)
        XCTAssertTrue(state.dueDateNotificationsEnabled)
    }

    func testInitialStateReflectsSignedInStatus() throws {
        try keychain.save(key: Constants.Keychain.refreshTokenKey, string: "some-refresh-token")
        let authService = GoogleAuthService(keychain: keychain)
        let state = makeState(authService: authService)

        XCTAssertTrue(state.isSignedIn)
    }

    func testInitialStateReflectsStoredGoogleAccountProfile() throws {
        try keychain.save(key: Constants.Keychain.refreshTokenKey, string: "some-refresh-token")
        try keychain.save(
            key: Constants.Keychain.accountProfileKey,
            data: JSONEncoder().encode(GoogleAccountProfile(email: "tan@example.com"))
        )

        let authService = GoogleAuthService(keychain: keychain)
        let state = makeState(authService: authService)

        XCTAssertEqual(state.googleAccountProfile?.displayEmail, "tan@example.com")
        XCTAssertEqual(state.googleAccountProfile?.email, "tan@example.com")
    }

    func testInitialTaskLoadingShowsForSignedInEmptyState() throws {
        try keychain.save(key: Constants.Keychain.refreshTokenKey, string: "some-refresh-token")
        let authService = GoogleAuthService(keychain: keychain)
        let state = makeState(authService: authService)

        XCTAssertTrue(state.isShowingInitialTaskLoad)

        state.hasCompletedInitialTaskLoad = true

        XCTAssertFalse(state.isShowingInitialTaskLoad)
    }

    func testInitialTaskLoadingDoesNotShowWhenSignedOut() {
        let authService = GoogleAuthService(keychain: keychain)
        let state = makeState(authService: authService)

        XCTAssertFalse(state.isShowingInitialTaskLoad)
    }

    func testInitialStateUsesStoredDueDateNotificationPreference() {
        userDefaults.set(false, forKey: Constants.UserDefaults.dueDateNotificationsEnabledKey)
        let authService = GoogleAuthService(keychain: keychain)
        let state = makeState(authService: authService)

        XCTAssertFalse(state.dueDateNotificationsEnabled)
    }

    func testSignInFailureShowsErrorAndStopsLoading() async {
        let webAuthenticator = AppStateFailingWebAuthenticator(
            error: GoogleAuthError.tokenExchangeFailed("invalid_client: Unauthorized")
        )
        let authService = GoogleAuthService(keychain: keychain, webAuthenticator: webAuthenticator)
        let state = makeState(authService: authService)

        state.signIn()

        await waitUntil {
            state.errorMessage != nil && !state.isLoading
        }

        XCTAssertFalse(state.isSignedIn)
        XCTAssertFalse(state.isLoading)
        XCTAssertTrue(state.errorMessage?.contains("invalid_client") == true)
    }

    func testChangingDueDateNotificationsPersistsPreferenceAndRemovesNotificationsWhenDisabled() async {
        let authService = GoogleAuthService(keychain: keychain)
        let notificationService = TestDueDateNotificationService()
        let state = makeState(
            authService: authService,
            dueDateNotificationService: notificationService
        )

        state.dueDateNotificationsEnabled = false
        await waitUntil {
            await notificationService.removeAllCallCount == 1
        }

        XCTAssertEqual(
            userDefaults.object(forKey: Constants.UserDefaults.dueDateNotificationsEnabledKey) as? Bool,
            false
        )
        let removeAllCallCount = await notificationService.removeAllCallCount
        XCTAssertEqual(removeAllCallCount, 1)
    }

    // MARK: - selectedList

    func testSelectedListReturnsNilWhenNoListSelected() {
        let authService = GoogleAuthService(keychain: keychain)
        let state = makeState(authService: authService)
        XCTAssertNil(state.selectedList)
    }

    func testSelectedListReturnsMatchingList() {
        let authService = GoogleAuthService(keychain: keychain)
        let state = makeState(authService: authService)

        state.taskLists = [
            TaskList(id: "list1", title: "Work", selfLink: nil, updated: nil),
            TaskList(id: "list2", title: "Personal", selfLink: nil, updated: nil),
        ]
        state.selectedListId = "list2"

        XCTAssertEqual(state.selectedList?.id, "list2")
        XCTAssertEqual(state.selectedList?.title, "Personal")
    }

    func testSelectedListReturnsNilForNonexistentId() {
        let authService = GoogleAuthService(keychain: keychain)
        let state = makeState(authService: authService)

        state.taskLists = [
            TaskList(id: "list1", title: "Work", selfLink: nil, updated: nil),
        ]
        state.selectedListId = "nonexistent"

        XCTAssertNil(state.selectedList)
    }

    // MARK: - Task Ordering

    func testRootTasksUseGooglePositionOrder() {
        let authService = GoogleAuthService(keychain: keychain)
        let state = makeState(authService: authService)
        state.tasks = [
            makeTask(id: "third", position: "00000003"),
            makeTask(id: "first", position: "00000001"),
            makeTask(id: "child", parent: "first", position: "00000000"),
            makeTask(id: "second", position: "00000002"),
        ]

        XCTAssertEqual(state.rootTasks.map(\.id), ["first", "second", "third"])
    }

    func testSubtasksUseGooglePositionOrder() {
        let authService = GoogleAuthService(keychain: keychain)
        let state = makeState(authService: authService)
        state.tasks = [
            makeTask(id: "parent", position: "00000000"),
            makeTask(id: "child-2", parent: "parent", position: "00000002"),
            makeTask(id: "child-1", parent: "parent", position: "00000001"),
        ]

        XCTAssertEqual(state.subtasks(of: "parent").map(\.id), ["child-1", "child-2"])
    }

    func testGooglePositionOrderingFallsBackToExistingOrderWhenPositionIsMissing() {
        let tasks = [
            makeTask(id: "first"),
            makeTask(id: "second"),
        ]

        XCTAssertEqual(tasksSortedByGooglePosition(tasks).map(\.id), ["first", "second"])
    }

    // MARK: - Reorder After Move

    private func rootOrder(_ tasks: [TaskItem]) -> [String] {
        tasksSortedByGooglePosition(tasks.filter { $0.parent == nil }).map(\.id)
    }

    private func subtaskOrder(_ tasks: [TaskItem], of parentID: String) -> [String] {
        tasksSortedByGooglePosition(tasks.filter { $0.parent == parentID }).map(\.id)
    }

    func testReorderAfterMovePlacesRootTaskAfterPreviousSibling() throws {
        let tasks = [
            makeTask(id: "first", position: "00000001"),
            makeTask(id: "second", position: "00000002"),
            makeTask(id: "third", position: "00000003"),
        ]

        let reordered = try XCTUnwrap(tasksReorderedAfterMove(
            tasks, movedTaskID: "third", newParentID: nil, previousTaskID: "first"
        ))

        XCTAssertEqual(rootOrder(reordered), ["first", "third", "second"])
    }

    func testReorderAfterMoveWithNilPreviousMovesTaskFirst() throws {
        let tasks = [
            makeTask(id: "first", position: "00000001"),
            makeTask(id: "second", position: "00000002"),
        ]

        let reordered = try XCTUnwrap(tasksReorderedAfterMove(
            tasks, movedTaskID: "second", newParentID: nil, previousTaskID: nil
        ))

        XCTAssertEqual(rootOrder(reordered), ["second", "first"])
    }

    func testReorderAfterMoveReordersSubtasksWithinParent() throws {
        let tasks = [
            makeTask(id: "parent", position: "00000001"),
            makeTask(id: "child-1", parent: "parent", position: "00000001"),
            makeTask(id: "child-2", parent: "parent", position: "00000002"),
            makeTask(id: "child-3", parent: "parent", position: "00000003"),
        ]

        let reordered = try XCTUnwrap(tasksReorderedAfterMove(
            tasks, movedTaskID: "child-1", newParentID: "parent", previousTaskID: "child-2"
        ))

        XCTAssertEqual(subtaskOrder(reordered, of: "parent"), ["child-2", "child-1", "child-3"])
        XCTAssertEqual(rootOrder(reordered), ["parent"])
    }

    func testReorderAfterMoveReparentsTaskAndKeepsSourceOrder() throws {
        let tasks = [
            makeTask(id: "parent-a", position: "00000001"),
            makeTask(id: "a-1", parent: "parent-a", position: "00000001"),
            makeTask(id: "a-2", parent: "parent-a", position: "00000002"),
            makeTask(id: "a-3", parent: "parent-a", position: "00000003"),
            makeTask(id: "parent-b", position: "00000002"),
            makeTask(id: "b-1", parent: "parent-b", position: "00000001"),
        ]

        let reordered = try XCTUnwrap(tasksReorderedAfterMove(
            tasks, movedTaskID: "a-2", newParentID: "parent-b", previousTaskID: "b-1"
        ))

        XCTAssertEqual(subtaskOrder(reordered, of: "parent-a"), ["a-1", "a-3"])
        XCTAssertEqual(subtaskOrder(reordered, of: "parent-b"), ["b-1", "a-2"])
        XCTAssertEqual(reordered.first { $0.id == "a-2" }?.parent, "parent-b")
    }

    func testReorderAfterMovePromotesSubtaskToRoot() throws {
        let tasks = [
            makeTask(id: "parent", position: "00000001"),
            makeTask(id: "child", parent: "parent", position: "00000001"),
            makeTask(id: "standalone", position: "00000002"),
        ]

        let reordered = try XCTUnwrap(tasksReorderedAfterMove(
            tasks, movedTaskID: "child", newParentID: nil, previousTaskID: "parent"
        ))

        XCTAssertEqual(rootOrder(reordered), ["parent", "child", "standalone"])
        XCTAssertNil(reordered.first { $0.id == "child" }?.parent)
    }

    func testReorderAfterMoveRejectsMoveIntoOwnSubtree() {
        let tasks = [
            makeTask(id: "parent", position: "00000001"),
            makeTask(id: "child", parent: "parent", position: "00000001"),
        ]

        XCTAssertNil(tasksReorderedAfterMove(
            tasks, movedTaskID: "parent", newParentID: "child", previousTaskID: nil
        ))
        XCTAssertNil(tasksReorderedAfterMove(
            tasks, movedTaskID: "parent", newParentID: "parent", previousTaskID: nil
        ))
    }

    func testReorderAfterMoveRejectsPreviousThatIsNotADestinationSibling() {
        let tasks = [
            makeTask(id: "parent", position: "00000001"),
            makeTask(id: "child", parent: "parent", position: "00000001"),
            makeTask(id: "standalone", position: "00000002"),
        ]

        // "child" is not a top-level task, so it cannot anchor a root move.
        XCTAssertNil(tasksReorderedAfterMove(
            tasks, movedTaskID: "standalone", newParentID: nil, previousTaskID: "child"
        ))
        XCTAssertNil(tasksReorderedAfterMove(
            tasks, movedTaskID: "standalone", newParentID: nil, previousTaskID: "standalone"
        ))
        XCTAssertNil(tasksReorderedAfterMove(
            tasks, movedTaskID: "missing", newParentID: nil, previousTaskID: nil
        ))
    }

    // MARK: - Sign Out

    func testSignOutResetsAllState() throws {
        try keychain.save(key: Constants.Keychain.refreshTokenKey, string: "token")
        try keychain.save(
            key: Constants.Keychain.accountProfileKey,
            data: JSONEncoder().encode(GoogleAccountProfile(email: "tan@example.com"))
        )
        let authService = GoogleAuthService(keychain: keychain)
        let state = makeState(authService: authService)

        state.taskLists = [
            TaskList(id: "list1", title: "Work", selfLink: nil, updated: nil),
        ]
        state.selectedListId = "list1"
        state.tasks = [
            TaskItem(id: "t1", title: "Task", notes: nil, status: .needsAction, due: nil, selfLink: nil, parent: nil, position: nil, updated: nil),
        ]

        state.signOut()

        XCTAssertFalse(state.isSignedIn)
        XCTAssertNil(state.googleAccountProfile)
        XCTAssertTrue(state.taskLists.isEmpty)
        XCTAssertTrue(state.tasks.isEmpty)
        XCTAssertNil(state.selectedListId)
    }

    func testDisconnectClearsCredentialsLocalTaskDataAndNotifications() async throws {
        try keychain.save(key: Constants.Keychain.accessTokenKey, string: "access-token")
        try keychain.save(key: Constants.Keychain.refreshTokenKey, string: "refresh-token")
        try keychain.save(
            key: Constants.Keychain.accountProfileKey,
            data: JSONEncoder().encode(GoogleAccountProfile(email: "tan@example.com"))
        )

        MockURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, Data())
        }

        let authService = GoogleAuthService(keychain: keychain, session: MockURLProtocol.mockSession())
        let notificationService = TestDueDateNotificationService()
        let state = makeState(
            authService: authService,
            dueDateNotificationService: notificationService
        )

        state.taskLists = [
            TaskList(id: "list1", title: "Work", selfLink: nil, updated: nil),
        ]
        state.selectedListId = "list1"
        state.tasks = [
            TaskItem(id: "t1", title: "Task", notes: nil, status: .needsAction, due: nil, selfLink: nil, parent: nil, position: nil, updated: nil),
        ]
        state.hasCompletedInitialTaskLoad = true

        await state.disconnectGoogleAccount()
        await waitUntil {
            await notificationService.removeAllCallCount == 1
        }

        XCTAssertFalse(state.isSignedIn)
        XCTAssertNil(state.googleAccountProfile)
        XCTAssertTrue(state.taskLists.isEmpty)
        XCTAssertTrue(state.tasks.isEmpty)
        XCTAssertNil(state.selectedListId)
        XCTAssertFalse(state.hasCompletedInitialTaskLoad)
        XCTAssertNil(try keychain.readString(key: Constants.Keychain.accessTokenKey))
        XCTAssertNil(try keychain.readString(key: Constants.Keychain.refreshTokenKey))
        XCTAssertNil(try keychain.read(key: Constants.Keychain.accountProfileKey))

        let revokeRequest = try XCTUnwrap(MockURLProtocol.requestLog.last)
        XCTAssertEqual(revokeRequest.url?.absoluteString, Constants.googleRevocationURL)
        XCTAssertNil(state.errorMessage)
    }

    func testDisconnectShowsErrorWhenGoogleRevocationFails() async throws {
        try keychain.save(key: Constants.Keychain.refreshTokenKey, string: "refresh-token")

        MockURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 500, httpVersion: nil, headerFields: nil)!
            return (response, Data())
        }

        let authService = GoogleAuthService(keychain: keychain, session: MockURLProtocol.mockSession())
        let state = makeState(authService: authService)

        await state.disconnectGoogleAccount()

        // Local sign-out proceeds, but the user must learn the Google-side
        // grant may still be active.
        XCTAssertFalse(state.isSignedIn)
        XCTAssertEqual(
            state.errorMessage,
            "Signed out, but Google revocation failed. Review access at myaccount.google.com/permissions."
        )
    }

    // MARK: - addTask guard

    func testAddTaskWithNoSelectedListDoesNothing() async {
        let authService = GoogleAuthService(keychain: keychain)
        let state = makeState(authService: authService)
        state.selectedListId = nil

        await state.addTask(title: "New Task")

        XCTAssertTrue(state.tasks.isEmpty)
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
}

@MainActor
private final class AppStateFailingWebAuthenticator: WebAuthenticating {
    private let error: Error

    init(error: Error) {
        self.error = error
    }

    func authenticate(
        url: URL,
        callbackScheme: String,
        presentationContextProvider: any ASWebAuthenticationPresentationContextProviding
    ) async throws -> URL {
        throw error
    }
}
