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

    func testStatusItemClickRoutingShowsContextMenuForRightAndControlClicks() {
        XCTAssertTrue(StatusItemClickRouting.shouldShowContextMenu(
            eventType: .rightMouseUp,
            modifierFlags: []
        ))
        XCTAssertTrue(StatusItemClickRouting.shouldShowContextMenu(
            eventType: .leftMouseUp,
            modifierFlags: .control
        ))
    }

    func testStatusItemClickRoutingTogglesPopoverForPlainLeftClicks() {
        XCTAssertFalse(StatusItemClickRouting.shouldShowContextMenu(
            eventType: .leftMouseUp,
            modifierFlags: []
        ))
        XCTAssertFalse(StatusItemClickRouting.shouldShowContextMenu(
            eventType: .leftMouseUp,
            modifierFlags: .option
        ))
        XCTAssertFalse(StatusItemClickRouting.shouldShowContextMenu(
            eventType: nil,
            modifierFlags: .control
        ))
    }

    func testSignedOutPopoverUpdatesSignInButtonAndErrorInPlace() async throws {
        let state = AppState()
        let controller = TaskPopoverViewController(appState: state, onRequestClose: {})
        _ = controller.view

        let button = try XCTUnwrap(findButton(withTitle: "Sign in with Google", in: controller.view))
        XCTAssertTrue(button.isEnabled)

        // Sign-in starts: the mode stays signed-out, so the controls must
        // update in place rather than through a full re-render.
        state.isLoading = true
        await drainMainActorTasks()
        XCTAssertEqual(button.title, "Signing in…")
        XCTAssertFalse(button.isEnabled)

        // Sign-in fails (e.g. user cancels the browser flow): the button
        // recovers and the error becomes visible.
        state.isLoading = false
        state.errorMessage = "Sign in failed: cancelled"
        await drainMainActorTasks()
        XCTAssertEqual(button.title, "Sign in with Google")
        XCTAssertTrue(button.isEnabled)

        let errorLabel = try XCTUnwrap(
            findTextField(withValue: "Sign in failed: cancelled", in: controller.view)
        )
        XCTAssertFalse(errorLabel.isHidden)

        // Dismissing the error hides the label again.
        state.errorMessage = nil
        await drainMainActorTasks()
        XCTAssertTrue(errorLabel.isHidden)
    }

    private func drainMainActorTasks() async {
        for _ in 0..<20 {
            await Task.yield()
        }
    }

    private func findButton(withTitle title: String, in view: NSView) -> NSButton? {
        if let button = view as? NSButton, button.title == title {
            return button
        }
        for subview in view.subviews {
            if let found = findButton(withTitle: title, in: subview) {
                return found
            }
        }
        return nil
    }

    private func findTextField(withValue value: String, in view: NSView) -> NSTextField? {
        if let field = view as? NSTextField, field.stringValue == value {
            return field
        }
        for subview in view.subviews {
            if let found = findTextField(withValue: value, in: subview) {
                return found
            }
        }
        return nil
    }

    func testStatusItemHighlightingFollowsPopoverVisibility() {
        let button = NSButton(frame: .zero)

        StatusItemHighlighting.apply(true, to: button)
        XCTAssertTrue(button.isHighlighted)

        StatusItemHighlighting.apply(false, to: button)
        XCTAssertFalse(button.isHighlighted)
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
