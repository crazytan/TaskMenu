import XCTest
@testable import TaskMenu

@MainActor
final class AppStateTests: XCTestCase {
    private var keychain: InMemoryKeychainService!
    private var userDefaults: UserDefaults!
    private var userDefaultsSuiteName: String!

    override func setUp() async throws {
        keychain = InMemoryKeychainService()
        userDefaultsSuiteName = "com.taskmenu.tests.appstate.\(UUID().uuidString)"
        userDefaults = UserDefaults(suiteName: userDefaultsSuiteName)
        userDefaults.removePersistentDomain(forName: userDefaultsSuiteName)
    }

    override func tearDown() async throws {
        try? keychain.deleteAll()
        if let userDefaultsSuiteName {
            userDefaults.removePersistentDomain(forName: userDefaultsSuiteName)
        }
        userDefaults = nil
        userDefaultsSuiteName = nil
    }

    private func makeState(
        authService: GoogleAuthService,
        shortcutMonitor: TestGlobalShortcutMonitor = TestGlobalShortcutMonitor()
    ) -> AppState {
        AppState(
            authService: authService,
            userDefaults: userDefaults,
            shortcutMonitor: shortcutMonitor
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
        XCTAssertTrue(state.globalShortcutEnabled)
    }

    func testInitialStateReflectsSignedInStatus() throws {
        try keychain.save(key: Constants.Keychain.refreshTokenKey, string: "some-refresh-token")
        let authService = GoogleAuthService(keychain: keychain)
        let state = makeState(authService: authService)

        XCTAssertTrue(state.isSignedIn)
    }

    func testInitialStateUsesStoredGlobalShortcutPreference() {
        userDefaults.set(false, forKey: Constants.UserDefaults.globalShortcutEnabledKey)
        let authService = GoogleAuthService(keychain: keychain)
        let monitor = TestGlobalShortcutMonitor()
        let state = makeState(authService: authService, shortcutMonitor: monitor)

        XCTAssertFalse(state.globalShortcutEnabled)
        XCTAssertEqual(monitor.enabledValues, [false])
        XCTAssertEqual(monitor.handlerSetCount, 1)
    }

    func testChangingGlobalShortcutPersistsPreferenceAndUpdatesMonitor() {
        let authService = GoogleAuthService(keychain: keychain)
        let monitor = TestGlobalShortcutMonitor()
        let state = makeState(authService: authService, shortcutMonitor: monitor)

        state.globalShortcutEnabled = false

        XCTAssertEqual(
            userDefaults.object(forKey: Constants.UserDefaults.globalShortcutEnabledKey) as? Bool,
            false
        )
        XCTAssertEqual(monitor.enabledValues, [true, false])
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

    func testDeinitInvalidatesShortcutMonitor() {
        let authService = GoogleAuthService(keychain: keychain)
        let monitor = TestGlobalShortcutMonitor()
        var state: AppState? = makeState(authService: authService, shortcutMonitor: monitor)

        state = nil

        XCTAssertNil(state)
        XCTAssertEqual(monitor.invalidateCallCount, 1)
    }
}
