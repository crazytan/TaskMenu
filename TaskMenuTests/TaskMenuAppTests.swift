import XCTest
@testable import TaskMenu

@MainActor
final class TaskMenuAppTests: XCTestCase {
    func testAppInitializes() {
        _ = TaskMenuApp()
    }
}
