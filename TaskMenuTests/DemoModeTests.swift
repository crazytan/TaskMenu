import XCTest
@testable import TaskMenu

/// Demo mode lets App Review (and anyone else) exercise the app without a
/// Google account, so these tests pin the properties that matters: it needs no
/// credentials, it never reaches the network or the notification service, and
/// leaving it restores the account-backed data source.
@MainActor
final class DemoModeTests: XCTestCase {
    private var keychain: InMemoryKeychainService!
    private var userDefaults: UserDefaults!
    private var userDefaultsSuiteName: String!
    private var dueDateNotificationService: TestDueDateNotificationService!

    override func setUp() async throws {
        MockURLProtocol.reset()
        keychain = InMemoryKeychainService()
        userDefaultsSuiteName = "dev.crazytan.TaskMenu.tests.demomode.\(UUID().uuidString)"
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

    private func makeState() -> AppState {
        let session = MockURLProtocol.mockSession()
        let authService = GoogleAuthService(keychain: keychain, session: session)
        return AppState(
            authService: authService,
            api: GoogleTasksAPI(authService: authService, session: session),
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

    // MARK: - Entering

    func testEnterDemoModeSignsInWithSampleDataAndNoNetwork() async {
        // Any request reaching the network would be a bug: demo mode must work
        // with no credentials and no connectivity.
        MockURLProtocol.requestHandler = { _ in
            XCTFail("Demo mode must not make network requests")
            throw APIError.serverError(500, "unexpected request")
        }
        let state = makeState()

        state.enterDemoMode()
        await waitUntil { !state.taskLists.isEmpty }

        XCTAssertTrue(state.isDemoMode)
        XCTAssertTrue(state.isSignedIn)
        XCTAssertNil(state.googleAccountProfile)
        XCTAssertEqual(state.taskLists.map(\.title), ["Today", "Work", "Personal"])
        XCTAssertFalse(state.tasks.isEmpty)
    }

    func testEnterDemoModeIsIgnoredWhenAlreadySignedIn() async {
        let state = makeState()
        state.isSignedIn = true

        state.enterDemoMode()

        XCTAssertFalse(state.isDemoMode)
    }

    func testDemoModeSchedulesNoNotifications() async {
        let state = makeState()

        state.enterDemoMode()
        await waitUntil { !state.tasks.isEmpty }
        // The seeded lists carry due dates, which would normally sync.
        await state.refreshTasks()

        let syncCalls = await dueDateNotificationService.syncCalls
        XCTAssertTrue(syncCalls.isEmpty)
    }

    // MARK: - Leaving

    func testExitDemoModeReturnsToSignedOutAndClearsSampleData() async {
        let state = makeState()
        state.enterDemoMode()
        await waitUntil { !state.taskLists.isEmpty }

        state.exitDemoMode()

        XCTAssertFalse(state.isDemoMode)
        XCTAssertFalse(state.isSignedIn)
        XCTAssertTrue(state.taskLists.isEmpty)
        XCTAssertTrue(state.tasks.isEmpty)
        XCTAssertNil(state.selectedListId)
    }

    /// The overflow menu's "Exit demo" item routes through `signOut()`, which
    /// must leave the auth service alone rather than discarding credentials.
    /// The tokens are written after entering the demo because stored tokens
    /// make `authService.isSignedIn` true, which is exactly what stops the
    /// demo from being entered in the first place.
    func testSignOutFromDemoModeLeavesStoredTokensIntact() async {
        let state = makeState()
        state.enterDemoMode()
        await waitUntil { !state.taskLists.isEmpty }
        try? keychain.save(key: Constants.Keychain.accessTokenKey, string: "test-access-token")
        try? keychain.save(key: Constants.Keychain.refreshTokenKey, string: "test-refresh-token")

        state.signOut()

        XCTAssertFalse(state.isDemoMode)
        XCTAssertFalse(state.isSignedIn)
        XCTAssertEqual(try? keychain.readString(key: Constants.Keychain.accessTokenKey), "test-access-token")
        XCTAssertEqual(try? keychain.readString(key: Constants.Keychain.refreshTokenKey), "test-refresh-token")
    }

    func testDisconnectFromDemoModeExitsWithoutRevoking() async {
        let state = makeState()
        state.enterDemoMode()
        await waitUntil { !state.taskLists.isEmpty }

        await state.disconnectGoogleAccount()

        XCTAssertFalse(state.isDemoMode)
        XCTAssertFalse(state.isSignedIn)
        // Revocation would have failed against the mock and surfaced an error.
        XCTAssertNil(state.errorMessage)
    }

    /// Regression guard for the swapped-out data source: after leaving the
    /// demo, loads have to hit Google again rather than the sample data.
    func testExitDemoModeRestoresTheAccountBackedAPI() async {
        try? keychain.save(key: Constants.Keychain.accessTokenKey, string: "test-access-token")
        try? keychain.save(key: Constants.Keychain.refreshTokenKey, string: "test-refresh-token")
        let futureExpiration = String(Date().addingTimeInterval(3600).timeIntervalSince1970)
        try? keychain.save(key: Constants.Keychain.expirationKey, string: futureExpiration)

        let state = makeState()
        state.enterDemoMode()
        await waitUntil { !state.taskLists.isEmpty }
        state.exitDemoMode()

        MockURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            let json = #"{"items":[{"id":"real-list","title":"From Google"}]}"#
            return (response, Data(json.utf8))
        }
        state.isSignedIn = true
        await state.loadTaskLists()

        XCTAssertEqual(state.taskLists.map(\.title), ["From Google"])
    }
}
