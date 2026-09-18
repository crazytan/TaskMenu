import XCTest
@testable import TaskMenu

/// Covers the idempotency guard behind `StatusBarController.showPopover()`.
///
/// `showPopover()` itself is not driven end to end here: `StatusBarController`
/// keeps its `NSStatusItem`/`NSPopover` `private` (no existing test in this
/// suite constructs a live `StatusBarController`, precisely because doing so
/// depends on real menu-bar/window-server presentation state that is not
/// reliable inside a test host). The file already extracts pure decision
/// helpers for exactly this reason — `StatusItemClickRouting`,
/// `PopoverClickHandling`, `StatusItemHighlighting` — and `showPopover()`'s
/// idempotency guard, `PopoverPresentationDecision.shouldPresent`, follows
/// the same pattern: this is the actual predicate `showPopover()` evaluates,
/// not a re-implementation of it.
final class StatusBarControllerPopoverTests: XCTestCase {
    func testShowPopoverPresentsWhenNotAlreadyShown() {
        XCTAssertTrue(PopoverPresentationDecision.shouldPresent(isPopoverAlreadyShown: false))
    }

    func testShowPopoverDoesNothingWhenAlreadyShown() {
        // This is the idempotency guarantee: a second `showPopover()` call
        // while the popover is visible must not toggle it closed.
        XCTAssertFalse(PopoverPresentationDecision.shouldPresent(isPopoverAlreadyShown: true))
    }
}
