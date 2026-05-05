import XCTest
@testable import TaskMenu

final class TaskListViewTests: XCTestCase {
    private func makeTask(
        id: String,
        title: String = "Task",
        parent: String? = nil,
        status: TaskItem.TaskStatus = .needsAction
    ) -> TaskItem {
        TaskItem(
            id: id,
            title: title,
            notes: nil,
            status: status,
            due: nil,
            selfLink: nil,
            parent: parent,
            position: nil,
            updated: nil
        )
    }

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
            [activeChild, completedChild],
            under: parent,
            isSearching: false,
            completedSubtasksRevealed: true
        )

        XCTAssertEqual(visible.map(\.id), ["active-child", "done-child"])
    }

    func testVisibleSubtasksShowsCompletedChildrenDuringSearch() {
        let parent = makeTask(id: "parent")
        let completedChild = makeTask(id: "done-child", parent: "parent", status: .completed)

        let visible = visibleSubtasks(
            [completedChild],
            under: parent,
            isSearching: true,
            completedSubtasksRevealed: false
        )

        XCTAssertEqual(visible.map(\.id), ["done-child"])
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

    func testTaskDropContextShowsBeforeIndicatorForSameLevelDrop() {
        let first = makeTask(id: "first")
        let second = makeTask(id: "second")
        let third = makeTask(id: "third")

        let context = taskDropContext(
            draggedTaskID: "third",
            targetTask: first,
            locationY: 4,
            rowHeight: 20,
            activeTasks: [first, second, third]
        )

        XCTAssertEqual(
            context,
            TaskDropContext(
                draggedTaskID: "third",
                targetTaskID: "first",
                placement: .before,
                destinationSiblingIndex: 0
            )
        )
    }

    func testTaskDropContextShowsAfterIndicatorForSameLevelDrop() {
        let first = makeTask(id: "first")
        let second = makeTask(id: "second")
        let third = makeTask(id: "third")

        let context = taskDropContext(
            draggedTaskID: "first",
            targetTask: second,
            locationY: 16,
            rowHeight: 20,
            activeTasks: [first, second, third]
        )

        XCTAssertEqual(
            context,
            TaskDropContext(
                draggedTaskID: "first",
                targetTaskID: "second",
                placement: .after,
                destinationSiblingIndex: 2
            )
        )
    }

    func testTaskDropContextRejectsDifferentParents() {
        let first = makeTask(id: "first", parent: "parent-1")
        let second = makeTask(id: "second", parent: "parent-2")

        XCTAssertNil(
            taskDropContext(
                draggedTaskID: "first",
                targetTask: second,
                locationY: 16,
                rowHeight: 20,
                activeTasks: [first, second]
            )
        )
    }

    func testTaskDropContextRejectsNoOpAdjacentPlacement() {
        let first = makeTask(id: "first")
        let second = makeTask(id: "second")

        XCTAssertNil(
            taskDropContext(
                draggedTaskID: "first",
                targetTask: second,
                locationY: 4,
                rowHeight: 20,
                activeTasks: [first, second]
            )
        )
    }

    func testTaskEndDropContextAcceptsRootTask() {
        let first = makeTask(id: "first")
        let second = makeTask(id: "second")
        let third = makeTask(id: "third")

        let context = taskEndDropContext(draggedTaskID: "first", activeTasks: [first, second, third])

        XCTAssertEqual(
            context,
            TaskDropContext(
                draggedTaskID: "first",
                targetTaskID: nil,
                placement: .after,
                destinationSiblingIndex: 3
            )
        )
    }

    func testTaskEndDropContextRejectsSubtask() {
        let parent = makeTask(id: "parent")
        let child = makeTask(id: "child", parent: "parent")

        XCTAssertNil(taskEndDropContext(draggedTaskID: "child", activeTasks: [parent, child]))
    }
}
