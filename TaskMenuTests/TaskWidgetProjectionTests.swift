import XCTest
@testable import TaskMenu

/// Covers `TaskWidgetProjection`'s open-task filtering, root ordering,
/// subtask flattening/orphan policy, row-budget truncation, and due-date
/// bucketing.
final class TaskWidgetProjectionTests: XCTestCase {
    private func makeTask(
        id: String,
        parent: String? = nil,
        status: TaskItem.TaskStatus = .needsAction,
        due: String? = nil,
        position: String? = nil
    ) -> TaskWidgetTaskSnapshot {
        TaskWidgetTaskSnapshot(id: id, title: "Task \(id)", status: status, due: due, parent: parent, position: position)
    }

    private func wireString(daysFromNow offset: Int, now: Date, calendar: Calendar) -> String {
        let day = calendar.date(byAdding: .day, value: offset, to: calendar.startOfDay(for: now))!
        return DateFormatting.formatGoogleTaskDueDate(day, calendar: calendar)
    }

    // MARK: Open-only filtering

    func testOpenOnlyFilteringExcludesCompletedTasks() {
        let open = makeTask(id: "open", status: .needsAction, position: "1")
        let completed = makeTask(id: "done", status: .completed, position: "2")

        let result = TaskWidgetProjection.project(tasks: [open, completed], sortOrder: .myOrder, rowBudget: 10)

        XCTAssertEqual(result.rows.map(\.task.id), ["open"])
    }

    // MARK: Root ordering — Google position / due date / ties

    func testGoogleOrderSortsByPositionWithMissingPositionsLastTiedByOriginalOrder() {
        let noPosition = makeTask(id: "c", position: nil)
        let bPosition = makeTask(id: "b", position: "b-position")
        let aPosition = makeTask(id: "a", position: "a-position")

        let result = TaskWidgetProjection.project(tasks: [noPosition, bPosition, aPosition], sortOrder: .myOrder, rowBudget: 10)

        XCTAssertEqual(result.rows.map(\.task.id), ["a", "b", "c"])
    }

    func testPositionTieBreaksByOriginalInputOrder() {
        let first = makeTask(id: "first", position: "00000000000000000000")
        let second = makeTask(id: "second", position: "00000000000000000000")

        let result = TaskWidgetProjection.project(tasks: [first, second], sortOrder: .myOrder, rowBudget: 10)

        XCTAssertEqual(result.rows.map(\.task.id), ["first", "second"])
    }

    func testDueDateOrderSortsAscendingWithUndatedLast() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        let now = Date()

        let overdue = makeTask(id: "overdue", due: wireString(daysFromNow: -2, now: now, calendar: calendar), position: "3")
        let today = makeTask(id: "today", due: wireString(daysFromNow: 0, now: now, calendar: calendar), position: "1")
        let undated = makeTask(id: "undated", due: nil, position: "0")

        let result = TaskWidgetProjection.project(
            tasks: [undated, today, overdue],
            sortOrder: .dueDate,
            rowBudget: 10,
            now: now,
            calendar: calendar
        )

