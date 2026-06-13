import AppKit
import XCTest
@testable import TaskMenu

final class TaskListViewTests: XCTestCase {
    private func makeTask(
        id: String,
        title: String = "Task",
        parent: String? = nil,
        status: TaskItem.TaskStatus = .needsAction,
        position: String? = nil
    ) -> TaskItem {
        TaskItem(
            id: id,
            title: title,
            notes: nil,
            status: status,
            due: nil,
            selfLink: nil,
            parent: parent,
            position: position,
            updated: nil
        )
    }

    @MainActor
    func testTaskListScrollIndicatorsUseTransientOverlayStyle() {
        let scrollView = NSScrollView()
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = false
        scrollView.scrollerStyle = .legacy

        TaskMenuAppKit.configureTaskListScrollIndicators(scrollView)

        XCTAssertTrue(scrollView.hasVerticalScroller)
        XCTAssertFalse(scrollView.hasHorizontalScroller)
        XCTAssertTrue(scrollView.autohidesScrollers)
        XCTAssertEqual(scrollView.scrollerStyle, .overlay)
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

    func testSubtasksWithCompletedLastPreservesRelativeOrderWithinGroups() {
        let firstDone = makeTask(id: "done-1", parent: "parent", status: .completed)
        let firstActive = makeTask(id: "active-1", parent: "parent")
        let secondDone = makeTask(id: "done-2", parent: "parent", status: .completed)
        let secondActive = makeTask(id: "active-2", parent: "parent")

        let ordered = subtasksWithCompletedLast([firstDone, firstActive, secondDone, secondActive])

        XCTAssertEqual(ordered.map(\.id), ["active-1", "active-2", "done-1", "done-2"])
    }

    func testFinalCompletedSectionExcludesCompletedSubtasksOfOpenParents() {
        let openParent = makeTask(id: "open-parent", position: "0001")
        let completedChildOfOpenParent = makeTask(
            id: "open-child-done",
            parent: "open-parent",
            status: .completed,
            position: "0001"
        )
        let completedRoot = makeTask(id: "done-root", status: .completed, position: "0002")
        let completedParent = makeTask(id: "done-parent", status: .completed, position: "0003")
        let completedChildOfCompletedParent = makeTask(
            id: "done-child",
            parent: "done-parent",
            status: .completed,
            position: "0001"
        )

        let completedTasks = completedTasksForFinalSection([
            openParent,
            completedChildOfOpenParent,
            completedRoot,
            completedParent,
            completedChildOfCompletedParent
        ])

        XCTAssertEqual(completedTasks.map(\.id), ["done-root", "done-parent", "done-child"])
    }

    func testCompletedSubtasksForOpenParentReturnsOnlyThatParentsCompletedChildren() {
        let firstDone = makeTask(id: "done-1", parent: "parent", status: .completed, position: "0002")
        let activeChild = makeTask(id: "active-1", parent: "parent", position: "0001")
        let otherDone = makeTask(id: "other-done", parent: "other", status: .completed, position: "0001")
        let secondDone = makeTask(id: "done-2", parent: "parent", status: .completed, position: "0003")

        let completedSubtasks = completedSubtasksForOpenParent(
            "parent",
            tasks: [firstDone, activeChild, otherDone, secondDone]
        )

        XCTAssertEqual(completedSubtasks.map(\.id), ["done-1", "done-2"])
    }
}
