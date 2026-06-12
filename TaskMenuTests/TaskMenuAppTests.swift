import AppKit
import XCTest
@testable import TaskMenu

@MainActor
final class TaskMenuAppTests: XCTestCase {
    func testRuntimeDetectsUnitTesting() {
        XCTAssertTrue(TaskMenuApp.isUnitTesting)
    }

    func testUIModeDefaultsToMenuBar() {
        XCTAssertEqual(
            TaskMenuApp.uiMode(arguments: ["TaskMenu"]),
            .menuBar
        )
    }

    func testUIModeDetectsTestingWindowArgument() {
        XCTAssertEqual(
            TaskMenuApp.uiMode(arguments: ["TaskMenu", "--testing-window"]),
            .testingWindow
        )
    }

    func testSeededTestingWindowDataRequiresTestingWindowArgument() {
        XCTAssertTrue(TaskMenuApp.shouldSeedTestingWindowTasks(arguments: ["TaskMenu", "--testing-window", "--seeded-tasks"]))
        XCTAssertFalse(TaskMenuApp.shouldSeedTestingWindowTasks(arguments: ["TaskMenu", "--seeded-tasks"]))
    }

    func testApplicationMainInstallsDelegate() throws {
        let delegate = try XCTUnwrap(TaskMenuApplication.installedDelegate)

        XCTAssertTrue(NSApplication.shared.delegate === delegate)
    }

    func testAppDelegateReusesSharedAppState() {
        let delegate = TaskMenuAppDelegate()
        let firstState = delegate.appState
        let secondState = delegate.appState

        XCTAssertTrue(firstState === secondState)
    }
}
