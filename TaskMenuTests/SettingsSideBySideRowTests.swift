import AppKit
import XCTest
@testable import TaskMenu

/// The "Show two lists side by side" switch in Settings › General: present in
/// every build variant, reflects `AppState.sideBySideListsEnabled`, and writes
/// it back when flipped.
@MainActor
final class SettingsSideBySideRowTests: XCTestCase {
    private var userDefaults: UserDefaults!
    private var suiteName: String!

    override func setUp() async throws {
        suiteName = "dev.crazytan.TaskMenu.tests.settingssidebyside.\(UUID().uuidString)"
        userDefaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        userDefaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() async throws {
        userDefaults.removePersistentDomain(forName: suiteName)
        userDefaults = nil
        suiteName = nil
    }

    func testGeneralSectionShowsSideBySideSwitchThatFollowsAndDrivesTheSetting() async throws {
        let appState = AppState(
            authService: GoogleAuthService(keychain: InMemoryKeychainService()),
            userDefaults: userDefaults,
            dueDateNotificationService: TestDueDateNotificationService()
        )
        let controller = SettingsWindowController(appState: appState)
        defer { controller.window?.close() }
        let contentViewController = try XCTUnwrap(controller.window?.contentViewController)
        contentViewController.loadViewIfNeeded()

        let toggle = try XCTUnwrap(sideBySideSwitch(in: contentViewController.view))
        XCTAssertEqual(toggle.state, .off)

        // Flipping the switch writes the preference (state first, then the
        // action, as a click does).
        toggle.state = .on
        XCTAssertTrue(toggle.sendAction(toggle.action, to: toggle.target))
        XCTAssertTrue(appState.sideBySideListsEnabled)

        // A change from elsewhere (the popover's "…" menu) re-renders the row.
        appState.sideBySideListsEnabled = false
        for _ in 0..<20 { await Task.yield() }
        let rerendered = try XCTUnwrap(sideBySideSwitch(in: contentViewController.view))
        XCTAssertEqual(rerendered.state, .off)
    }

    private func sideBySideSwitch(in view: NSView) -> NSSwitch? {
        if let toggle = view as? NSSwitch, toggle.accessibilityLabel() == "Show two lists side by side" {
            return toggle
        }
        for subview in view.subviews {
            if let found = sideBySideSwitch(in: subview) {
                return found
            }
        }
        return nil
    }
}
