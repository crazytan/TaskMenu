import XCTest
@testable import TaskMenu

/// Covers the widget deep-link ROUTING decisions: `TaskWidgetDeepLinkRouter`
/// (signed-out routing, cold-start bootstrap, valid/deleted/unknown list
/// selection, malformed-URL no-op) and `DeepLinkColdStartBuffer` (buffering
/// and replacement before the app is ready to route). URL construction and
/// strict parsing are `TaskWidgetDeepLinkTests`' scope, not this suite's.
/// Everything here runs against fakes — no `NSAppleEventManager`, AppKit
/// event plumbing, or a live status item.
@MainActor
final class TaskWidgetDeepLinkRoutingTests: XCTestCase {
    // MARK: - Fakes

    final class FakeDeepLinkAppState: DeepLinkAppStateRouting {
        var isSignedIn: Bool
        var taskLists: [TaskList]
        let primaryPane = TaskListPane(id: .primary)

        /// If set, `bootstrapSignedInState()` replaces `taskLists` with this,
        /// simulating the list catalog becoming available only after a
        /// bootstrap load.
        var taskListsAfterBootstrap: [TaskList]?

        private(set) var bootstrapCallCount = 0
        private(set) var selectedListIDs: [String] = []
        private(set) var selectedPanes: [TaskListPane?] = []

        init(isSignedIn: Bool, taskLists: [TaskList] = []) {
            self.isSignedIn = isSignedIn
            self.taskLists = taskLists
        }

        func bootstrapSignedInState() async {
            bootstrapCallCount += 1
            if let taskListsAfterBootstrap {
                taskLists = taskListsAfterBootstrap
            }
        }

        func selectList(_ listId: String, in pane: TaskListPane?) async {
            selectedListIDs.append(listId)
            selectedPanes.append(pane)
        }
    }

    final class FakePopoverPresenter: DeepLinkPopoverPresenting {
        private(set) var showCallCount = 0

        func showPopover() {
            showCallCount += 1
        }
    }

    private func makeTaskList(id: String) -> TaskList {
        TaskList(id: id, title: "List \(id)", selfLink: nil, updated: nil)
    }

    private func deepLinkURL(id: String = "list-1") -> URL {
        // swiftlint:disable:next force_unwrapping
        TaskWidgetDeepLink.url(forListID: id)!
    }

    // MARK: - Malformed URL: no side effects

    func testMalformedURLHasNoSideEffects() async {
        let appState = FakeDeepLinkAppState(isSignedIn: true, taskLists: [makeTaskList(id: "list-1")])
        let popover = FakePopoverPresenter()
        var activateCallCount = 0

        await TaskWidgetDeepLinkRouter.route(
            url: URL(string: "https://example.com")!,
            activate: { activateCallCount += 1 },
            appState: appState,
            popover: popover
        )

        XCTAssertEqual(activateCallCount, 0)
        XCTAssertEqual(popover.showCallCount, 0)
        XCTAssertEqual(appState.bootstrapCallCount, 0)
        XCTAssertTrue(appState.selectedListIDs.isEmpty)
    }

    func testWrongSchemeURLHasNoSideEffects() async {
        let appState = FakeDeepLinkAppState(isSignedIn: true, taskLists: [makeTaskList(id: "list-1")])
        let popover = FakePopoverPresenter()

        await TaskWidgetDeepLinkRouter.route(
            url: URL(string: "https://widget/list?id=list-1")!,
            activate: {},
            appState: appState,
            popover: popover
        )

        XCTAssertEqual(popover.showCallCount, 0)
        XCTAssertTrue(appState.selectedListIDs.isEmpty)
    }

    // MARK: - Signed out

    func testSignedOutShowsPopoverWithoutBootstrapOrListSwitch() async {
        let appState = FakeDeepLinkAppState(isSignedIn: false)
        let popover = FakePopoverPresenter()
        var activateCallCount = 0

        await TaskWidgetDeepLinkRouter.route(
            url: deepLinkURL(),
            activate: { activateCallCount += 1 },
            appState: appState,
            popover: popover
        )

        XCTAssertEqual(activateCallCount, 1)
        XCTAssertEqual(popover.showCallCount, 1)
        XCTAssertEqual(appState.bootstrapCallCount, 0)
        XCTAssertTrue(appState.selectedListIDs.isEmpty)
    }

    // MARK: - Signed in, lists not loaded yet

    func testSignedInWithNoListsLoadedBootstrapsBeforeSelecting() async {
        let appState = FakeDeepLinkAppState(isSignedIn: true, taskLists: [])
        appState.taskListsAfterBootstrap = [makeTaskList(id: "list-1")]
        let popover = FakePopoverPresenter()

        await TaskWidgetDeepLinkRouter.route(
            url: deepLinkURL(id: "list-1"),
            activate: {},
            appState: appState,
            popover: popover
        )

        XCTAssertEqual(appState.bootstrapCallCount, 1)
        XCTAssertEqual(appState.selectedListIDs, ["list-1"])
        XCTAssertEqual(popover.showCallCount, 1)
    }

    // MARK: - Valid list, already loaded

