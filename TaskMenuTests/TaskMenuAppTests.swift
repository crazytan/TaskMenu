import XCTest
@testable import TaskMenu

@MainActor
final class TaskMenuAppTests: XCTestCase {
    func testAppInitializes() {
        _ = TaskMenuApp()
    }

    func testAppDelegateReusesSharedAppState() {
        let delegate = TaskMenuAppDelegate()
        let firstState = delegate.appState
        let secondState = delegate.appState

        XCTAssertTrue(firstState === secondState)
    }
}
