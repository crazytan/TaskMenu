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

    func testEffectiveTitleUsesTrimmedFieldTextWhenNonEmpty() {
        XCTAssertEqual(
            TaskDetailEditing.effectiveTitle(fieldText: "  New title  ", existingTitle: "Old title"),
            "New title"
        )
    }

    func testEffectiveTitleKeepsExistingTitleWhenFieldIsEmpty() {
        XCTAssertEqual(
            TaskDetailEditing.effectiveTitle(fieldText: "   \n ", existingTitle: "Old title"),
            "Old title"
        )
    }

    func testClampedScrollOffsetKeepsOffsetWithinRange() {
        // documentHeight 12 rows * 32 = 384, visibleHeight 160 -> maxOffset 224
        XCTAssertEqual(
            TaskDetailEditing.clampedScrollOffset(100, documentHeight: 384, visibleHeight: 160),
            100
        )
    }

    func testClampedScrollOffsetClampsToMaxWhenDocumentShrinks() {
        // Offset 300 exceeds maxOffset (384 - 160 = 224).
        XCTAssertEqual(
            TaskDetailEditing.clampedScrollOffset(300, documentHeight: 384, visibleHeight: 160),
            224
        )
    }

    func testClampedScrollOffsetFloorsAtZeroWhenDocumentFits() {
        // documentHeight <= visibleHeight -> maxOffset floors at 0.
        XCTAssertEqual(
            TaskDetailEditing.clampedScrollOffset(50, documentHeight: 96, visibleHeight: 160),
            0
        )
        XCTAssertEqual(
            TaskDetailEditing.clampedScrollOffset(-10, documentHeight: 384, visibleHeight: 160),
            0
        )
    }
}
