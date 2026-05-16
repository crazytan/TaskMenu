import XCTest
@testable import TaskMenu

final class SemanticVersionTests: XCTestCase {
    func testSemanticVersionComparison() throws {
        let version100 = try XCTUnwrap(SemanticVersion("1.0.0"))
        let version101 = try XCTUnwrap(SemanticVersion("1.0.1"))
        let version109 = try XCTUnwrap(SemanticVersion("1.0.9"))
        let version110 = try XCTUnwrap(SemanticVersion("1.1.0"))
        let version199 = try XCTUnwrap(SemanticVersion("1.9.9"))
        let version200 = try XCTUnwrap(SemanticVersion("2.0.0"))

        XCTAssertTrue(version101 > version100)
        XCTAssertTrue(version110 > version109)
        XCTAssertTrue(version200 > version199)
        XCTAssertEqual(SemanticVersion("v1.2.3"), SemanticVersion("1.2.3"))
    }

    func testSemanticVersionRejectsMalformedValues() {
        XCTAssertNil(SemanticVersion("1.0"))
        XCTAssertNil(SemanticVersion("1.0.0-beta"))
        XCTAssertNil(SemanticVersion("release-1.0.0"))
        XCTAssertNil(SemanticVersion("1..0"))
    }
}

final class GitHubUpdateCheckerTests: XCTestCase {
    override func setUp() async throws {
        MockURLProtocol.reset()
    }

    override func tearDown() async throws {
        MockURLProtocol.reset()
    }

    func testLatestUpdateDecodesGitHubReleaseAndRequestsExpectedEndpoint() async throws {
        let publishedAt = "2026-05-16T12:34:56Z"
        MockURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            )!
            let json = """
            {
              "tag_name": "v1.2.0",
              "html_url": "https://github.com/crazytan/TaskMenu/releases/tag/v1.2.0",
              "name": "TaskMenu 1.2.0",
              "published_at": "\(publishedAt)"
            }
            """
            return (response, Data(json.utf8))
        }

        let checker = GitHubUpdateChecker(session: MockURLProtocol.mockSession())
        let update = try await checker.latestUpdate(currentVersion: "1.1.0")

        XCTAssertEqual(update?.version, "1.2.0")
        XCTAssertEqual(update?.displayVersion, "TaskMenu 1.2.0")
        XCTAssertEqual(update?.releaseURL.absoluteString, "https://github.com/crazytan/TaskMenu/releases/tag/v1.2.0")
        XCTAssertEqual(update?.publishedAt, ISO8601DateFormatter().date(from: publishedAt))

        let request = try XCTUnwrap(MockURLProtocol.requestLog.first)
        XCTAssertEqual(request.url?.absoluteString, Constants.githubLatestReleaseURL)
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/vnd.github+json")
        XCTAssertEqual(request.value(forHTTPHeaderField: "User-Agent"), "TaskMenu")
    }

    func testLatestUpdateReturnsNilWhenReleaseIsNotNewer() async throws {
        stubLatestRelease(tagName: "v1.2.0")
        let checker = GitHubUpdateChecker(session: MockURLProtocol.mockSession())

        let update = try await checker.latestUpdate(currentVersion: "1.2.0")

        XCTAssertNil(update)
    }

    func testLatestUpdateReturnsNilForMalformedReleaseTag() async throws {
        stubLatestRelease(tagName: "not-a-version")
        let checker = GitHubUpdateChecker(session: MockURLProtocol.mockSession())

        let update = try await checker.latestUpdate(currentVersion: "1.1.0")

        XCTAssertNil(update)
    }

    private func stubLatestRelease(tagName: String) {
        MockURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            )!
            let json = """
            {
              "tag_name": "\(tagName)",
              "html_url": "https://github.com/crazytan/TaskMenu/releases/tag/\(tagName)",
              "name": null,
              "published_at": "2026-05-16T12:34:56Z"
            }
            """
            return (response, Data(json.utf8))
        }
    }
}

@MainActor
final class AppStateUpdateCheckTests: XCTestCase {
    private var keychain: InMemoryKeychainService!
    private var userDefaults: UserDefaults!
    private var userDefaultsSuiteName: String!
    private var dueDateNotificationService: TestDueDateNotificationService!

    override func setUp() async throws {
        keychain = InMemoryKeychainService()
        userDefaultsSuiteName = "dev.crazytan.TaskMenu.tests.updates.\(UUID().uuidString)"
        userDefaults = UserDefaults(suiteName: userDefaultsSuiteName)
        userDefaults.removePersistentDomain(forName: userDefaultsSuiteName)
        dueDateNotificationService = TestDueDateNotificationService()
    }

    override func tearDown() async throws {
        try? keychain.deleteAll()
        if let userDefaultsSuiteName {
            userDefaults.removePersistentDomain(forName: userDefaultsSuiteName)
        }
        keychain = nil
        userDefaults = nil
        userDefaultsSuiteName = nil
        dueDateNotificationService = nil
    }

