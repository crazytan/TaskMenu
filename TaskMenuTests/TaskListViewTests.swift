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

    func testTaskNotesPreviewTrimsWhitespace() {
        let task = TaskItem(
            id: "with-notes",
            title: "Subtask",
            notes: "  Pack the charger\n",
            status: .needsAction,
            due: nil,
            selfLink: nil,
            parent: "parent",
            position: nil,
            updated: nil
        )

        XCTAssertEqual(taskNotesPreview(for: task), "Pack the charger")
    }

    func testTaskNotesPreviewHidesEmptyNotes() {
        let task = TaskItem(
            id: "empty-notes",
            title: "Subtask",
            notes: "  \n",
            status: .needsAction,
            due: nil,
            selfLink: nil,
            parent: "parent",
            position: nil,
            updated: nil
        )

        XCTAssertNil(taskNotesPreview(for: task))
    }

    func testInlineSubtaskFieldShowsImmediatelyAfterSelectedParent() {
        let parent = TaskItem(
            id: "parent",
            title: "Parent",
            notes: nil,
            status: .needsAction,
            due: nil,
            selfLink: nil,
            parent: nil,
            position: nil,
            updated: nil
        )

        XCTAssertTrue(
            shouldPlaceInlineSubtaskField(
                after: parent,
                parentID: "parent",
                isSearching: false,
                section: .active
            )
        )
    }

    func testInlineSubtaskFieldDoesNotShowAfterExistingChild() {
        let child = TaskItem(
            id: "child",
            title: "Child",
            notes: nil,
            status: .needsAction,
            due: nil,
            selfLink: nil,
            parent: "parent",
            position: nil,
            updated: nil
        )

        XCTAssertFalse(
            shouldPlaceInlineSubtaskField(
                after: child,
                parentID: "parent",
                isSearching: false,
                section: .active
            )
        )
    }

    func testInlineSubtaskFieldHidesDuringSearch() {
        let parent = TaskItem(
            id: "parent",
            title: "Parent",
            notes: nil,
            status: .needsAction,
            due: nil,
            selfLink: nil,
            parent: nil,
            position: nil,
            updated: nil
        )

        XCTAssertFalse(
            shouldPlaceInlineSubtaskField(
                after: parent,
                parentID: "parent",
                isSearching: true,
                section: .active
            )
        )
    }
}
