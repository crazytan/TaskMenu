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
}
