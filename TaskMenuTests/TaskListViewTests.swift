import XCTest
@testable import TaskMenu

final class TaskListViewTests: XCTestCase {
    func testTaskRowSectionTracksTaskCompletion() {
        let activeTask = TaskItem(
            id: "active",
            title: "Active",
            notes: nil,
            status: .needsAction,
            due: nil,
            selfLink: nil,
            parent: nil,
            position: nil,
            updated: nil
        )
        let completedTask = TaskItem(
            id: "done",
            title: "Done",
            notes: nil,
            status: .completed,
            due: nil,
            selfLink: nil,
            parent: nil,
            position: nil,
            updated: nil
        )

        XCTAssertEqual(taskRowSection(for: activeTask), .active)
        XCTAssertEqual(taskRowSection(for: completedTask), .completed)
    }

    func testTaskRowIdentityDiffersAcrossSectionsForSameTask() {
        let taskID = "t1"

        XCTAssertEqual(taskRowIdentity(for: taskID, in: .active), "active-t1")
        XCTAssertEqual(taskRowIdentity(for: taskID, in: .completed), "completed-t1")
        XCTAssertNotEqual(
            taskRowIdentity(for: taskID, in: .active),
            taskRowIdentity(for: taskID, in: .completed)
        )
    }

    func testCompletedSectionSpacingStaysCompact() {
        XCTAssertLessThanOrEqual(TaskListLayout.activeEndDropZoneHeight, 4)
        XCTAssertLessThanOrEqual(TaskListLayout.completedHeaderTopPadding, 2)
    }
}