        XCTAssertEqual(result.rows.map(\.task.id), ["overdue", "today", "undated"])
    }

    // MARK: Subtask placement and orphan policy

    func testSubtasksFollowParentImmediatelyInGoogleOrderRegardlessOfSortOrder() {
        let root = makeTask(id: "root", position: "1")
        let sub2 = makeTask(id: "sub2", parent: "root", position: "2")
        let sub1 = makeTask(id: "sub1", parent: "root", position: "1")

        // Sort order is .dueDate; subtasks must still follow in Google
        // (position) order, matching AppState's subtasks(of:) behavior.
        let result = TaskWidgetProjection.project(tasks: [root, sub2, sub1], sortOrder: .dueDate, rowBudget: 10)

        XCTAssertEqual(result.rows.map(\.task.id), ["root", "sub1", "sub2"])
        XCTAssertEqual(result.rows.map(\.isSubtask), [false, true, true])
    }

    func testOrphanSubtaskWithCompletedParentIsPromotedToRoot() {
        let completedParent = makeTask(id: "parent", status: .completed, position: "1")
        let orphan = makeTask(id: "child", parent: "parent", position: "1")

        let result = TaskWidgetProjection.project(tasks: [completedParent, orphan], sortOrder: .myOrder, rowBudget: 10)

        XCTAssertEqual(result.rows.map(\.task.id), ["child"])
        XCTAssertFalse(result.rows[0].isSubtask, "an orphaned subtask must render as a root row")
    }

    func testOrphanSubtaskWithMissingParentIsPromotedToRoot() {
        let orphan = makeTask(id: "child", parent: "does-not-exist", position: "1")

        let result = TaskWidgetProjection.project(tasks: [orphan], sortOrder: .myOrder, rowBudget: 10)

        XCTAssertEqual(result.rows.map(\.task.id), ["child"])
        XCTAssertFalse(result.rows[0].isSubtask)
    }

    // MARK: Row budgets and "+N more"

    func testDefaultRowBudgetConstantsMatchContract() {
        XCTAssertEqual(TaskWidgetProjectionConstants.smallRowBudget, 3)
        XCTAssertEqual(TaskWidgetProjectionConstants.mediumRowBudget, 6)
        XCTAssertEqual(TaskWidgetProjectionConstants.largeRowBudget, 10)
    }

    func testRowBudgetTruncatesMidSubtaskGroupAndReportsRemainder() {
        let root1 = makeTask(id: "root1", position: "1")
        let sub1a = makeTask(id: "sub1a", parent: "root1", position: "1")
        let root2 = makeTask(id: "root2", position: "2")

        let result = TaskWidgetProjection.project(tasks: [root1, sub1a, root2], sortOrder: .myOrder, rowBudget: 2)

        XCTAssertEqual(result.rows.map(\.task.id), ["root1", "sub1a"])
        XCTAssertEqual(result.remainderCount, 1)
    }

    func testRowBudgetNotExceededReportsZeroRemainder() {
        let root = makeTask(id: "root1", position: "1")

        let result = TaskWidgetProjection.project(tasks: [root], sortOrder: .myOrder, rowBudget: TaskWidgetProjectionConstants.smallRowBudget)

        XCTAssertEqual(result.rows.count, 1)
        XCTAssertEqual(result.remainderCount, 0)
    }

    // MARK: Due treatment

    func testDueTreatmentUndatedWhenNoDueDate() {
        XCTAssertEqual(TaskWidgetProjection.dueTreatment(for: nil), .undated)
    }

    func testDueTreatmentBucketsAcrossTimeZones() {
        for identifier in ["America/Los_Angeles", "Asia/Tokyo", "Pacific/Kiritimati"] {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(identifier: identifier)!
            let now = Date()

            let overdueWire = wireString(daysFromNow: -1, now: now, calendar: calendar)
            let todayWire = wireString(daysFromNow: 0, now: now, calendar: calendar)
            let tomorrowWire = wireString(daysFromNow: 1, now: now, calendar: calendar)
            let futureWire = wireString(daysFromNow: 5, now: now, calendar: calendar)

            XCTAssertEqual(TaskWidgetProjection.dueTreatment(for: overdueWire, now: now, calendar: calendar), .overdue, identifier)
            XCTAssertEqual(TaskWidgetProjection.dueTreatment(for: todayWire, now: now, calendar: calendar), .dueToday, identifier)
            XCTAssertEqual(TaskWidgetProjection.dueTreatment(for: tomorrowWire, now: now, calendar: calendar), .dueTomorrow, identifier)

            guard case .dated(let futureDate) = TaskWidgetProjection.dueTreatment(for: futureWire, now: now, calendar: calendar) else {
                XCTFail("expected .dated for a future date beyond tomorrow in \(identifier)")
                continue
            }
            let expectedFutureDay = calendar.date(byAdding: .day, value: 5, to: calendar.startOfDay(for: now))!
            XCTAssertTrue(calendar.isDate(futureDate, inSameDayAs: expectedFutureDay), identifier)
        }
    }

    func testDueTreatmentAcrossDSTSpringForwardBoundary() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        // March 8, 2026 is the US spring-forward DST transition (2:00am -> 3:00am).
        let now = calendar.date(from: DateComponents(year: 2026, month: 3, day: 8, hour: 12))!

        let overdueWire = wireString(daysFromNow: -1, now: now, calendar: calendar)
        let todayWire = wireString(daysFromNow: 0, now: now, calendar: calendar)
        let tomorrowWire = wireString(daysFromNow: 1, now: now, calendar: calendar)

        XCTAssertEqual(TaskWidgetProjection.dueTreatment(for: overdueWire, now: now, calendar: calendar), .overdue)
        XCTAssertEqual(TaskWidgetProjection.dueTreatment(for: todayWire, now: now, calendar: calendar), .dueToday)
        XCTAssertEqual(TaskWidgetProjection.dueTreatment(for: tomorrowWire, now: now, calendar: calendar), .dueTomorrow)
    }

    func testDueTreatmentAcrossDSTFallBackBoundary() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        // November 1, 2026 is the US fall-back DST transition (2:00am -> 1:00am).
        let now = calendar.date(from: DateComponents(year: 2026, month: 11, day: 1, hour: 12))!

        let todayWire = wireString(daysFromNow: 0, now: now, calendar: calendar)
        let tomorrowWire = wireString(daysFromNow: 1, now: now, calendar: calendar)

        XCTAssertEqual(TaskWidgetProjection.dueTreatment(for: todayWire, now: now, calendar: calendar), .dueToday)
        XCTAssertEqual(TaskWidgetProjection.dueTreatment(for: tomorrowWire, now: now, calendar: calendar), .dueTomorrow)
    }
}
