import AppKit
import XCTest
@testable import TaskMenu

@MainActor
final class TaskMenuAppTests: XCTestCase {
    func testRuntimeDetectsUnitTesting() {
        XCTAssertTrue(TaskMenuApp.isUnitTesting)
    }

    func testUIModeDefaultsToMenuBar() {
        XCTAssertEqual(
            TaskMenuApp.uiMode(arguments: ["TaskMenu"]),
            .menuBar
        )
    }

    func testUIModeDetectsTestingWindowArgument() {
        XCTAssertEqual(
            TaskMenuApp.uiMode(arguments: ["TaskMenu", "--testing-window"]),
            .testingWindow
        )
    }

    func testUIModeIgnoresUnknownArguments() {
        XCTAssertEqual(
            TaskMenuApp.uiMode(arguments: ["TaskMenu", "--seeded-tasks"]),
            .menuBar
        )
    }

    func testApplicationMainInstallsDelegate() throws {
        let delegate = try XCTUnwrap(TaskMenuApplication.installedDelegate)

        XCTAssertTrue(NSApplication.shared.delegate === delegate)
    }

    func testAppDelegateReusesSharedAppState() {
        let delegate = TaskMenuAppDelegate()
        let firstState = delegate.appState
        let secondState = delegate.appState

        XCTAssertTrue(firstState === secondState)
    }

    func testAutomaticUpdateCheckLoopChecksEveryCycleAndAlertsOnlyWhenReleaseReturned() async {
        let release = AppUpdateRelease(
            version: "9.9.9",
            displayVersion: "TaskMenu 9.9.9",
            releaseURL: URL(string: "https://github.com/crazytan/TaskMenu/releases/tag/v9.9.9")!,
            publishedAt: nil
        )
        var checkCount = 0
        var alertedReleases: [AppUpdateRelease] = []

        await TaskMenuAppDelegate.runAutomaticUpdateChecks(
            checkForUpdates: {
                checkCount += 1
                // Only the second cycle finds an update.
                return checkCount == 2 ? release : nil
            },
            presentAlert: { alertedReleases.append($0) },
            sleepBetweenChecks: {
                // End the loop after three check cycles.
                if checkCount >= 3 { throw CancellationError() }
            }
        )

        XCTAssertEqual(checkCount, 3)
        XCTAssertEqual(alertedReleases, [release])
    }

    func testUpdateAlertChoiceMapsModalResponses() {
        XCTAssertEqual(UpdateAlertChoice(modalResponse: .alertFirstButtonReturn), .download)
        XCTAssertEqual(UpdateAlertChoice(modalResponse: .alertSecondButtonReturn), .later)
        XCTAssertEqual(UpdateAlertChoice(modalResponse: .alertThirdButtonReturn), .skipThisVersion)
    }

    func testUpdateAlertChoiceOnlyLaterSkipsPersistingAlertedVersion() {
        XCTAssertTrue(UpdateAlertChoice.download.persistsAlertedVersion)
        XCTAssertFalse(UpdateAlertChoice.later.persistsAlertedVersion)
        XCTAssertTrue(UpdateAlertChoice.skipThisVersion.persistsAlertedVersion)

        XCTAssertTrue(UpdateAlertChoice.download.opensReleasePage)
        XCTAssertFalse(UpdateAlertChoice.later.opensReleasePage)
        XCTAssertFalse(UpdateAlertChoice.skipThisVersion.opensReleasePage)
    }
}
