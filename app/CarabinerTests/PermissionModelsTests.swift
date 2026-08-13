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

    /// ...and only the browser row mentions the browser. Telling the carousel row that
    /// Chrome will open is a lie — its target is System Events.
    func testTargetLaunchNoteNamesTheRightTarget() {
        XCTAssertEqual(PermissionRow.carouselDialog.presentation(for: .targetNotRunning).detail,
                       "System Events will start first")
        XCTAssertNil(PermissionRow.notifications.presentation(for: .targetNotRunning).detail)
    }

    /// The carousel bug, 2026-08-11: request() skipped the launch dance for System Events
    /// on the belief it was an "always-available agent". It is not — it quits when idle,
    /// and AEDeterminePermissionToAutomateTarget then returns procNotFound (-600) and
    /// shows no prompt, so the switch could never be turned on. Both Automation rows need
    /// their target alive before asking; notifications needs no target at all.
    func testBothAutomationRowsRequireARunningTarget() {
        XCTAssertTrue(PermissionRow.browserAccess.requiresRunningTarget)
        XCTAssertTrue(PermissionRow.carouselDialog.requiresRunningTarget)
        XCTAssertFalse(PermissionRow.notifications.requiresRunningTarget)
    }

    /// A stopped target and a refused one both return procNotFound, so a granted carousel
    /// permission renders as off whenever System Events has idled out — which is most of
    /// the time. Starting a faceless system agent to answer that is free; starting the
    /// user's browser to render a settings row is not.
    func testOnlySystemEventsMayBeStartedForAPassiveCheck() {
        XCTAssertTrue(PermissionRow.carouselDialog.mayLaunchTargetForStatusCheck)
        XCTAssertFalse(PermissionRow.browserAccess.mayLaunchTargetForStatusCheck)
        XCTAssertFalse(PermissionRow.notifications.mayLaunchTargetForStatusCheck)
    }

    /// Auto-launching only makes sense for a row that needs a running target at all.
    func testAutoLaunchImpliesARunningTargetIsRequired() {
        for row in PermissionRow.allCases where row.mayLaunchTargetForStatusCheck {
            XCTAssertTrue(row.requiresRunningTarget,
                          "\(row.title): may auto-launch but claims no target is needed")
        }
    }

    /// Every row that must launch something first should say so, and no row that doesn't
    /// should claim it will. Pins the two properties together so a new row cannot add one
    /// without the other.
    func testLaunchNoteExistsExactlyWhenATargetMustRun() {
        for row in PermissionRow.allCases {
            XCTAssertEqual(row.requiresRunningTarget, row.targetLaunchNote != nil,
                           "\(row.title): requiresRunningTarget and targetLaunchNote disagree")
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

    // MARK: - toggle intent
    //
    // macOS lets an app prompt once and never again: it cannot revoke its own grant, and
    // cannot re-ask after a refusal. So exactly one transition is performable in process
    // and every other flip has to hand off to System Settings.

    func testTurningOnAnUndecidedPermissionPrompts() {
        XCTAssertEqual(toggleAction(desired: true, status: .notDetermined), .request)
        XCTAssertEqual(toggleAction(desired: true, status: .targetNotRunning), .request)
    }

    /// Re-asking after a refusal does nothing at all — requestAuthorization returns
    /// instantly with no prompt — so the switch must send the user somewhere real.
    func testTurningOnADeniedPermissionOpensSystemSettings() {
        XCTAssertEqual(toggleAction(desired: true, status: .denied), .openSystemSettings)
    }

    /// The whole reason the switch cannot behave like a switch.
    func testTurningOffAlwaysOpensSystemSettings() {
        XCTAssertEqual(toggleAction(desired: false, status: .granted), .openSystemSettings)
    }

    func testNoOpTransitionsDoNothing() {
        XCTAssertEqual(toggleAction(desired: true, status: .granted), .nothing)
        XCTAssertEqual(toggleAction(desired: false, status: .denied), .nothing)
        XCTAssertEqual(toggleAction(desired: false, status: .notDetermined), .nothing)
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

extension PermissionModelsTests {
    func testBrowserButtonRowExists() {
        XCTAssertTrue(PermissionRow.allCases.contains(.browserButton))
    }
    func testBrowserButtonIsGrantedOnlyWhenSeenRecently() {
        let now = Date()
        XCTAssertEqual(browserButtonStatus(lastSeen: now, now: now), .granted)
        XCTAssertEqual(browserButtonStatus(lastSeen: nil, now: now), .notDetermined)
        // A browser that has not checked in for a month is not proof of anything.
        XCTAssertEqual(browserButtonStatus(lastSeen: now.addingTimeInterval(-60*60*24*30), now: now),
                       .notDetermined)
    }
    func testBrowserButtonTurningOnStartsTheInstall() {
        XCTAssertEqual(PermissionRow.browserButton.intent(desired: true, status: .notDetermined),
                       .request)
    }
    func testBrowserButtonTitleAndWhy() {
        XCTAssertEqual(PermissionRow.browserButton.title, "Instagram button")
        XCTAssertFalse(PermissionRow.browserButton.why.isEmpty)
    }
    func testExistingRowsKeepTheGenericIntent() {
        // The new row-aware wrapper must not change behaviour for the rows that already
        // worked — it only exists so a row that cannot be prompted can say so.
        for row in [PermissionRow.notifications, .browserAccess, .carouselDialog] {
            for status: PermissionStatus in [.granted, .denied, .notDetermined, .targetNotRunning] {
                XCTAssertEqual(row.intent(desired: true, status: status),
                               toggleAction(desired: true, status: status),
                               "\(row) changed behaviour at \(status)")
            }
        }
    }
}

extension PermissionModelsTests {
    func testFullDiskAccessRowExists() {
        XCTAssertTrue(PermissionRow.allCases.contains(.fullDiskAccess))
    }
    func testFullDiskAccessAlwaysDeepLinks() {
        // macOS has no API to grant FDA, and unlike Automation it cannot even be
        // *prompted* for. Opening the right System Settings pane is the only honest
        // action at every status — including .notDetermined, where every other row
        // would prompt.
        for status: PermissionStatus in [.notDetermined, .denied, .targetNotRunning] {
            XCTAssertEqual(PermissionRow.fullDiskAccess.intent(desired: true, status: status),
                           .openSystemSettings)
        }
    }
    func testFullDiskAccessCannotBePrompted() {
        XCTAssertFalse(PermissionRow.fullDiskAccess.canBePrompted)
        for row in [PermissionRow.notifications, .browserAccess, .carouselDialog, .browserButton] {
            XCTAssertTrue(row.canBePrompted, "\(row) should still be promptable")
        }
    }
    func testFullDiskAccessTitleAndWhy() {
        XCTAssertEqual(PermissionRow.fullDiskAccess.title, "Full Disk Access")
        XCTAssertFalse(PermissionRow.fullDiskAccess.why.isEmpty)
    }
    /// Turning fullDiskAccess "off" is meaningless (there's nothing we granted to revoke),
    /// but the intent function must still resolve to something sane rather than crash —
    /// `desired: false` always defers to the shared rule regardless of canBePrompted.
    func testFullDiskAccessTurningOffDefersToTheSharedRule() {
        XCTAssertEqual(PermissionRow.fullDiskAccess.intent(desired: false, status: .granted),
                       toggleAction(desired: false, status: .granted))
    }
}
