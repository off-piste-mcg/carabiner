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

    func testNotFoundStillLetsUsTryToRegister() {
        // Measured 2026-08-19: mainApp reports .notFound before the FIRST registration —
        // `sudo sfltool dumpbtm` showed macOS holding no record for the bundle id at all.
        // This originally mapped to .denied, which routed the row to "Open System Settings"
        // and sent the user to a list Carabiner was not in, while register() was never
        // called once. Not a tick (that would be a lie), but not a dead end either.
        XCTAssertEqual(loginItemStatus(.notFound), .notDetermined)
        XCTAssertEqual(PermissionRow.launchAtLogin.intent(desired: true, status: loginItemStatus(.notFound)),
                       .request, "the toggle must actually attempt registration")
    }

    func testNoStatusEverRendersAsAFalseTick() {
        // The property the .notFound change must not break: only a real .enabled is a tick.
        for status in [LoginItemStatus.notRegistered, .requiresApproval, .notFound] {
            XCTAssertNotEqual(loginItemStatus(status), .granted, "\(status) must not read as granted")
        }
        XCTAssertEqual(loginItemStatus(.enabled), .granted)
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

    // MARK: - Wiring (gotcha #34: the mapping being right proves nothing about the call site)

    /// Records what was asked of it, and can be made to fail on demand.
    private final class FakeLoginItem: LoginItemControlling {
        var status: LoginItemStatus = .notRegistered
        var registerCalls = 0
        var unregisterCalls = 0
        var registerError: Error?

        func register() throws {
            registerCalls += 1
            if let registerError { throw registerError }
            status = .enabled
        }
        func unregister() throws {
            unregisterCalls += 1
            status = .notRegistered
        }
    }

    private struct Boom: Error {}

    private func waitForStatus(_ checker: PermissionChecking,
                               _ call: (PermissionChecking, @escaping (PermissionStatus) -> Void) -> Void)
        -> PermissionStatus {
        let done = expectation(description: "status")
        var result: PermissionStatus?
        call(checker) { s in result = s; done.fulfill() }
        wait(for: [done], timeout: 2)
        return result ?? .notDetermined
    }

    func testCheckerReportsTheRealServiceStatus() {
        let fake = FakeLoginItem()
        fake.status = .enabled
        let checker = LivePermissionChecker(browser: .chrome, loginItem: fake)
        let s = waitForStatus(checker) { c, done in c.status(for: .launchAtLogin, completion: done) }
        XCTAssertEqual(s, .granted)
    }

    func testRequestRegistersAndReportsTheResultingStatus() {
        let fake = FakeLoginItem()
        let checker = LivePermissionChecker(browser: .chrome, loginItem: fake)
        let s = waitForStatus(checker) { c, done in c.request(.launchAtLogin, completion: done) }
        XCTAssertEqual(fake.registerCalls, 1)
        XCTAssertEqual(s, .granted)
    }

    func testAFailedRegisterLeavesTheRowOffRatherThanLying() {
        // The switch must land on the truth. A register() that throws leaves the item
        // unregistered, so the row must read off — gotcha #37 is a row whose Allow silently
        // did nothing and looked fine.
        let fake = FakeLoginItem()
        fake.registerError = Boom()
        let checker = LivePermissionChecker(browser: .chrome, loginItem: fake)
        let s = waitForStatus(checker) { c, done in c.request(.launchAtLogin, completion: done) }
        XCTAssertEqual(fake.registerCalls, 1)
        XCTAssertEqual(s, .notDetermined, "a thrown register must not present as granted")
    }

    func testRevokeUnregistersAndReportsOff() {
        let fake = FakeLoginItem()
        fake.status = .enabled
        let checker = LivePermissionChecker(browser: .chrome, loginItem: fake)
        let s = waitForStatus(checker) { c, done in c.revoke(.launchAtLogin, completion: done) }
        XCTAssertEqual(fake.unregisterCalls, 1)
        XCTAssertEqual(s, .notDetermined)
    }

    func testRevokeOnAnyOtherRowTouchesNothing() {
        // The protocol default must be inert: no existing row has an in-process revoke, and
        // a default that DID something would be a silent behaviour change for all of them.
        let fake = FakeLoginItem()
        let checker = LivePermissionChecker(browser: .chrome, loginItem: fake)
        _ = waitForStatus(checker) { c, done in c.revoke(.notifications, completion: done) }
        XCTAssertEqual(fake.unregisterCalls, 0)
    }

    // MARK: - View model

    @MainActor
    func testSwitchingTheRowOffRevokesInsteadOfOpeningSettings() async {
        // The point of the whole task: without this the switch would deep-link to System
        // Settings to do something the app can do itself in one call.
        let fake = FakeLoginItem()
        fake.status = .enabled
        let checker = LivePermissionChecker(browser: .chrome, loginItem: fake)
        let model = OnboardingViewModel(checker: checker)

        model.setEnabled(false, for: .launchAtLogin)
        try? await Task.sleep(nanoseconds: 300_000_000)

        XCTAssertEqual(fake.unregisterCalls, 1)
        XCTAssertEqual(fake.status, .notRegistered)
    }

    @MainActor
    func testSwitchingTheRowOnRegisters() async {
        let fake = FakeLoginItem()
        let checker = LivePermissionChecker(browser: .chrome, loginItem: fake)
        let model = OnboardingViewModel(checker: checker)

        model.setEnabled(true, for: .launchAtLogin)
        try? await Task.sleep(nanoseconds: 300_000_000)

        XCTAssertEqual(fake.registerCalls, 1)
        XCTAssertEqual(fake.status, .enabled)
    }
}
