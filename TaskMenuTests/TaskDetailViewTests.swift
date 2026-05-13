import XCTest
@testable import TaskMenu

final class TaskDetailViewTests: XCTestCase {
    func testDueDateStateStartsDisabledForTaskWithoutDueDate() {
        let task = TaskItem(
            id: "t1",
            title: "Test",
            notes: nil,
            status: .needsAction,
            due: nil,
            selfLink: nil,
            parent: nil,
            position: nil,
            updated: nil
        )
        let referenceDate = Date(timeIntervalSince1970: 1_800_000_000)

        let state = TaskDetailDueDateState(task: task, defaultDate: referenceDate)

        XCTAssertFalse(state.isEnabled)
        XCTAssertEqual(state.selection, referenceDate)
    }

    func testApplyingDisabledDueDateStateClearsDueDate() {
        var task = TaskItem(
            id: "t1",
            title: "Test",
            notes: nil,
            status: .needsAction,
            due: nil,
            selfLink: nil,
            parent: nil,
            position: nil,
            updated: nil
        )
        task.dueDate = Date(timeIntervalSince1970: 1_800_000_000)
        var state = TaskDetailDueDateState(task: task)

        state.clear()
        let updatedTask = state.applying(to: task)

        XCTAssertNil(updatedTask.due)
        XCTAssertNil(updatedTask.dueDate)
    }

    func testApplyingEnabledDueDateStateSetsDueDate() {
        let task = TaskItem(
            id: "t1",
            title: "Test",
            notes: nil,
            status: .needsAction,
            due: nil,
            selfLink: nil,
            parent: nil,
            position: nil,
            updated: nil
        )
        let dueDate = Date(timeIntervalSince1970: 1_800_000_000)
        var state = TaskDetailDueDateState(task: task, defaultDate: dueDate)

        state.enable(defaultDate: dueDate)
        let updatedTask = state.applying(to: task)

        XCTAssertEqual(updatedTask.due, DateFormatting.formatGoogleTaskDueDate(dueDate))
        XCTAssertEqual(updatedTask.dueDate, DateFormatting.parseGoogleTaskDueDate(DateFormatting.formatGoogleTaskDueDate(dueDate)))
    }

    func testSubtaskListMinimumHeightIsZeroWhenEmpty() {
        XCTAssertEqual(TaskDetailLayout.subtaskListMinimumHeight(forCount: 0), 0)
    }

    func testSubtaskListMinimumHeightFitsShortLists() {
        XCTAssertEqual(
            TaskDetailLayout.subtaskListMinimumHeight(forCount: 3),
            TaskDetailLayout.subtaskRowHeight * 3
                + TaskDetailLayout.subtaskRowSpacing * 2
                + TaskDetailLayout.subtaskListVerticalPadding * 2
        )
    }

    func testSubtaskListMinimumHeightKeepsLongListsCompressible() {
        XCTAssertEqual(
            TaskDetailLayout.subtaskListMinimumHeight(forCount: 20),
            TaskDetailLayout.subtaskRowHeight * CGFloat(TaskDetailLayout.subtaskListMinimumVisibleRows)
                + TaskDetailLayout.subtaskRowSpacing * CGFloat(TaskDetailLayout.subtaskListMinimumVisibleRows - 1)
                + TaskDetailLayout.subtaskListVerticalPadding * 2
        )
    }
}
