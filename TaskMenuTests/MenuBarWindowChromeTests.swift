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

    /// The signed-in popover renders one pane controller per visible pane and
    /// widens to two panes plus the divider while the setting is on.
    func testSignedInPopoverRendersTwoPanesAndWidensWhenEnabled() async throws {
        let suiteName = "dev.crazytan.TaskMenu.tests.popover.\(UUID().uuidString)"
        let userDefaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        userDefaults.removePersistentDomain(forName: suiteName)
        defer { userDefaults.removePersistentDomain(forName: suiteName) }
        let state = AppState(
            authService: GoogleAuthService(keychain: InMemoryKeychainService()),
            api: DemoTasksAPI(),
            userDefaults: userDefaults
        )
        state.isSignedIn = true
        state.hasCompletedInitialTaskLoad = true
        state.taskLists = [
            TaskList(id: "one", title: "One", selfLink: nil, updated: nil),
            TaskList(id: "two", title: "Two", selfLink: nil, updated: nil)
        ]
        state.selectedListId = "one"

        var reportedSizes: [NSSize] = []
        let controller = TaskPopoverViewController(
            appState: state,
            onRequestClose: {},
            onContentSizeChanged: { reportedSizes.append($0) }
        )
        _ = controller.view

        XCTAssertEqual(paneControllers(of: controller).count, 1)
        XCTAssertEqual(controller.preferredContentSize.width, TaskMenuMetrics.popoverWidth)
        XCTAssertNil(paneDivider(in: controller.view))

        state.sideBySideListsEnabled = true
        await drainMainActorTasks()

        let paneViews = paneControllers(of: controller).map(\.view)
        XCTAssertEqual(paneViews.count, 2)
        XCTAssertEqual(controller.preferredContentSize.width, TaskMenuMetrics.sideBySidePopoverWidth)
        XCTAssertEqual(controller.preferredContentSize.height, TaskMenuMetrics.signedInPopoverHeight)
        XCTAssertEqual(reportedSizes.last?.width, TaskMenuMetrics.sideBySidePopoverWidth)
        let divider = try XCTUnwrap(paneDivider(in: controller.view))
        // Both panes and the divider share one row container.
        XCTAssertTrue(paneViews.allSatisfy { $0.superview === divider.superview })
        controller.view.layoutSubtreeIfNeeded()
        XCTAssertEqual(paneViews[0].frame.width, TaskMenuMetrics.popoverWidth)
        XCTAssertEqual(paneViews[1].frame.width, TaskMenuMetrics.popoverWidth)
        // The box's frame carries AppKit's alignment insets; the laid-out
        // hairline (and the gap between the panes) is the divider width.
        XCTAssertEqual(divider.alignmentRect(forFrame: divider.frame).width, TaskMenuMetrics.paneDividerWidth)
        XCTAssertEqual(paneViews[1].frame.minX - paneViews[0].frame.maxX, TaskMenuMetrics.paneDividerWidth)

        state.sideBySideListsEnabled = false
        await drainMainActorTasks()

        XCTAssertEqual(paneControllers(of: controller).count, 1)
        XCTAssertEqual(controller.preferredContentSize.width, TaskMenuMetrics.popoverWidth)
        XCTAssertNil(paneDivider(in: controller.view))
    }

    private func paneControllers(of controller: NSViewController) -> [TaskListAppKitViewController] {
        controller.children.compactMap { $0 as? TaskListAppKitViewController }
    }

    /// The hairline between the panes: a separator `NSBox` that is a direct
    /// sibling of the pane controllers' views (every other separator in the
    /// popover is an arranged subview of some `NSStackView`).
    private func paneDivider(in view: NSView) -> NSBox? {
        if let box = view as? NSBox, box.boxType == .separator, !(box.superview is NSStackView) {
            return box
        }
        for subview in view.subviews {
            if let found = paneDivider(in: subview) {
                return found
            }
        }
        return nil
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
