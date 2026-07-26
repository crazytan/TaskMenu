import AppKit
import XCTest
@testable import TaskMenu

@MainActor
final class SettingsVersionRowTests: XCTestCase {
    func testUpdatesSectionShowsVersionWithBuildCommit() {
        let title = renderedVersionRowTitle(version: "1.3.0", buildCommit: "a1b2c3d")

        XCTAssertEqual(title, "Version 1.3.0 (a1b2c3d)")
    }

    func testUpdatesSectionShowsDevWhenBuildIsNotStamped() {
        let title = renderedVersionRowTitle(version: "1.3.0", buildCommit: nil)

        XCTAssertEqual(title, "Version 1.3.0 (dev)")
    }

    private func renderedVersionRowTitle(version: String, buildCommit: String?) -> String? {
        let suiteName = "dev.crazytan.TaskMenu.tests.settingsversion.\(UUID().uuidString)"
        guard let userDefaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Could not create test defaults")
            return nil
        }
        defer { userDefaults.removePersistentDomain(forName: suiteName) }

        let appState = AppState(
            authService: GoogleAuthService(keychain: InMemoryKeychainService()),
            userDefaults: userDefaults,
            dueDateNotificationService: TestDueDateNotificationService(),
            currentAppVersion: version,
            currentBuildCommit: buildCommit
        )

        let controller = SettingsWindowController(appState: appState)
        defer { controller.window?.close() }
        guard let contentViewController = controller.window?.contentViewController else {
            XCTFail("Settings window has no content view controller")
            return nil
        }
        contentViewController.loadViewIfNeeded()

        return labelStrings(in: contentViewController.view).first { $0.hasPrefix("Version ") }
    }

    private func labelStrings(in view: NSView) -> [String] {
        var strings: [String] = []
        if let textField = view as? NSTextField {
            strings.append(textField.stringValue)
        }
        for subview in view.subviews {
            strings.append(contentsOf: labelStrings(in: subview))
        }
        return strings
    }
}