    func testValidListSelectsInPrimaryPaneWithoutBootstrapping() async {
        let appState = FakeDeepLinkAppState(isSignedIn: true, taskLists: [makeTaskList(id: "list-1")])
        let popover = FakePopoverPresenter()

        await TaskWidgetDeepLinkRouter.route(
            url: deepLinkURL(id: "list-1"),
            activate: {},
            appState: appState,
            popover: popover
        )

        XCTAssertEqual(appState.bootstrapCallCount, 0)
        XCTAssertEqual(appState.selectedListIDs, ["list-1"])
        XCTAssertEqual(appState.selectedPanes.count, 1)
        XCTAssertTrue(appState.selectedPanes[0] === appState.primaryPane)
        XCTAssertEqual(popover.showCallCount, 1)
    }

    func testActivatesBeforeReturningOnValidLink() async {
        let appState = FakeDeepLinkAppState(isSignedIn: true, taskLists: [makeTaskList(id: "list-1")])
        let popover = FakePopoverPresenter()
        var activateCallCount = 0

        await TaskWidgetDeepLinkRouter.route(
            url: deepLinkURL(id: "list-1"),
            activate: { activateCallCount += 1 },
            appState: appState,
            popover: popover
        )

        XCTAssertEqual(activateCallCount, 1)
    }

    // MARK: - Deleted / unknown list

    func testDeletedListPresentsPopoverWithoutSwitchingLists() async {
        let appState = FakeDeepLinkAppState(isSignedIn: true, taskLists: [makeTaskList(id: "other-list")])
        let popover = FakePopoverPresenter()

        await TaskWidgetDeepLinkRouter.route(
            url: deepLinkURL(id: "missing-list"),
            activate: {},
            appState: appState,
            popover: popover
        )

        XCTAssertTrue(appState.selectedListIDs.isEmpty)
        XCTAssertEqual(popover.showCallCount, 1)
    }

    func testUnknownListAfterBootstrapStillPresentsPopoverWithoutSwitching() async {
        let appState = FakeDeepLinkAppState(isSignedIn: true, taskLists: [])
        appState.taskListsAfterBootstrap = [] // deleted from the account entirely
        let popover = FakePopoverPresenter()

        await TaskWidgetDeepLinkRouter.route(
            url: deepLinkURL(id: "missing-list"),
            activate: {},
            appState: appState,
            popover: popover
        )

        XCTAssertEqual(appState.bootstrapCallCount, 1)
        XCTAssertTrue(appState.selectedListIDs.isEmpty)
        XCTAssertEqual(popover.showCallCount, 1)
    }
}

/// Covers `DeepLinkColdStartBuffer` in isolation: exactly one pending link
/// survives until the app is ready, and a second link before that replaces
/// the first rather than queuing.
@MainActor
final class DeepLinkColdStartBufferTests: XCTestCase {
    private func url(_ id: String) -> URL {
        // swiftlint:disable:next force_unwrapping
        URL(string: "taskmenu://widget/list?id=\(id)")!
    }

    func testNotReadyBuffersAndReturnsNilWithoutRouting() {
        let buffer = DeepLinkColdStartBuffer()

        XCTAssertNil(buffer.receive(url("a")))
        XCTAssertEqual(buffer.bufferedURL, url("a"))
        XCTAssertFalse(buffer.isReady)
    }

    func testSecondLinkBeforeFlushReplacesTheBufferedOne() {
        let buffer = DeepLinkColdStartBuffer()

        XCTAssertNil(buffer.receive(url("a")))
        XCTAssertNil(buffer.receive(url("b")))
        XCTAssertEqual(buffer.bufferedURL, url("b"))

        // Only the most recent link is ever flushed — this is the "replace,
        // don't queue" guarantee.
        XCTAssertEqual(buffer.markReady(), url("b"))
    }

    func testMarkReadyFlushesTheBufferedURLAndClearsIt() {
        let buffer = DeepLinkColdStartBuffer()
        _ = buffer.receive(url("a"))

        XCTAssertEqual(buffer.markReady(), url("a"))
        XCTAssertTrue(buffer.isReady)
        XCTAssertNil(buffer.bufferedURL)
    }

    func testMarkReadyWithNothingBufferedReturnsNil() {
        let buffer = DeepLinkColdStartBuffer()

        XCTAssertNil(buffer.markReady())
        XCTAssertTrue(buffer.isReady)
    }

    func testOnceReadyReceiveReturnsTheURLImmediatelyWithoutBuffering() {
        let buffer = DeepLinkColdStartBuffer()
        _ = buffer.markReady()

        XCTAssertEqual(buffer.receive(url("a")), url("a"))
        XCTAssertNil(buffer.bufferedURL)
    }

    func testReadyBufferNeverRetainsAPreviouslyBufferedLink() {
        let buffer = DeepLinkColdStartBuffer()
        _ = buffer.receive(url("stale"))
        _ = buffer.markReady()

        // The flushed link was already handed back by `markReady()`; a later
        // `receive` must not resurrect it.
        XCTAssertEqual(buffer.receive(url("fresh")), url("fresh"))
    }
}
