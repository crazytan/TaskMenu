import XCTest
@testable import TaskMenu

/// Live contract checks against the real Google Tasks API for the behavior
/// `AppState.addSubtask` relies on. Skipped unless
/// `TASKMENU_LIVE_GOOGLE_TESTS=1` is set and the test host can read a
/// signed-in token: the hosted test bundle uses the Debug app's keychain
/// path, so sign in once from a Debug run of the app first. Every run works
/// in a throwaway task list that is deleted at the end, so the account's own
/// lists are never touched. Set `TASKMENU_LIVE_GOOGLE_LIST_ID` to run inside
/// an existing list instead and leave the created tasks there, which is how
/// to eyeball the result next to the Google Tasks website.
///
/// ```bash
/// TEST_RUNNER_TASKMENU_LIVE_GOOGLE_TESTS=1 xcodebuild test -project TaskMenu.xcodeproj \
///   -scheme TaskMenu -configuration Debug -destination "platform=macOS" \
///   -only-testing:TaskMenuTests/GoogleTasksAPILiveTests
/// ```
@MainActor
final class GoogleTasksAPILiveTests: XCTestCase {
    private var authService: GoogleAuthService!
    private var client: LiveGoogleTasksClient!
    private var scratchListID: String!
    private var ownsScratchList = false

    override func setUp() async throws {
        try await super.setUp()
        let environment = ProcessInfo.processInfo.environment
        guard environment["TASKMENU_LIVE_GOOGLE_TESTS"] == "1" else {
            throw XCTSkip("Set TASKMENU_LIVE_GOOGLE_TESTS=1 to run against the real Google Tasks API.")
        }
        // Bypass the XCTest in-memory keychain so the real signed-in token is used.
        authService = GoogleAuthService(keychain: KeychainService(environment: [:]))
        guard authService.isSignedIn else {
            throw XCTSkip("No Google sign-in is readable by the test host; sign in from a Debug run of TaskMenu first.")
        }
        client = LiveGoogleTasksClient(authService: authService)
        if let listID = environment["TASKMENU_LIVE_GOOGLE_LIST_ID"], !listID.isEmpty {
            scratchListID = listID
        } else {
            scratchListID = try await client.createTaskList(title: "TaskMenu live test \(UUID().uuidString.prefix(8))")
            ownsScratchList = true
        }
    }

    override func tearDown() async throws {
        if ownsScratchList, let scratchListID, let client {
            try await client.deleteTaskList(id: scratchListID)
        }
        try await super.tearDown()
    }

    /// The path the right-click composer takes: `AppState.addSubtask` twice
    /// under one parent. What the app shows right after each add has to be
    /// what a refresh (the server's order) shows.
    func testAddSubtaskThroughAppStateShowsServerOrderWithoutRefresh() async throws {
        let parent = try await client.api.createTask(listId: scratchListID, title: "AppState parent")
        let state = AppState(
            authService: authService,
            api: client.api,
            userDefaults: UserDefaults(suiteName: "TaskMenu.LiveTests.\(UUID().uuidString)") ?? .standard,
            dueDateNotificationService: TestDueDateNotificationService(),
            updateChecker: DisabledUpdateChecker()
        )
        state.isSignedIn = true
        state.selectedListId = scratchListID
        await state.refreshTasks()
        XCTAssertTrue(state.tasks.contains { $0.id == parent.id })

        let first = await state.addSubtask(title: "AppState sub 1", parentId: parent.id)
        let second = await state.addSubtask(title: "AppState sub 2", parentId: parent.id)
        XCTAssertNotNil(first)
        XCTAssertNotNil(second)
        XCTAssertNil(state.errorMessage)
        let optimisticOrder = state.subtasks(of: parent.id).map(\.title)
        XCTAssertEqual(optimisticOrder, ["AppState sub 2", "AppState sub 1"])

        await state.refreshTasks()
        let refreshedOrder = state.subtasks(of: parent.id).map(\.title)
        client.log("appstate-add-subtask", message: "optimistic \(optimisticOrder) refreshed \(refreshedOrder)")
        XCTAssertEqual(refreshedOrder, optimisticOrder, "the order shown before the refresh is the server's order")
    }

    /// `tasks.insert` with `parent` and no `previous` makes the new task the
    /// first child. The positions handed back at creation time are logged so
    /// they can be compared against the listed positions: the API renumbers
    /// siblings, so a client cannot place the new task by comparing its
    /// returned position against sibling positions it fetched earlier.
    func testInsertWithoutPreviousBecomesFirstChild() async throws {
        let parent = try await client.api.createTask(listId: scratchListID, title: "Parent")
        let first = try await client.api.createTask(listId: scratchListID, title: "Sub A", parentId: parent.id)
        let second = try await client.api.createTask(listId: scratchListID, title: "Sub B", parentId: parent.id)
        let third = try await client.api.createTask(listId: scratchListID, title: "Sub C", parentId: parent.id)

        let listed = try await client.api.listTasks(listId: scratchListID)
        let children = tasksSortedByGooglePosition(listed.filter { $0.parent == parent.id })
        client.log("insert-without-previous", created: [first, second, third], listed: children)

        XCTAssertEqual(children.map(\.title), ["Sub C", "Sub B", "Sub A"])
        let locallyPlaced = tasksWithCreatedTask(third, in: tasksWithCreatedTask(second, in: [parent, first]))
        XCTAssertEqual(
            tasksSortedByGooglePosition(locallyPlaced.filter { $0.parent == parent.id }).map(\.title),
            ["Sub C", "Sub B", "Sub A"],
            "the local placement helper reproduces the server's order from the creation responses alone"
        )
    }
}

/// Thin wrapper over the app's API actor plus the task-list create/delete
/// calls the app itself does not need.
@MainActor
private final class LiveGoogleTasksClient {
    let api: GoogleTasksAPI
    private let authService: GoogleAuthService
    private let baseURL = Constants.googleTasksBaseURL

    init(authService: GoogleAuthService) {
        self.authService = authService
        self.api = GoogleTasksAPI(authService: authService)
    }

    func createTaskList(title: String) async throws -> String {
        let data = try await request(path: "/users/@me/lists", method: "POST", body: ["title": title])
        return try JSONDecoder().decode(TaskList.self, from: data).id
    }

    func deleteTaskList(id: String) async throws {
        _ = try await request(path: "/users/@me/lists/\(id)", method: "DELETE")
    }

    func log(_ label: String, created: [TaskItem], listed: [TaskItem]) {
        let createdDescription = created.map { "\($0.title)@\($0.position ?? "nil")" }.joined(separator: ", ")
        let listedDescription = listed.map { "\($0.title)@\($0.position ?? "nil")" }.joined(separator: ", ")
        log(label, message: "created [\(createdDescription)] listed [\(listedDescription)]")
    }

    func log(_ label: String, message: String) {
        print("LIVE-API \(label): \(message)")
    }

    private func request(path: String, method: String, body: [String: Any]? = nil) async throws -> Data {
        let token = try await authService.validAccessToken()
        var request = URLRequest(url: try XCTUnwrap(URL(string: baseURL + path)))
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let body {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard (200...299).contains(status) else {
            throw APIError.serverError(status, String(data: data, encoding: .utf8))
        }
        return data
    }
}
