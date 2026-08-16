import AppKit
import XCTest
@testable import TaskMenu

/// Pure menu-bar counting (open vs due-today, day boundaries, subtasks) and
/// the status item title/length presentation helper.
@MainActor
final class MenuBarCounterTests: XCTestCase {
    private var calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }()

    /// 2026-08-16 12:00 UTC.
    private var now: Date {
        calendar.date(from: DateComponents(year: 2026, month: 8, day: 16, hour: 12))!
    }

    private func makeTask(
        id: String,
        parent: String? = nil,
        status: TaskItem.TaskStatus = .needsAction,
        dueInDays: Int? = nil
    ) -> TaskItem {
        TaskItem(
            id: id,
            title: id,
            notes: nil,
            status: status,
            due: dueInDays.map { days in
                let date = calendar.date(byAdding: .day, value: days, to: now)!
                return DateFormatting.formatGoogleTaskDueDate(date, calendar: calendar)
            },
            selfLink: nil,
            parent: parent,
            position: nil,
            updated: nil
        )
    }

    // MARK: - Mode

    func testModeCasesAreOrderedOffOpenDue() {
        XCTAssertEqual(MenuBarCounterMode.allCases, [.off, .openTasks, .dueToday])
        XCTAssertEqual(MenuBarCounterMode.allCases.map(\.title), ["Off", "Open tasks", "Due today"])
        for mode in MenuBarCounterMode.allCases {
            XCTAssertEqual(MenuBarCounterMode(rawValue: mode.rawValue), mode)
        }
    }

    // MARK: - Counting

    func testOpenTasksCountsEveryIncompleteTaskIncludingSubtasks() {
        let tasks = [
            makeTask(id: "root"),
            makeTask(id: "child", parent: "root"),
            makeTask(id: "done-root", status: .completed),
            makeTask(id: "done-child", parent: "root", status: .completed)
        ]

        XCTAssertEqual(pendingTaskCount(in: tasks, mode: .openTasks, now: now, calendar: calendar), 2)
    }

    func testDueTodayCountsTodayAndOverdueOnly() {
        let tasks = [
            makeTask(id: "today", dueInDays: 0),
            makeTask(id: "yesterday", dueInDays: -1),
            makeTask(id: "long-ago", dueInDays: -30),
            makeTask(id: "tomorrow", dueInDays: 1),
            makeTask(id: "undated"),
            makeTask(id: "done-today", status: .completed, dueInDays: 0)
        ]

        XCTAssertEqual(pendingTaskCount(in: tasks, mode: .dueToday, now: now, calendar: calendar), 3)
    }

    func testDueTodayUsesTheGivenCalendarDayBoundary() {
        let dueToday = makeTask(id: "today", dueInDays: 0)
        let startOfDay = calendar.startOfDay(for: now)
        let endOfDay = calendar.date(byAdding: DateComponents(day: 1, second: -1), to: startOfDay)!
        let previousEvening = calendar.date(byAdding: .second, value: -1, to: startOfDay)!

        XCTAssertTrue(MenuBarCounterMode.dueToday.counts(dueToday, now: endOfDay, calendar: calendar))
        XCTAssertTrue(MenuBarCounterMode.dueToday.counts(dueToday, now: startOfDay, calendar: calendar))
        XCTAssertFalse(MenuBarCounterMode.dueToday.counts(dueToday, now: previousEvening, calendar: calendar))
    }

    func testOffCountsNothing() {
        let tasks = [
            makeTask(id: "today", dueInDays: 0),
            makeTask(id: "open"),
            makeTask(id: "child", parent: "open")
        ]

        XCTAssertEqual(pendingTaskCount(in: tasks, mode: .off, now: now, calendar: calendar), 0)
    }

    // MARK: - Presentation

    func testPresentationTitleIsNilForZeroAndNegativeCounts() {
        XCTAssertNil(MenuBarCounterPresentation.title(forPendingCount: 0))
        XCTAssertNil(MenuBarCounterPresentation.title(forPendingCount: -1))
        XCTAssertEqual(MenuBarCounterPresentation.title(forPendingCount: 3), "3")
        XCTAssertEqual(MenuBarCounterPresentation.title(forPendingCount: 120), "120")
    }

    func testPresentationApplyShowsTitleNextToImageOrIconOnly() {
        let button = NSButton(frame: .zero)
        button.image = NSImage(systemSymbolName: "checklist", accessibilityDescription: nil)

        MenuBarCounterPresentation.apply(title: "3", to: button)
        XCTAssertEqual(button.title, "3")
        XCTAssertEqual(button.imagePosition, .imageLeading)
        XCTAssertNotNil(button.image)

        MenuBarCounterPresentation.apply(title: nil, to: button)
        XCTAssertEqual(button.title, "")
        XCTAssertEqual(button.imagePosition, .imageOnly)
        XCTAssertNotNil(button.image)
    }

    func testPresentationLengthIsSquareWithoutTitleAndVariableWithOne() {
        XCTAssertEqual(MenuBarCounterPresentation.statusItemLength(forTitle: nil), NSStatusItem.squareLength)
        XCTAssertEqual(MenuBarCounterPresentation.statusItemLength(forTitle: "3"), NSStatusItem.variableLength)
    }
}
