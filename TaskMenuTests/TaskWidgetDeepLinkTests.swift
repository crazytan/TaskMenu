import XCTest
@testable import TaskMenu

/// Covers `TaskWidgetDeepLink` construction and strict parsing only. App
/// routing (activating TaskMenu, bootstrapping lists, showing the popover)
/// is owned elsewhere and is out of scope here.
final class TaskWidgetDeepLinkTests: XCTestCase {
    func testValidURLRoundTrips() throws {
        let url = try XCTUnwrap(TaskWidgetDeepLink.url(forListID: "MTIzNDU2Nzg5"))

        XCTAssertEqual(url.scheme, "taskmenu")
        XCTAssertEqual(url.host, "widget")
        XCTAssertEqual(url.path, "/list")
        XCTAssertEqual(TaskWidgetDeepLink.parse(url), .list(id: "MTIzNDU2Nzg5"))
    }

    func testConstructionAndParsingPercentEncodeAndDecodeSpecialCharacters() throws {
        let listID = "list/with spaces & special?chars=1"
        let url = try XCTUnwrap(TaskWidgetDeepLink.url(forListID: listID))

        XCTAssertEqual(TaskWidgetDeepLink.parse(url), .list(id: listID))
    }

    func testParsesLiteralWellFormedURL() throws {
        let url = try XCTUnwrap(URL(string: "taskmenu://widget/list?id=abc123"))
        XCTAssertEqual(TaskWidgetDeepLink.parse(url), .list(id: "abc123"))
    }

    func testRejectsWrongScheme() throws {
        let url = try XCTUnwrap(URL(string: "https://widget/list?id=abc123"))
        XCTAssertNil(TaskWidgetDeepLink.parse(url))
    }

    func testRejectsWrongHost() throws {
        let url = try XCTUnwrap(URL(string: "taskmenu://notwidget/list?id=abc123"))
        XCTAssertNil(TaskWidgetDeepLink.parse(url))
    }

    func testRejectsWrongPath() throws {
        let url = try XCTUnwrap(URL(string: "taskmenu://widget/task?id=abc123"))
        XCTAssertNil(TaskWidgetDeepLink.parse(url))
    }

    func testRejectsMissingID() throws {
        let url = try XCTUnwrap(URL(string: "taskmenu://widget/list"))
        XCTAssertNil(TaskWidgetDeepLink.parse(url))
    }

    func testRejectsEmptyID() throws {
        let url = try XCTUnwrap(URL(string: "taskmenu://widget/list?id="))
        XCTAssertNil(TaskWidgetDeepLink.parse(url))
    }

    func testRejectsDuplicateID() throws {
        let url = try XCTUnwrap(URL(string: "taskmenu://widget/list?id=abc&id=def"))
        XCTAssertNil(TaskWidgetDeepLink.parse(url))
    }

    func testRejectsIDOverMaxLength() throws {
        let overlong = String(repeating: "a", count: TaskWidgetDeepLink.maxListIDLength + 1)
        let url = try XCTUnwrap(TaskWidgetDeepLink.url(forListID: overlong) ?? URL(string: "taskmenu://widget/list?id=\(overlong)"))
        XCTAssertNil(TaskWidgetDeepLink.parse(url))
    }

    func testAcceptsIDAtExactMaxLength() throws {
        let maxLength = String(repeating: "a", count: TaskWidgetDeepLink.maxListIDLength)
        let url = try XCTUnwrap(TaskWidgetDeepLink.url(forListID: maxLength))
        XCTAssertEqual(TaskWidgetDeepLink.parse(url), .list(id: maxLength))
    }

    func testConstructionRejectsEmptyID() {
        XCTAssertNil(TaskWidgetDeepLink.url(forListID: ""))
    }

    func testConstructionRejectsIDOverMaxLength() {
        let overlong = String(repeating: "a", count: TaskWidgetDeepLink.maxListIDLength + 1)
        XCTAssertNil(TaskWidgetDeepLink.url(forListID: overlong))
    }

    func testRejectsUnrelatedGarbageURL() throws {
        let url = try XCTUnwrap(URL(string: "https://example.com/"))
        XCTAssertNil(TaskWidgetDeepLink.parse(url))
    }

    func testRejectsExtraPathComponents() throws {
        let url = try XCTUnwrap(URL(string: "taskmenu://widget/list/extra?id=abc123"))
        XCTAssertNil(TaskWidgetDeepLink.parse(url))
    }
}
