import XCTest
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
}
