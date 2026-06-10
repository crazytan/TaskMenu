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

    func testCompletedSectionSpacingStaysCompact() {
        XCTAssertLessThanOrEqual(TaskListLayout.completedHeaderTopPadding, 2)
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

    func testVisibleSubtasksHidesCompletedChildrenByDefaultForActiveParent() {
        let parent = makeTask(id: "parent")
        let activeChild = makeTask(id: "active-child", parent: "parent")
        let completedChild = makeTask(id: "done-child", parent: "parent", status: .completed)

        let visible = visibleSubtasks(
            [activeChild, completedChild],
            under: parent,
            isSearching: false,
            completedSubtasksRevealed: false
        )

        XCTAssertEqual(visible.map(\.id), ["active-child"])
    }

    func testVisibleSubtasksShowsCompletedChildrenWhenRevealed() {
        let parent = makeTask(id: "parent")
        let activeChild = makeTask(id: "active-child", parent: "parent")
        let completedChild = makeTask(id: "done-child", parent: "parent", status: .completed)

        let visible = visibleSubtasks(
            [completedChild, activeChild],
            under: parent,
            isSearching: false,
            completedSubtasksRevealed: true
        )

        XCTAssertEqual(visible.map(\.id), ["active-child", "done-child"])
    }

    func testSubtasksWithCompletedLastPreservesRelativeOrderWithinGroups() {
        let firstDone = makeTask(id: "done-1", parent: "parent", status: .completed)
        let firstActive = makeTask(id: "active-1", parent: "parent")
        let secondDone = makeTask(id: "done-2", parent: "parent", status: .completed)
        let secondActive = makeTask(id: "active-2", parent: "parent")

        let ordered = subtasksWithCompletedLast([firstDone, firstActive, secondDone, secondActive])

        XCTAssertEqual(ordered.map(\.id), ["active-1", "active-2", "done-1", "done-2"])
    }

    func testVisibleSubtasksShowsCompletedChildrenDuringSearch() {
        let parent = makeTask(id: "parent")
        let activeChild = makeTask(id: "active-child", parent: "parent")
        let completedChild = makeTask(id: "done-child", parent: "parent", status: .completed)

        let visible = visibleSubtasks(
            [completedChild, activeChild],
            under: parent,
            isSearching: true,
            completedSubtasksRevealed: false
        )

        XCTAssertEqual(visible.map(\.id), ["active-child", "done-child"])
    }

    func testVisibleSubtasksDoesNotHideChildrenOfCompletedParent() {
        let parent = makeTask(id: "parent", status: .completed)
        let completedChild = makeTask(id: "done-child", parent: "parent", status: .completed)

        let visible = visibleSubtasks(
            [completedChild],
            under: parent,
            isSearching: false,
            completedSubtasksRevealed: false
        )

        XCTAssertEqual(visible.map(\.id), ["done-child"])
    }

    func testCompletedSubtasksRevealCountCountsOnlyHiddenCompletedChildren() {
        let parent = makeTask(id: "parent")
        let activeChild = makeTask(id: "active-child", parent: "parent")
        let completedChild = makeTask(id: "done-child", parent: "parent", status: .completed)

        XCTAssertEqual(
            completedSubtasksRevealCount(
                [activeChild, completedChild],
                under: parent,
                isSearching: false
            ),
            1
        )
    }

    func testCompletedSubtasksRevealCountIsZeroDuringSearch() {
        let parent = makeTask(id: "parent")
        let completedChild = makeTask(id: "done-child", parent: "parent", status: .completed)

        XCTAssertEqual(
            completedSubtasksRevealCount([completedChild], under: parent, isSearching: true),
            0
        )
    }

    func testCompletedSubtasksRevealTitlePluralizes() {
        XCTAssertEqual(completedSubtasksRevealTitle(count: 1, isRevealed: false), "Show 1 completed subtask")
        XCTAssertEqual(completedSubtasksRevealTitle(count: 2, isRevealed: false), "Show 2 completed subtasks")
        XCTAssertEqual(completedSubtasksRevealTitle(count: 2, isRevealed: true), "Hide completed subtasks")
    }
}
