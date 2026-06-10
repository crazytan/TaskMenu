import AppKit
import XCTest
@testable import TaskMenu

@MainActor
final class TaskMenuAppTests: XCTestCase {
    func testRuntimeDetectsUnitTesting() {
        XCTAssertTrue(TaskMenuApp.isUnitTesting)
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
