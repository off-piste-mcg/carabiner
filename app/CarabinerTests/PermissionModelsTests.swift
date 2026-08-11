import XCTest
import AppKit
import UserNotifications
@testable import Carabiner

/// Row state is pure data → presentation so it can be tested at all: the real statuses
/// come from OS APIs a test runner can't drive.
final class PermissionModelsTests: XCTestCase {

    func testGrantedShowsTickAndNoButton() {
        for row in PermissionRow.allCases {
            let p = row.presentation(for: .granted)
            XCTAssertEqual(p.tick, .ok)
            XCTAssertNil(p.buttonTitle)
            XCTAssertEqual(p.action, PermissionRow.Action.none)
        }
    }

    func testNotDeterminedOffersAllow() {
        for row in PermissionRow.allCases {
            let p = row.presentation(for: .notDetermined)
            XCTAssertEqual(p.tick, .pending)
            XCTAssertEqual(p.buttonTitle, "Allow")
            XCTAssertEqual(p.action, .request)
        }
    }

    /// Denied is a dead end without a door: the button must lead to System Settings.
    func testDeniedLinksToSystemSettings() {
        for row in PermissionRow.allCases {
            let p = row.presentation(for: .denied)
            XCTAssertEqual(p.tick, .cross)
            XCTAssertEqual(p.buttonTitle, "Open System Settings")
            XCTAssertEqual(p.action, .openSystemSettings)
        }
    }

    /// The Automation prompt only works while the target app runs, and the OS cannot even
    /// REPORT the grant state for a closed app — so this is "pending with a heads-up",
    /// never a failure state.
    func testTargetNotRunningExplainsTheBrowserWillOpen() {
        let p = PermissionRow.browserAccess.presentation(for: .targetNotRunning)
        XCTAssertEqual(p.tick, .pending)
        XCTAssertEqual(p.buttonTitle, "Allow")
        XCTAssertEqual(p.action, .request)
        XCTAssertEqual(p.detail, "Chrome will open first")
    }

    /// ...but only the browser row. System Events needs no launch dance, so promising the
    /// carousel row that Chrome will open is a lie. Caught on screen 2026-08-11 once the
    /// rows had room to show their detail line.
    func testOnlyTheBrowserRowPromisesToOpenTheBrowser() {
        for row in PermissionRow.allCases where row != .browserAccess {
            XCTAssertNil(row.presentation(for: .targetNotRunning).detail,
                         "\(row.title) should not claim Chrome will open")
        }
    }

    func testEveryRowHasTitleAndWhy() {
        XCTAssertEqual(PermissionRow.notifications.title, "Notifications")
        XCTAssertEqual(PermissionRow.notifications.why, "So you see when a grab finishes — or why it didn't.")
        XCTAssertEqual(PermissionRow.browserAccess.title, "Browser access")
        XCTAssertEqual(PermissionRow.browserAccess.why, "To read the address of the post you're looking at.")
        XCTAssertEqual(PermissionRow.carouselDialog.title, "Carousel dialog")
        XCTAssertEqual(PermissionRow.carouselDialog.why, "So Carabiner can ask 'this slide or the whole set?'.")
    }

    func testBrowserBundleIds() {
        XCTAssertEqual(Browser.chrome.bundleId, "com.google.Chrome")
        XCTAssertEqual(Browser.safari.bundleId, "com.apple.Safari")
        XCTAssertEqual(Browser.brave.bundleId, "com.brave.Browser")
        XCTAssertEqual(Browser.edge.bundleId, "com.microsoft.edgemac")
        XCTAssertEqual(Browser.arc.bundleId, "company.thebrowser.Browser")
    }

    // MARK: - notification verdict
    //
    // The reported bug (2026-08-11): the row reported granted straight from
    // requestAuthorization's callback flag, so an authorization that did not take showed
    // a green tick and no banners. The verdict below is what the row must ask instead.

    func testAuthorizedWithAlertsEnabledIsGranted() {
        XCTAssertEqual(notificationStatus(authorization: .authorized, alert: .enabled), .granted)
    }

    /// The sibling of the reported bug: allowed, but the alert style is None, so banners
    /// never appear. For Carabiner the banner IS the feature — silent delivery is a
    /// failure, and the remedy is the same as a denial.
    func testAuthorizedWithAlertsDisabledIsDenied() {
        XCTAssertEqual(notificationStatus(authorization: .authorized, alert: .disabled), .denied)
    }

    func testDeniedIsDenied() {
        XCTAssertEqual(notificationStatus(authorization: .denied, alert: .enabled), .denied)
    }

    func testNotDeterminedOffersAllowAgain() {
        XCTAssertEqual(notificationStatus(authorization: .notDetermined, alert: .notSupported),
                       .notDetermined)
    }

    func testProvisionalWithAlertsEnabledIsGranted() {
        XCTAssertEqual(notificationStatus(authorization: .provisional, alert: .enabled), .granted)
    }

    /// Provisional authorization delivers quietly by default — exactly the invisible case.
    func testProvisionalWithAlertsDisabledIsDenied() {
        XCTAssertEqual(notificationStatus(authorization: .provisional, alert: .disabled), .denied)
    }

    // MARK: - tick symbols

    /// All three must resolve on the deployment target, or the row renders an empty gap
    /// where its status should be — a silent, purely visual failure.
    func testTickSymbolsResolve() {
        for tick in [PermissionRow.Tick.ok, .cross, .pending] {
            XCTAssertNotNil(NSImage(systemSymbolName: tick.symbolName, accessibilityDescription: nil),
                            "SF Symbol missing: \(tick.symbolName)")
        }
    }

    func testOnlyCrossIsFailure() {
        XCTAssertTrue(PermissionRow.Tick.cross.isFailure)
        XCTAssertFalse(PermissionRow.Tick.ok.isFailure)
        XCTAssertFalse(PermissionRow.Tick.pending.isFailure)
    }
}
