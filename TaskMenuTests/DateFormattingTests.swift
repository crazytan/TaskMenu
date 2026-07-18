import XCTest
@testable import TaskMenu

final class DateFormattingTests: XCTestCase {
    func testParseRFC3339WithFractionalSeconds() {
        let date = DateFormatting.parseRFC3339("2026-03-15T00:00:00.000Z")
        XCTAssertNotNil(date)
    }

    func testParseRFC3339WithoutFractionalSeconds() {
        let date = DateFormatting.parseRFC3339("2026-03-15T00:00:00Z")
        XCTAssertNotNil(date)
    }

    func testParseRFC3339InvalidString() {
        let date = DateFormatting.parseRFC3339("not-a-date")
        XCTAssertNil(date)
    }

    func testFormatRFC3339() {
        let date = DateFormatting.parseRFC3339("2026-03-15T00:00:00.000Z")!
        let formatted = DateFormatting.formatRFC3339(date)
        XCTAssertTrue(formatted.contains("2026-03-15"))
    }

    func testFormatRFC3339EmitsGregorianAsciiOutput() {
        let date = DateFormatting.parseRFC3339("2026-03-15T00:00:00.000Z")!
        XCTAssertEqual(DateFormatting.formatRFC3339(date), "2026-03-15T00:00:00.000Z")
    }

    func testParseGoogleTaskDueDatePreservesCalendarDayInNegativeOffsetTimeZone() {
        let calendar = Self.calendar(timeZoneIdentifier: "America/Los_Angeles")
        let date = DateFormatting.parseGoogleTaskDueDate("2026-05-06T00:00:00.000Z", calendar: calendar)

        let components = calendar.dateComponents([.year, .month, .day], from: date!)
        XCTAssertEqual(components.year, 2026)
        XCTAssertEqual(components.month, 5)
        XCTAssertEqual(components.day, 6)
    }

    func testFormatGoogleTaskDueDatePreservesCalendarDayInPositiveOffsetTimeZone() {
        let calendar = Self.calendar(timeZoneIdentifier: "Pacific/Kiritimati")
        let date = calendar.date(from: DateComponents(year: 2026, month: 1, day: 2, hour: 0))!

        let formatted = DateFormatting.formatGoogleTaskDueDate(date, calendar: calendar)

        XCTAssertEqual(formatted, "2026-01-02T00:00:00.000Z")
    }

    // The next four tests pin each direction against an independent Gregorian
    // reference: a plain parse -> format round trip would pass even if both
    // directions misinterpreted era years symmetrically.

    func testParseGoogleTaskDueDateWithBuddhistCalendarYieldsGregorianDay() {
        let calendar = Self.calendar(identifier: .buddhist, timeZoneIdentifier: "Asia/Bangkok")
        let date = DateFormatting.parseGoogleTaskDueDate("2026-05-06T00:00:00.000Z", calendar: calendar)!

        let gregorian = Self.calendar(identifier: .gregorian, timeZoneIdentifier: "Asia/Bangkok")
        let components = gregorian.dateComponents([.year, .month, .day], from: date)
        XCTAssertEqual(components.year, 2026)
        XCTAssertEqual(components.month, 5)
        XCTAssertEqual(components.day, 6)
        XCTAssertEqual(date, calendar.startOfDay(for: date))
    }

    func testFormatGoogleTaskDueDateWithBuddhistCalendarEmitsGregorianYear() {
        let gregorian = Self.calendar(identifier: .gregorian, timeZoneIdentifier: "Asia/Bangkok")
        let date = gregorian.date(from: DateComponents(year: 2026, month: 5, day: 6))!
        let calendar = Self.calendar(identifier: .buddhist, timeZoneIdentifier: "Asia/Bangkok")

        XCTAssertEqual(DateFormatting.formatGoogleTaskDueDate(date, calendar: calendar), "2026-05-06T00:00:00.000Z")
    }

    func testParseGoogleTaskDueDateWithJapaneseCalendarYieldsGregorianDay() {
        let calendar = Self.calendar(identifier: .japanese, timeZoneIdentifier: "Asia/Tokyo")
        let date = DateFormatting.parseGoogleTaskDueDate("2026-05-06T00:00:00.000Z", calendar: calendar)!

        let gregorian = Self.calendar(identifier: .gregorian, timeZoneIdentifier: "Asia/Tokyo")
        let components = gregorian.dateComponents([.year, .month, .day], from: date)
        XCTAssertEqual(components.year, 2026)
        XCTAssertEqual(components.month, 5)
        XCTAssertEqual(components.day, 6)
        XCTAssertEqual(date, calendar.startOfDay(for: date))
    }

    func testFormatGoogleTaskDueDateWithJapaneseCalendarEmitsGregorianYear() {
        let gregorian = Self.calendar(identifier: .gregorian, timeZoneIdentifier: "Asia/Tokyo")
        let date = gregorian.date(from: DateComponents(year: 2026, month: 5, day: 6))!
        let calendar = Self.calendar(identifier: .japanese, timeZoneIdentifier: "Asia/Tokyo")

        XCTAssertEqual(DateFormatting.formatGoogleTaskDueDate(date, calendar: calendar), "2026-05-06T00:00:00.000Z")
    }

    func testGoogleTaskDueDateRoundTripWithBuddhistCalendar() {
        let calendar = Self.calendar(identifier: .buddhist, timeZoneIdentifier: "Asia/Bangkok")
        let date = DateFormatting.parseGoogleTaskDueDate("2026-05-06T00:00:00.000Z", calendar: calendar)!

        XCTAssertEqual(DateFormatting.formatGoogleTaskDueDate(date, calendar: calendar), "2026-05-06T00:00:00.000Z")
    }

    func testGoogleTaskDueDateRelativeStringUsesCalendarDay() {
        let calendar = Self.calendar(timeZoneIdentifier: "America/Los_Angeles")
        let now = calendar.date(from: DateComponents(year: 2026, month: 5, day: 5, hour: 12))!
        let dueDate = DateFormatting.parseGoogleTaskDueDate("2026-05-06T00:00:00.000Z", calendar: calendar)!

        let result = DateFormatting.relativeString(from: dueDate, relativeTo: now, calendar: calendar)

        XCTAssertEqual(result, "Tomorrow")
    }

    func testRelativeStringToday() {
        let today = Date()
        let result = DateFormatting.relativeString(from: today)
        XCTAssertEqual(result, "Today")
    }

    func testRelativeStringTomorrow() {
        let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: Date())!
        let result = DateFormatting.relativeString(from: tomorrow)
        XCTAssertEqual(result, "Tomorrow")
    }

    func testRelativeStringYesterday() {
        let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: Date())!
        let result = DateFormatting.relativeString(from: yesterday)
        XCTAssertEqual(result, "Yesterday")
    }

    func testDisplayString() {
        let date = DateFormatting.parseRFC3339("2026-03-15T00:00:00.000Z")!
        let display = DateFormatting.displayString(date)
        XCTAssertFalse(display.isEmpty)
    }

    private static func calendar(timeZoneIdentifier: String) -> Calendar {
        calendar(identifier: .gregorian, timeZoneIdentifier: timeZoneIdentifier)
    }

    private static func calendar(identifier: Calendar.Identifier, timeZoneIdentifier: String) -> Calendar {
        var calendar = Calendar(identifier: identifier)
        calendar.timeZone = TimeZone(identifier: timeZoneIdentifier)!
        return calendar
    }
}
