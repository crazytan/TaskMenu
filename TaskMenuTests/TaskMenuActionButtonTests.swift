import AppKit
import XCTest
@testable import TaskMenu

@MainActor
final class TaskMenuActionButtonTests: XCTestCase {
    private func makeMouseMovedEvent() throws -> NSEvent {
        let event = NSEvent.mouseEvent(
            with: .mouseMoved,
            location: NSPoint(x: 5, y: 5),
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            eventNumber: 0,
            clickCount: 0,
            pressure: 0
        )
        return try XCTUnwrap(event)
    }

    func testPointingHandCursorIsOptOutByDefault() {
        let button = TaskMenuActionButton(symbolName: "circle")
        button.frame = NSRect(x: 0, y: 0, width: 26, height: 24)
        button.updateTrackingAreas()

        XCTAssertFalse(button.usesPointingHandCursor)
        XCTAssertTrue(button.trackingAreas.allSatisfy { !$0.options.contains(.cursorUpdate) })
    }

    func testEnablingPointingHandCursorAddsCursorUpdateTracking() {
        let button = TaskMenuActionButton(symbolName: "circle")
        button.frame = NSRect(x: 0, y: 0, width: 26, height: 24)

        button.usesPointingHandCursor = true

        XCTAssertTrue(button.trackingAreas.contains { $0.options.contains(.cursorUpdate) })
    }

    func testCursorUpdateSetsPointingHandWhenEnabled() throws {
        let button = TaskMenuActionButton(symbolName: "circle")
        button.usesPointingHandCursor = true
        defer { NSCursor.arrow.set() }

        NSCursor.arrow.set()
        button.cursorUpdate(with: try makeMouseMovedEvent())

        XCTAssertEqual(NSCursor.current, NSCursor.pointingHand)
    }

    func testCursorUpdateLeavesDefaultCursorWhenDisabled() throws {
        let button = TaskMenuActionButton(symbolName: "circle")
        defer { NSCursor.arrow.set() }

        NSCursor.arrow.set()
        button.cursorUpdate(with: try makeMouseMovedEvent())

        XCTAssertNotEqual(NSCursor.current, NSCursor.pointingHand)
    }
}