    func testAutomaticUpdateChecksDefaultToEnabled() {
        let state = makeState(updateChecker: TestUpdateChecker())

        XCTAssertTrue(state.automaticUpdateChecksEnabled)
    }

    func testChangingAutomaticUpdateCheckPreferencePersists() {
        let state = makeState(updateChecker: TestUpdateChecker())

        state.automaticUpdateChecksEnabled = false

        XCTAssertEqual(
            userDefaults.object(forKey: Constants.UserDefaults.automaticUpdateChecksEnabledKey) as? Bool,
            false
        )
    }

    func testAutomaticCheckSkipsWhenLastCheckIsRecent() async {
        let checker = TestUpdateChecker(release: makeRelease(version: "1.2.0"))
        let state = makeState(updateChecker: checker)
        state.lastUpdateCheckDate = Date()

        let update = await state.checkForUpdatesIfNeeded()
        let requestCount = await checker.requestCount()

        XCTAssertNil(update)
        XCTAssertEqual(requestCount, 0)
    }

    func testManualCheckRunsEvenWhenLastCheckIsRecent() async {
        let release = makeRelease(version: "1.2.0")
        let checker = TestUpdateChecker(release: release)
        let state = makeState(updateChecker: checker)
        state.lastUpdateCheckDate = Date()

        await state.checkForUpdatesManually()
        let requestCount = await checker.requestCount()

        XCTAssertEqual(requestCount, 1)
        XCTAssertEqual(state.latestAvailableUpdate, release)
        XCTAssertNil(state.updateCheckErrorMessage)
    }

    func testManualCheckStoresUpToDateResult() async {
        let checker = TestUpdateChecker(release: nil)
        let state = makeState(updateChecker: checker)

        await state.checkForUpdatesManually()
        let requestCount = await checker.requestCount()

        XCTAssertEqual(requestCount, 1)
        XCTAssertNil(state.latestAvailableUpdate)
        XCTAssertNil(state.updateCheckErrorMessage)
        XCTAssertNotNil(state.lastUpdateCheckDate)
    }

    func testUpdateCheckFailureStoresSettingsVisibleErrorWithoutChangingTaskData() async {
        let checker = TestUpdateChecker(errorMessage: "Offline")
        let state = makeState(updateChecker: checker)
        let task = TaskItem(
            id: "t1",
            title: "Keep me",
            notes: nil,
            status: .needsAction,
            due: nil,
            selfLink: nil,
            parent: nil,
            position: nil,
            updated: nil
        )
        state.tasks = [task]

        await state.checkForUpdatesManually()

        XCTAssertEqual(state.updateCheckErrorMessage, "Offline")
        XCTAssertNil(state.latestAvailableUpdate)
        XCTAssertEqual(state.tasks.map(\.id), [task.id])
        XCTAssertEqual(state.tasks.map(\.title), [task.title])
    }

    func testAutomaticCheckDoesNotReturnAlreadyAlertedRelease() async {
        let release = makeRelease(version: "1.2.0")
        let checker = TestUpdateChecker(release: release)
        let state = makeState(updateChecker: checker)
        state.lastUpdateCheckDate = .distantPast

        let firstUpdate = await state.checkForUpdatesIfNeeded()
        state.markUpdateAlertShown(for: release)
        state.lastUpdateCheckDate = .distantPast
        let secondUpdate = await state.checkForUpdatesIfNeeded()
        let requestCount = await checker.requestCount()

        XCTAssertEqual(firstUpdate, release)
        XCTAssertNil(secondUpdate)
        XCTAssertEqual(requestCount, 2)
    }

    private func makeState(
        updateChecker: any UpdateChecking,
        currentVersion: String = "1.1.0"
    ) -> AppState {
        let authService = GoogleAuthService(keychain: keychain)
        return AppState(
            authService: authService,
            userDefaults: userDefaults,
            dueDateNotificationService: dueDateNotificationService,
            updateChecker: updateChecker,
            currentAppVersion: currentVersion
        )
    }

    private func makeRelease(version: String) -> AppUpdateRelease {
        AppUpdateRelease(
            version: version,
            displayVersion: "TaskMenu \(version)",
            releaseURL: URL(string: "https://github.com/crazytan/TaskMenu/releases/tag/v\(version)")!,
            publishedAt: Date(timeIntervalSince1970: 1_778_888_888)
        )
    }
}

private actor TestUpdateChecker: UpdateChecking {
    private let release: AppUpdateRelease?
    private let errorMessage: String?
    private var requestedVersions: [String] = []

    init(release: AppUpdateRelease? = nil, errorMessage: String? = nil) {
        self.release = release
        self.errorMessage = errorMessage
    }

    func latestUpdate(currentVersion: String) async throws -> AppUpdateRelease? {
        requestedVersions.append(currentVersion)

        if let errorMessage {
            throw TestUpdateCheckError(message: errorMessage)
        }

        return release
    }

    func requestCount() -> Int {
        requestedVersions.count
    }
}

private struct TestUpdateCheckError: LocalizedError, Sendable {
    let message: String

    var errorDescription: String? {
        message
    }
}
