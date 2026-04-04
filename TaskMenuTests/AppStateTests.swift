import XCTest
@testable import TaskMenu

@MainActor
final class AppStateTests: XCTestCase {
    private var keychain: InMemoryKeychainService!
    private var userDefaults: UserDefaults!
    private var userDefaultsSuiteName: String!
    private var dueDateNotificationService: TestDueDateNotificationService!

    override func setUp() async throws {
        keychain = InMemoryKeychainService()
        userDefaultsSuiteName = "dev.crazytan.TaskMenu.tests.appstate.\(UUID().uuidString)"
        userDefaults = UserDefaults(suiteName: userDefaultsSuiteName)
        userDefaults.removePersistentDomain(forName: userDefaultsSuiteName)
        dueDateNotificationService = TestDueDateNotificationService()
    }

    override func tearDown() async throws {
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

    func testInitialStateUsesStoredDueDateNotificationPreference() {
        userDefaults.set(false, forKey: Constants.UserDefaults.dueDateNotificationsEnabledKey)
        let authService = GoogleAuthService(keychain: keychain)
        let state = makeState(authService: authService)

        XCTAssertFalse(state.dueDateNotificationsEnabled)
    }

    func testChangingDueDateNotificationsPersistsPreferenceAndRemovesNotificationsWhenDisabled() async {
        let authService = GoogleAuthService(keychain: keychain)
        let notificationService = TestDueDateNotificationService()
        let state = makeState(
            authService: authService,
            dueDateNotificationService: notificationService
        )

        state.dueDateNotificationsEnabled = false
        await Task.yield()

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

    // MARK: - Sign Out

    func testSignOutResetsAllState() throws {
        try keychain.save(key: Constants.Keychain.refreshTokenKey, string: "token")
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
        XCTAssertTrue(state.taskLists.isEmpty)
        XCTAssertTrue(state.tasks.isEmpty)
        XCTAssertNil(state.selectedListId)
    }

    // MARK: - loadTasks guard

    func testLoadTasksWithNoSelectedListDoesNothing() async {
        let authService = GoogleAuthService(keychain: keychain)
        let state = makeState(authService: authService)
        state.selectedListId = nil

        await state.loadTasks()

        // Should not crash or set loading state
        XCTAssertFalse(state.isLoading)
        XCTAssertTrue(state.tasks.isEmpty)
    }

    // MARK: - addTask guard

    func testAddTaskWithNoSelectedListDoesNothing() async {
        let authService = GoogleAuthService(keychain: keychain)
        let state = makeState(authService: authService)
        state.selectedListId = nil

        await state.addTask(title: "New Task")

        XCTAssertTrue(state.tasks.isEmpty)
    }
}
