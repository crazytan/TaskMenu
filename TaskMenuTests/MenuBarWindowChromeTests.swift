import AppKit
import XCTest
@testable import TaskMenu

@MainActor
final class MenuBarWindowChromeTests: XCTestCase {
    func testLiquidGlassAvailabilityMatchesPlatformAvailability() {
        #if compiler(>=6.2)
        if #available(macOS 26.0, *) {
            XCTAssertTrue(MenuBarWindowChrome.supportsLiquidGlass)
        } else {
            XCTAssertFalse(MenuBarWindowChrome.supportsLiquidGlass)
        }
        #else
        XCTAssertFalse(MenuBarWindowChrome.supportsLiquidGlass)
        #endif
    }

    func testApplyingLiquidGlassSupportClearsSupportedWindowBackground() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 480),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isOpaque = true
        window.backgroundColor = .windowBackgroundColor

        MenuBarWindowChrome.applyLiquidGlassSupport(to: window)

        if MenuBarWindowChrome.supportsLiquidGlass {
            XCTAssertFalse(window.isOpaque)
            XCTAssertEqual(window.backgroundColor, .clear)
        } else {
            XCTAssertTrue(window.isOpaque)
            XCTAssertEqual(window.backgroundColor, .windowBackgroundColor)
        }
    }

    func testPopoverClickHandlingKeepsPopoverClicksOpen() {
        let popoverWindow = NSWindow()
        let statusWindow = NSWindow()

        XCTAssertFalse(PopoverClickHandling.shouldClosePopover(
            eventWindow: popoverWindow,
            popoverWindow: popoverWindow,
            statusItemWindow: statusWindow
        ))
    }

    func testPopoverClickHandlingKeepsStatusItemClicksOpen() {
        let popoverWindow = NSWindow()
        let statusWindow = NSWindow()

        XCTAssertFalse(PopoverClickHandling.shouldClosePopover(
            eventWindow: statusWindow,
            popoverWindow: popoverWindow,
            statusItemWindow: statusWindow
        ))
    }

    func testPopoverClickHandlingClosesForOtherWindowsAndGlobalEvents() {
        let popoverWindow = NSWindow()
        let statusWindow = NSWindow()
        let otherWindow = NSWindow()

        XCTAssertTrue(PopoverClickHandling.shouldClosePopover(
            eventWindow: otherWindow,
            popoverWindow: popoverWindow,
            statusItemWindow: statusWindow
        ))
        XCTAssertTrue(PopoverClickHandling.shouldClosePopover(
            eventWindow: nil,
            popoverWindow: popoverWindow,
            statusItemWindow: statusWindow
        ))
    }

    func testMenuPresentationRefreshTriggerRunsRefreshEveryTimeMenuOpens() async {
        var refreshCount = 0
        let refreshTrigger = MenuPresentationRefreshTrigger {
            refreshCount += 1
        }

        await refreshTrigger.menuDidOpen().value
        await refreshTrigger.menuDidOpen().value

        XCTAssertEqual(refreshCount, 2)
    }
}
