import XCTest
@testable import Carabiner

/// The login-item row's pure half. `SMAppService` itself is never exercised here — it
/// mutates real system state, so a unit test cannot honestly drive it. What IS testable is
/// the mapping from its status to a row, which is where the judgement lives.
final class LoginItemTests: XCTestCase {

    func testEnabledIsGranted() {
        XCTAssertEqual(loginItemStatus(.enabled), .granted)
    }

    func testNotRegisteredIsNotDetermined() {
        // The ordinary opt-in state: off, and the row offers "Allow".
        XCTAssertEqual(loginItemStatus(.notRegistered), .notDetermined)
    }

    func testRequiresApprovalIsDenied() {
        // The user switched it off in System Settings. Nothing in-app can undo that, so the
        // row must send them there rather than offering an "Allow" that cannot work.
        XCTAssertEqual(loginItemStatus(.requiresApproval), .denied)
    }

    func testNotFoundIsDeniedRatherThanASilentPass() {
        // Should not happen for mainApp. A state we do not understand must never render as
        // a tick — a false green here is exactly the failure gotcha #28 exists about.
        XCTAssertEqual(loginItemStatus(.notFound), .denied)
    }

    // MARK: - The row

    func testRowCopyNamesTheCostOfLeavingItOff() {
        XCTAssertEqual(PermissionRow.launchAtLogin.title, "Launch at login")
        XCTAssertEqual(PermissionRow.launchAtLogin.why,
                       "So Carabiner is already running. Otherwise your browser asks "
                       + "'Open Carabiner?' every time you use the button.")
    }

    func testRowHasNoTargetAppToLaunch() {
        // These three exist for the Automation rows, which must start Chrome or System
        // Events before the OS will even show a prompt. There is no target here.
        XCTAssertFalse(PermissionRow.launchAtLogin.requiresRunningTarget)
        XCTAssertFalse(PermissionRow.launchAtLogin.mayLaunchTargetForStatusCheck)
        XCTAssertNil(PermissionRow.launchAtLogin.targetLaunchNote)
    }

    func testTurningItOffIsSomethingWeCanActuallyDo() {
        // THE difference from every other row. Every TCC row resolves "off" to
        // .openSystemSettings because macOS offers no in-process revoke. unregister() is a
        // real revoke, so this row must not send the user to Settings to do what we can do.
        XCTAssertTrue(PermissionRow.launchAtLogin.canRevokeInProcess)
        XCTAssertEqual(PermissionRow.launchAtLogin.intent(desired: false, status: .granted),
                       .revoke)
    }

    func testEveryOtherRowStillCannotRevokeItself() {
        for row in PermissionRow.allCases where row != .launchAtLogin {
            XCTAssertFalse(row.canRevokeInProcess, "\(row) must not claim an in-process revoke")
            XCTAssertEqual(row.intent(desired: false, status: .granted), .openSystemSettings,
                           "\(row) has no in-process revoke and must still deep-link")
        }
    }

    func testTurningItOnFromOffAsksUsToRegister() {
        XCTAssertEqual(PermissionRow.launchAtLogin.intent(desired: true, status: .notDetermined),
                       .request)
    }

    func testTurningItOnWhenSettingsHasItBlockedDeepLinks() {
        // .requiresApproval → .denied → register() would silently not stick, so the only
        // honest action is to send the user where they can actually change it.
        XCTAssertEqual(PermissionRow.launchAtLogin.intent(desired: true, status: .denied),
                       .openSystemSettings)
    }

    func testRevokingWhenAlreadyOffDoesNothing() {
        XCTAssertEqual(PermissionRow.launchAtLogin.intent(desired: false, status: .notDetermined),
                       .nothing)
    }
}
