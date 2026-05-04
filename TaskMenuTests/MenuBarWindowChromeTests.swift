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

        MenuBarWindowChrome.applyLiquidGlassSupport(to: window, enabled: false)

        if MenuBarWindowChrome.supportsLiquidGlass {
            XCTAssertFalse(window.isOpaque)
            XCTAssertEqual(window.backgroundColor, .clear)
        } else {
            XCTAssertTrue(window.isOpaque)
            XCTAssertEqual(window.backgroundColor, .windowBackgroundColor)
        }
    }

    func testApplyingExperimentalFullWindowLiquidGlassWrapsAndUnwrapsContentView() {
        let hostedContentView = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 480))
        let window = NSWindow(
            contentRect: hostedContentView.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = hostedContentView

        MenuBarWindowChrome.applyLiquidGlassSupport(to: window, enabled: true)

        if MenuBarWindowChrome.supportsLiquidGlass {
            XCTAssertTrue(MenuBarWindowChrome.isFullWindowGlassApplied(to: window))
            XCTAssertTrue(window.contentView !== hostedContentView)
        } else {
            XCTAssertFalse(MenuBarWindowChrome.isFullWindowGlassApplied(to: window))
            XCTAssertTrue(window.contentView === hostedContentView)
        }

        MenuBarWindowChrome.applyLiquidGlassSupport(to: window, enabled: false)

        XCTAssertFalse(MenuBarWindowChrome.isFullWindowGlassApplied(to: window))
        if MenuBarWindowChrome.supportsLiquidGlass {
            XCTAssertTrue(window.contentView === hostedContentView)
        }
    }
}
