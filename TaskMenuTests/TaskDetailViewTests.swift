import AppKit
import XCTest
@testable import TaskMenu

final class TaskDetailViewTests: XCTestCase {
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

    @MainActor
    private func makeDetailController(
        task: TaskItem,
        tasks: [TaskItem]
    ) -> (state: AppState, controller: TaskDetailAppKitViewController) {
        let state = AppState()
        state.tasks = tasks
        let controller = TaskDetailAppKitViewController(appState: state, task: task, onDismiss: {})
        _ = controller.view
        return (state, controller)
    }

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

    @MainActor
    func testDatePickerInstanceAndUncommittedValueSurviveTasksRender() {
        var parent = makeTask(id: "p1")
        parent.dueDate = Date(timeIntervalSince1970: 1_800_000_000)
        let (state, controller) = makeDetailController(task: parent, tasks: [parent])

        guard let picker = controller.dueDatePicker else {
            return XCTFail("Expected a due-date picker for a task with a due date")
        }
        // Simulate an in-progress edit that the user has not committed yet.
        let uncommitted = Date(timeIntervalSince1970: 1_900_000_000)
        picker.dateValue = uncommitted

        // A background tasks mutation re-runs the subtask render path.
        state.tasks = [parent, makeTask(id: "s1", parent: "p1")]
        controller.renderSubtasks()

        XCTAssertTrue(controller.dueDatePicker === picker)
        XCTAssertNotNil(picker.superview)
        XCTAssertEqual(picker.dateValue, uncommitted)
    }

    @MainActor
    func testCalendarSelectionWritesIntoExistingPickerAndCloses() {
        var parent = makeTask(id: "p1")
        parent.dueDate = Date(timeIntervalSince1970: 1_800_000_000)
        let (_, controller) = makeDetailController(task: parent, tasks: [parent])

        guard let picker = controller.dueDatePicker else {
            return XCTFail("Expected a due-date picker for a task with a due date")
        }

        controller.openDueDateCalendar()
        guard let calendar = controller.dueDateCalendarPicker else {
            return XCTFail("Expected the calendar overlay to be open")
        }
        XCTAssertTrue(controller.isDueDateCalendarOpen)
        XCTAssertEqual(calendar.dateValue, picker.dateValue)

        let picked = Date(timeIntervalSince1970: 1_900_000_000)
        calendar.dateValue = picked
        calendar.sendAction(calendar.action, to: calendar.target)

        // The text picker is updated in place, not rebuilt.
        XCTAssertTrue(controller.dueDatePicker === picker)
        XCTAssertEqual(picker.dateValue, picked)
        XCTAssertFalse(controller.isDueDateCalendarOpen)
    }

    @MainActor
    func testEscapeClosesCalendarBeforeDismissingDetail() {
        var parent = makeTask(id: "p1")
        parent.dueDate = Date(timeIntervalSince1970: 1_800_000_000)
        let state = AppState()
        state.tasks = [parent]
        var dismissed = false
        let controller = TaskDetailAppKitViewController(
            appState: state,
            task: parent,
            onDismiss: { dismissed = true }
        )
        _ = controller.view

        controller.openDueDateCalendar()
        XCTAssertTrue(controller.isDueDateCalendarOpen)

        controller.cancelOperation(nil)
        XCTAssertFalse(controller.isDueDateCalendarOpen)
        XCTAssertFalse(dismissed, "First Escape should only close the calendar")

        controller.cancelOperation(nil)
        XCTAssertTrue(dismissed)
    }

    @MainActor
    func testClearingDueDateClosesOpenCalendar() {
        var parent = makeTask(id: "p1")
        parent.dueDate = Date(timeIntervalSince1970: 1_800_000_000)
        let (_, controller) = makeDetailController(task: parent, tasks: [parent])

        controller.openDueDateCalendar()
        XCTAssertTrue(controller.isDueDateCalendarOpen)

        guard let clearButton = controller.dueDateClearButton else {
            return XCTFail("Expected a Clear button while a due date is set")
        }
        clearButton.sendAction(clearButton.action, to: clearButton.target)

        XCTAssertFalse(controller.isDueDateCalendarOpen)
        XCTAssertNil(controller.dueDatePicker)
    }

