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

        XCTAssertEqual(updatedTask.due, DateFormatting.formatRFC3339(dueDate))
        XCTAssertEqual(updatedTask.dueDate, DateFormatting.parseRFC3339(DateFormatting.formatRFC3339(dueDate)))
    }
}
