import ServiceManagement
import XCTest
@testable import TaskMenu

final class SettingsLaunchAtLoginTests: XCTestCase {
    func testEnablingWithRequiresApprovalStatusNeedsNotice() {
        XCTAssertTrue(
            SettingsLaunchAtLogin.needsApprovalNotice(enabling: true, status: .requiresApproval)
        )
    }

    func testEnablingWithEnabledStatusNeedsNoNotice() {
        XCTAssertFalse(
            SettingsLaunchAtLogin.needsApprovalNotice(enabling: true, status: .enabled)
        )
    }

    func testEnablingWithOtherStatusesNeedsNoNotice() {
        XCTAssertFalse(
            SettingsLaunchAtLogin.needsApprovalNotice(enabling: true, status: .notRegistered)
        )
        XCTAssertFalse(
            SettingsLaunchAtLogin.needsApprovalNotice(enabling: true, status: .notFound)
        )
    }

    func testDisablingNeverNeedsNotice() {
        for status: SMAppService.Status in [.requiresApproval, .enabled, .notRegistered, .notFound] {
            XCTAssertFalse(
                SettingsLaunchAtLogin.needsApprovalNotice(enabling: false, status: status),
                "Disabling should not surface an approval notice for status \(status)"
            )
        }
    }
}