    @MainActor
    func testCalendarDoesNotOpenWhenNoDueDateIsSet() {
        let parent = makeTask(id: "p1")
        let (_, controller) = makeDetailController(task: parent, tasks: [parent])

        controller.openDueDateCalendar()

        XCTAssertFalse(controller.isDueDateCalendarOpen)
        XCTAssertNil(controller.dueDateCalendarPicker)
    }

    @MainActor
    func testAddSubtaskFieldSurvivesTasksRenderWithoutRebuild() {
        let parent = makeTask(id: "p1")
        let (state, controller) = makeDetailController(task: parent, tasks: [parent])

        controller.openAddSubtaskField()
        guard let field = controller.addSubtaskField, let row = controller.addSubtaskRowView else {
            return XCTFail("Expected the add-subtask field to be open")
        }
        field.stringValue = "half-typed subtask"

        // A background tasks mutation re-runs the subtask render path.
        state.tasks = [parent, makeTask(id: "s1", parent: "p1")]
        controller.renderSubtasks()

        XCTAssertTrue(controller.addSubtaskField === field)
        XCTAssertTrue(controller.addSubtaskRowView === row)
        XCTAssertTrue(controller.subtaskListStack.arrangedSubviews.first === row)
        XCTAssertEqual(controller.subtaskListStack.arrangedSubviews.count, 2)
        XCTAssertEqual(field.stringValue, "half-typed subtask")
    }

    @MainActor
    func testEscapeClosesAddSubtaskFieldAndRestoresButtonRow() {
        let parent = makeTask(id: "p1")
        let (_, controller) = makeDetailController(task: parent, tasks: [parent])

        controller.openAddSubtaskField()
        guard let field = controller.addSubtaskField else {
            return XCTFail("Expected the add-subtask field to be open")
        }
        let openRow = controller.addSubtaskRowView

        field.onEscape?()

        XCTAssertNil(controller.addSubtaskField)
        XCTAssertNotNil(controller.addSubtaskRowView)
        XCTAssertFalse(controller.addSubtaskRowView === openRow)
        XCTAssertTrue(controller.subtaskListStack.arrangedSubviews.first === controller.addSubtaskRowView)
    }

    @MainActor
    func testDetailGroupBoxReappliesLayerColorsOnAppearanceChange() {
        let group = TaskDetailGroupBoxView()
        group.appearance = NSAppearance(named: .aqua)
        group.viewDidChangeEffectiveAppearance()
        let lightBackground = group.layer?.backgroundColor

        group.appearance = NSAppearance(named: .darkAqua)
        group.viewDidChangeEffectiveAppearance()

        var expectedBorder: CGColor?
        var expectedBackground: CGColor?
        group.effectiveAppearance.performAsCurrentDrawingAppearance {
            expectedBorder = NSColor.separatorColor.withAlphaComponent(0.65).cgColor
            expectedBackground = NSColor.textBackgroundColor.withAlphaComponent(0.42).cgColor
        }
        XCTAssertEqual(group.layer?.borderColor, expectedBorder)
        XCTAssertEqual(group.layer?.backgroundColor, expectedBackground)
        XCTAssertNotEqual(group.layer?.backgroundColor, lightBackground)
    }

    @MainActor
    func testDetailFooterReappliesLayerColorOnAppearanceChange() {
        let footer = TaskDetailFooterView()
        footer.appearance = NSAppearance(named: .aqua)
        footer.viewDidChangeEffectiveAppearance()
        let lightBackground = footer.layer?.backgroundColor

        footer.appearance = NSAppearance(named: .darkAqua)
        footer.viewDidChangeEffectiveAppearance()

        var expectedBackground: CGColor?
        footer.effectiveAppearance.performAsCurrentDrawingAppearance {
            expectedBackground = NSColor.windowBackgroundColor.withAlphaComponent(0.28).cgColor
        }
        XCTAssertEqual(footer.layer?.backgroundColor, expectedBackground)
        XCTAssertNotEqual(footer.layer?.backgroundColor, lightBackground)
    }
}
