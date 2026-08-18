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
}
