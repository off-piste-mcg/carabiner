import XCTest
@testable import Carabiner

/// The panel's one decision of its own: which action a row offers. Everything else
/// (status, intent handling) is OnboardingViewModel's, already covered elsewhere.
final class SettingsPanelTests: XCTestCase {
    func testUngrantedRowOffersAllow() {
        for row in PermissionRow.allCases {
            XCTAssertEqual(SettingsPanel.actionTitle(row: row, isOn: false, notApplicable: false),
                           "ALLOW", "\(row) should offer ALLOW when off")
        }
    }

    /// macOS gives no way to revoke a TCC grant, so a granted row offers nothing —
    /// except Launch at login, the one row that genuinely can turn itself off
    /// (PermissionRow.canRevokeInProcess; CLAUDE.md gotcha #40's neighbor).
    func testGrantedRowsOfferNothingExceptLaunchAtLogin() {
        for row in PermissionRow.allCases {
            let title = SettingsPanel.actionTitle(row: row, isOn: true, notApplicable: false)
            if row == .launchAtLogin {
                XCTAssertEqual(title, "DISABLE")
            } else {
                XCTAssertNil(title, "\(row) has no honest off action")
            }
        }
    }

    func testNotApplicableRowOffersNothing() {
        XCTAssertNil(SettingsPanel.actionTitle(row: .fullDiskAccess, isOn: false, notApplicable: true))
    }

    func testManageTitleOnGrantedSystemSettingsRows() {
        for row: PermissionRow in [.notifications, .browserAccess, .carouselDialog, .fullDiskAccess] {
            XCTAssertEqual(SettingsPanel.manageTitle(row: row, isOn: true, notApplicable: false),
                           "MANAGE", "\(row) granted should offer MANAGE")
        }
    }

    func testManageTitleAbsentWhenUngranted() {
        for row: PermissionRow in [.notifications, .browserAccess, .carouselDialog, .fullDiskAccess] {
            XCTAssertNil(SettingsPanel.manageTitle(row: row, isOn: false, notApplicable: false),
                         "\(row) ungranted shows ALLOW, not MANAGE")
        }
    }

    func testManageTitleAbsentWhereItWouldLie() {
        // launchAtLogin has a real DISABLE; browserButton has no pane to open.
        XCTAssertNil(SettingsPanel.manageTitle(row: .launchAtLogin, isOn: true, notApplicable: false))
        XCTAssertNil(SettingsPanel.manageTitle(row: .browserButton, isOn: true, notApplicable: false))
        // Nothing granted → nothing to manage (no-Safari machine's FDA row).
        XCTAssertNil(SettingsPanel.manageTitle(row: .fullDiskAccess, isOn: true, notApplicable: true))
    }
}
