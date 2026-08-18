# Launch at Login Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a "Launch at login" row to the Setup & Permissions window so Carabiner is normally already running, which is the only way to stop Chrome's "Open Carabiner?" dialog appearing on every cold launch.

**Architecture:** `SMAppService.mainApp` sits behind a two-method protocol (`LoginItemControlling`) so the status mapping and toggle decisions stay pure and testable, matching how `LivePermissionChecker` already isolates TCC. The row plugs into the existing `PermissionRow` model; the only genuinely new concept is that this row can be turned **off** in-process, which no existing row can — hence one new `ToggleIntent` case.

**Tech Stack:** Swift 5, AppKit + SwiftUI, `ServiceManagement`, XCTest.

## Global Constraints

- Deployment target is **macOS 13.0** (`app/project.yml`). `SMAppService` is macOS 13+, so no `@available` fencing is needed.
- Design doc: `docs/superpowers/specs/2026-08-18-launch-at-login-design.md`.
- Row copy, verbatim: title **"Launch at login"**, why **"So Carabiner is already running. Otherwise your browser asks 'Open Carabiner?' every time you use the button."**
- Login Items deep link, verified 2026-08-18 (window title read back as `Login Items & Extensions`): `x-apple.systempreferences:com.apple.LoginItems-Settings.extension`
- Default is **off**. Nothing in this plan registers the login item without the user toggling it.
- Every build needs the team ID exported first (gotcha #11/#12), and must build to `/tmp` not the iCloud-synced repo (gotcha #13):
  ```bash
  export CARABINER_TEAM_ID=SDC6T5U9G3
  cd app && xcodegen generate
  xcodebuild -project Carabiner.xcodeproj -scheme Carabiner \
    -configuration Debug -derivedDataPath /tmp/carabiner-dd build
  ```
- Tests run with: `xcodebuild -project Carabiner.xcodeproj -scheme Carabiner -destination 'platform=macOS' test` — use a **separate** derived-data path from any build you intend to install (gotcha #27).

## File Structure

| File | Responsibility |
|---|---|
| `app/Carabiner/Onboarding/LoginItem.swift` **(create)** | The `SMAppService` seam: `LoginItemStatus`, `LoginItemControlling`, `LiveLoginItemController`. Thin and deliberately untested, like `LivePermissionChecker`'s OS calls. |
| `app/Carabiner/Onboarding/PermissionModels.swift` **(modify)** | New `.launchAtLogin` row + copy, the pure `loginItemStatus(_:)` mapping, `ToggleIntent.revoke`, `canRevokeInProcess`, the settings URL. All pure, all tested. |
| `app/Carabiner/Onboarding/PermissionChecker.swift` **(modify)** | Wire the row into `status` / `request` / `openSystemSettings`, and add `revoke` to the seam. |
| `app/Carabiner/Onboarding/OnboardingViewModel.swift` **(modify)** | Handle the new `.revoke` intent. |
| `app/Carabiner/MenuBarController.swift` **(modify)** | Inject `LiveLoginItemController()` into the checker. |
| `app/CarabinerTests/LoginItemTests.swift` **(create)** | Mapping, intent, and checker-with-fake tests. |

**Adding a case to `PermissionRow` breaks every exhaustive switch over it.** These are all of them — the compiler will point at each, but knowing the list up front avoids a surprise:
- `PermissionModels.swift`: `title` (line ~40), `why` (~50), `requiresRunningTarget` (~71), `targetLaunchNote` (~94), `canBePrompted` (~284)
- `PermissionChecker.swift`: `status(for:)` (~69), `request(_:)` (~107), `openSystemSettings(for:)` (~150)

`mayLaunchTargetForStatusCheck` needs no change — it is `self == .carouselDialog`.

---

### Task 1: The SMAppService seam

**Files:**
- Create: `app/Carabiner/Onboarding/LoginItem.swift`
- Create: `app/CarabinerTests/LoginItemTests.swift`
- Modify: `app/Carabiner/Onboarding/PermissionModels.swift` (add `loginItemStatus`)

**Interfaces:**
- Produces: `enum LoginItemStatus { case enabled, notRegistered, requiresApproval, notFound }`; `protocol LoginItemControlling { var status: LoginItemStatus { get }; func register() throws; func unregister() throws }`; `final class LiveLoginItemController: LoginItemControlling`; `func loginItemStatus(_ status: LoginItemStatus) -> PermissionStatus`

- [ ] **Step 1: Write the failing test**

Create `app/CarabinerTests/LoginItemTests.swift`:

```swift
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
```

- [ ] **Step 2: Run it and watch it fail**

```bash
cd /Users/wissevellinga/Documents/OFF-PISTE/Carabiner/app
export CARABINER_TEAM_ID=SDC6T5U9G3
xcodegen generate
xcodebuild -project Carabiner.xcodeproj -scheme Carabiner -destination 'platform=macOS' \
  -derivedDataPath /tmp/carabiner-test test 2>&1 | tail -20
```

Expected: compile failure — `cannot find 'loginItemStatus' in scope` and `cannot find type 'LoginItemStatus'`.

- [ ] **Step 3: Create the seam**

Create `app/Carabiner/Onboarding/LoginItem.swift`:

```swift
import Foundation
import ServiceManagement

/// Mirrors `SMAppService.Status`, so everything in front of this seam can be tested without
/// touching the real login-item database. Same split as `LivePermissionChecker`: the OS call
/// is thin and untested, the judgement about what it MEANS is pure and tested.
enum LoginItemStatus: Equatable {
    case enabled
    case notRegistered
    case requiresApproval
    case notFound
}

protocol LoginItemControlling {
    var status: LoginItemStatus { get }
    /// Both of these throw. Callers must not assume success — see OnboardingViewModel.
    func register() throws
    func unregister() throws
}

/// The real thing. Deliberately has no logic worth testing: if this file ever grows a
/// decision, that decision belongs on the other side of the seam.
final class LiveLoginItemController: LoginItemControlling {
    var status: LoginItemStatus {
        switch SMAppService.mainApp.status {
        case .enabled:          return .enabled
        case .notRegistered:    return .notRegistered
        case .requiresApproval: return .requiresApproval
        case .notFound:         return .notFound
        @unknown default:       return .notFound
        }
    }

    func register() throws { try SMAppService.mainApp.register() }
    func unregister() throws { try SMAppService.mainApp.unregister() }
}
```

- [ ] **Step 4: Add the pure mapping**

In `app/Carabiner/Onboarding/PermissionModels.swift`, at the end of the file (next to `browserButtonStatus`, which is the same kind of function):

```swift
/// The login-item row's verdict. Kept next to `browserButtonStatus` and `notificationStatus`
/// because it is the same shape of thing: an OS value a test runner cannot produce, judged
/// by a function a test runner can.
///
/// `.requiresApproval` means the user switched Carabiner off in System Settings → Login
/// Items & Extensions. Calling `register()` again does NOT override that, so offering
/// "Allow" would be a button that cannot work; `.denied` is what routes the row to the
/// Settings deep link instead.
///
/// `.notFound` should be unreachable for `SMAppService.mainApp`. It maps to `.denied` rather
/// than anything softer on purpose: a tick must mean a real, checked yes.
func loginItemStatus(_ status: LoginItemStatus) -> PermissionStatus {
    switch status {
    case .enabled:          return .granted
    case .notRegistered:    return .notDetermined
    case .requiresApproval: return .denied
    case .notFound:         return .denied
    }
}
```

- [ ] **Step 5: Run the tests and watch them pass**

```bash
xcodebuild -project Carabiner.xcodeproj -scheme Carabiner -destination 'platform=macOS' \
  -derivedDataPath /tmp/carabiner-test test 2>&1 | grep -E "Executed|error:" | tail -5
```

Expected: all tests pass, including the four new ones.

- [ ] **Step 6: Commit**

```bash
cd /Users/wissevellinga/Documents/OFF-PISTE/Carabiner
git add app/Carabiner/Onboarding/LoginItem.swift app/Carabiner/Onboarding/PermissionModels.swift \
        app/CarabinerTests/LoginItemTests.swift
git commit -m "feat: SMAppService seam and the login-item status mapping

The OS call is thin and untested; the judgement about what its status means
is pure and tested, matching LivePermissionChecker's split. notFound maps to
denied rather than anything softer — a tick must mean a real checked yes."
```

---

### Task 2: The row, and the intent that can turn itself off

**Files:**
- Modify: `app/Carabiner/Onboarding/PermissionModels.swift`
- Modify: `app/CarabinerTests/LoginItemTests.swift`

**Interfaces:**
- Consumes: `loginItemStatus(_:)` from Task 1
- Produces: `PermissionRow.launchAtLogin`; `PermissionRow.canRevokeInProcess: Bool`; `ToggleIntent.revoke`; `let loginItemSettingsURL: String`

**Why this task exists as its own thing:** every existing row obeys "turning OFF is never something we can do ourselves" (`toggleAction`, line ~259) — macOS gives no way to revoke a TCC grant from inside the app. That rule is simply **false** for a login item: `unregister()` works. So the shared rule needs a row-level exception, and the decision must stay pure rather than leaking into the view model.

- [ ] **Step 1: Write the failing tests**

Append to `app/CarabinerTests/LoginItemTests.swift`, inside the class:

```swift
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
```

- [ ] **Step 2: Run and watch it fail**

```bash
cd /Users/wissevellinga/Documents/OFF-PISTE/Carabiner/app
xcodebuild -project Carabiner.xcodeproj -scheme Carabiner -destination 'platform=macOS' \
  -derivedDataPath /tmp/carabiner-test test 2>&1 | tail -20
```

Expected: compile failure — `type 'PermissionRow' has no member 'launchAtLogin'`.

- [ ] **Step 3: Add the row case and its copy**

In `PermissionModels.swift`, extend the enum and the two copy switches:

```swift
enum PermissionRow: CaseIterable {
    case notifications, browserAccess, carouselDialog, browserButton, fullDiskAccess, launchAtLogin
```

In `title`:
```swift
        case .launchAtLogin:  return "Launch at login"
```

In `why`:
```swift
        case .launchAtLogin:  return "So Carabiner is already running. Otherwise your browser asks 'Open Carabiner?' every time you use the button."
```

In `requiresRunningTarget` — add to the `false` list:
```swift
        case .notifications, .browserButton, .fullDiskAccess, .launchAtLogin: return false
```

In `targetLaunchNote` — add to the `nil` list:
```swift
        case .notifications, .browserButton, .fullDiskAccess, .launchAtLogin: return nil
```

In `canBePrompted` — `true`, because turning it on is a real in-process action rather than a Settings trip:
```swift
        case .notifications, .browserAccess, .carouselDialog, .browserButton, .launchAtLogin: return true
```

- [ ] **Step 4: Add the revoke intent**

In `PermissionModels.swift`, add the case to `ToggleIntent`:

```swift
enum ToggleIntent: Equatable {
    /// Ask the OS to prompt. Only legal from an undecided state.
    case request
    /// Deep-link to the relevant System Settings pane — the switch will not move until
    /// the user changes it there, which is the honest outcome.
    case openSystemSettings
    /// Undo the grant ourselves. Only legal where the app genuinely can: a login item is
    /// `unregister()`-able, unlike every TCC permission, where macOS offers no in-process
    /// revoke and `openSystemSettings` is the only truthful answer.
    case revoke
    /// Already in the requested state.
    case nothing
}
```

Add the row property, next to `canBePrompted`:

```swift
    /// Whether turning this row OFF is something the app can do itself.
    ///
    /// False for every TCC permission: macOS provides no API to hand a grant back, which is
    /// why `toggleAction` resolves every "off" to `.openSystemSettings`. A login item is not
    /// a TCC permission — `SMAppService.unregister()` is a real revoke — so that blanket
    /// rule would send the user to Settings to do something we could have just done.
    var canRevokeInProcess: Bool { self == .launchAtLogin }
```

Extend `intent(desired:status:)` — the revoke check goes **first**, before the existing rules:

```swift
    func intent(desired: Bool, status: PermissionStatus) -> ToggleIntent {
        // Before anything else: a row that can revoke itself must not be routed to System
        // Settings by the shared "off is never in-process" rule below.
        if !desired, canRevokeInProcess {
            return status == .granted ? .revoke : .nothing
        }
        guard desired else { return toggleAction(desired: desired, status: status) }
        guard canBePrompted else {
            return status == .notApplicable ? .nothing : .openSystemSettings
        }
        return toggleAction(desired: desired, status: status)
    }
```

- [ ] **Step 5: Add the settings URL**

In `PermissionModels.swift`, next to `fullDiskAccessSettingsURL`:

```swift
/// Verified 2026-08-18 by opening it and reading the window title back via System Events,
/// which returned literally `Login Items & Extensions` — the same instrument gotcha #37
/// established for the Full Disk Access link, and for the same reason: a deep link that
/// opens the wrong pane is indistinguishable from a working one until a human looks.
let loginItemSettingsURL = "x-apple.systempreferences:com.apple.LoginItems-Settings.extension"
```

- [ ] **Step 6: Fix the switches the new case broke**

The compiler will now flag `PermissionChecker.swift`'s three switches. Add a temporary
placeholder in each so the project compiles and Task 2's tests can run; Task 3 replaces them.

In `status(for:)`:
```swift
        case .launchAtLogin:
            DispatchQueue.main.async { completion(.notDetermined) } // replaced in Task 3
```

In `request(_:)`:
```swift
        case .launchAtLogin:
            status(for: row, completion: completion) // replaced in Task 3
```

In `openSystemSettings(for:)`:
```swift
        case .launchAtLogin:
            url = loginItemSettingsURL
```

- [ ] **Step 7: Run the tests and watch them pass**

```bash
xcodebuild -project Carabiner.xcodeproj -scheme Carabiner -destination 'platform=macOS' \
  -derivedDataPath /tmp/carabiner-test test 2>&1 | grep -E "Executed|error:|failed" | tail -5
```

Expected: all pass. Note `PermissionModelsTests`'s existing `testGrantedShowsTickAndNoButton`
and `testNotDeterminedOffersAllow` loop over `allCases`, so they now cover the new row too —
if either fails, the row's presentation is wrong, not the test.

- [ ] **Step 8: Mutation-check the one test that matters**

Revert `canRevokeInProcess` to `false` and confirm `testTurningItOffIsSomethingWeCanActuallyDo`
goes **red**:

```bash
# in PermissionModels.swift change: var canRevokeInProcess: Bool { false }
xcodebuild -project Carabiner.xcodeproj -scheme Carabiner -destination 'platform=macOS' \
  -derivedDataPath /tmp/carabiner-test test 2>&1 | grep -E "testTurningItOff|Executed" | tail -3
# then restore `self == .launchAtLogin`
```

Expected: red while mutated, green when restored. If it stays green, the test has no teeth
and must be fixed before moving on (gotcha #34).

- [ ] **Step 9: Commit**

```bash
cd /Users/wissevellinga/Documents/OFF-PISTE/Carabiner
git add app/Carabiner/Onboarding/PermissionModels.swift \
        app/Carabiner/Onboarding/PermissionChecker.swift \
        app/CarabinerTests/LoginItemTests.swift
git commit -m "feat: the Launch at login row, and an intent that can revoke itself

Every existing row obeys 'turning off is never something we can do ourselves',
because macOS offers no way to hand a TCC grant back. That is false for a login
item — unregister() is a real revoke — so the shared rule gets a row-level
exception, kept pure rather than special-cased in the view model.

Mutation-checked: reverting canRevokeInProcess turns the intent test red."
```

---

### Task 3: Wire the row to the real service

**Files:**
- Modify: `app/Carabiner/Onboarding/PermissionChecker.swift`
- Modify: `app/CarabinerTests/LoginItemTests.swift`

**Interfaces:**
- Consumes: `LoginItemControlling`, `loginItemStatus(_:)` (Task 1); `PermissionRow.launchAtLogin`, `loginItemSettingsURL` (Task 2)
- Produces: `PermissionChecking.revoke(_:completion:)` with a protocol-extension default; `LivePermissionChecker.init(browser:lastSeen:serverState:loginItem:)`

- [ ] **Step 1: Write the failing tests**

Append to `LoginItemTests.swift`, inside the class:

```swift
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
```

- [ ] **Step 2: Run and watch it fail**

Expected: compile failure — `LivePermissionChecker` has no `loginItem:` parameter and
`PermissionChecking` has no `revoke`.

- [ ] **Step 3: Add `revoke` to the seam**

In `PermissionChecker.swift`, add to the protocol and give it an inert default:

```swift
protocol PermissionChecking {
    /// Passive: never shows a prompt. Completion on the main queue.
    func status(for row: PermissionRow, completion: @escaping (PermissionStatus) -> Void)
    /// Active: shows the OS prompt (launching the browser first when it must be
    /// running for the prompt to appear). Completion on the main queue.
    func request(_ row: PermissionRow, completion: @escaping (PermissionStatus) -> Void)
    /// Undo a grant in process. Only `.launchAtLogin` can: see PermissionRow.canRevokeInProcess.
    func revoke(_ row: PermissionRow, completion: @escaping (PermissionStatus) -> Void)
    func openSystemSettings(for row: PermissionRow)
}

extension PermissionChecking {
    /// Default: nothing to revoke. Every TCC row lands here, and it must stay a plain
    /// status re-read — a default that took action would silently change every row's
    /// behaviour, and existing test fakes conform without knowing this method exists.
    func revoke(_ row: PermissionRow, completion: @escaping (PermissionStatus) -> Void) {
        status(for: row, completion: completion)
    }
}
```

- [ ] **Step 4: Add the dependency and the three real branches**

In `LivePermissionChecker`, add the stored property and init parameter:

```swift
    /// The login-item seam. Defaults to the real one so every existing call site and test —
    /// none of which knows this row exists — keeps working untouched.
    private let loginItem: LoginItemControlling

    init(browser: Browser, lastSeen: @escaping () -> [String: Date] = { [:] },
         serverState: @escaping () -> GrabServer.State = { .listening },
         loginItem: LoginItemControlling = LiveLoginItemController()) {
        self.browser = browser
        self.lastSeen = lastSeen
        self.serverState = serverState
        self.loginItem = loginItem
    }
```

Replace the Task 2 placeholder in `status(for:)`:

```swift
        case .launchAtLogin:
            // Cheap and local — no TCC round-trip, no target to start — so unlike
            // fullDiskAccess this needs no hop off the main queue.
            let s = loginItemStatus(loginItem.status)
            DispatchQueue.main.async { completion(s) }
```

Replace the placeholder in `request(_:)`:

```swift
        case .launchAtLogin:
            // Not an OS prompt: this genuinely performs the change. Errors are logged and
            // then the REAL status is read back, so a failed register presents as still-off
            // rather than as a switch that moved and did nothing (gotcha #37).
            do {
                try loginItem.register()
            } catch {
                NSLog("Carabiner: login item register failed: %@", error.localizedDescription)
            }
            let s = loginItemStatus(loginItem.status)
            DispatchQueue.main.async { completion(s) }
```

Add the `revoke` override (a new method on the class, which takes precedence over the
protocol-extension default):

```swift
    func revoke(_ row: PermissionRow, completion: @escaping (PermissionStatus) -> Void) {
        guard row == .launchAtLogin else { status(for: row, completion: completion); return }
        do {
            try loginItem.unregister()
        } catch {
            NSLog("Carabiner: login item unregister failed: %@", error.localizedDescription)
        }
        let s = loginItemStatus(loginItem.status)
        DispatchQueue.main.async { completion(s) }
    }
```

- [ ] **Step 5: Run the tests and watch them pass**

```bash
xcodebuild -project Carabiner.xcodeproj -scheme Carabiner -destination 'platform=macOS' \
  -derivedDataPath /tmp/carabiner-test test 2>&1 | grep -E "Executed|error:|failed" | tail -5
```

- [ ] **Step 6: Commit**

```bash
cd /Users/wissevellinga/Documents/OFF-PISTE/Carabiner
git add app/Carabiner/Onboarding/PermissionChecker.swift app/CarabinerTests/LoginItemTests.swift
git commit -m "feat: wire the login-item row to SMAppService through the checker

revoke() joins the seam with an inert protocol-extension default, so every
existing row and test fake is unaffected. A register() that throws is logged and
the real status read back, so a failed toggle reads off instead of pretending."
```

---

### Task 4: Make the switch actually revoke

**Files:**
- Modify: `app/Carabiner/Onboarding/OnboardingViewModel.swift`
- Modify: `app/CarabinerTests/LoginItemTests.swift`

**Interfaces:**
- Consumes: `ToggleIntent.revoke` (Task 2), `PermissionChecking.revoke` (Task 3)

- [ ] **Step 1: Write the failing test**

Append to `LoginItemTests.swift`, inside the class:

```swift
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
```

- [ ] **Step 2: Run and watch it fail**

Expected: compile failure — `switch must be exhaustive`, missing `.revoke` in
`OnboardingViewModel.setEnabled`. (If it compiles, `intent` is not returning `.revoke` and
Task 2 is wrong.)

- [ ] **Step 3: Handle the new intent**

In `OnboardingViewModel.setEnabled`, add a case to the `switch` — after `.openSystemSettings`,
before `.nothing`:

```swift
            case .revoke:
                // Only .launchAtLogin reaches here (PermissionRow.canRevokeInProcess). Unlike
                // every TCC row, "off" is a real action we can perform, so performing it is
                // the honest response to the switch rather than opening Settings.
                self.checker.revoke(row) { [weak self] _ in self?.refresh(row) }
```

- [ ] **Step 4: Run the tests and watch them pass**

```bash
xcodebuild -project Carabiner.xcodeproj -scheme Carabiner -destination 'platform=macOS' \
  -derivedDataPath /tmp/carabiner-test test 2>&1 | grep -E "Executed|error:|failed" | tail -5
```

- [ ] **Step 5: Mutation-check the wiring**

Change the `.revoke` case body to `self.refresh(row)` (i.e. drop the revoke call) and confirm
`testSwitchingTheRowOffRevokesInsteadOfOpeningSettings` goes **red**, then restore it. This is
the gotcha #34 check: the pure `intent` test in Task 2 would stay green either way, because a
correct decision that nobody acts on is still a correct decision.

- [ ] **Step 6: Commit**

```bash
cd /Users/wissevellinga/Documents/OFF-PISTE/Carabiner
git add app/Carabiner/Onboarding/OnboardingViewModel.swift app/CarabinerTests/LoginItemTests.swift
git commit -m "feat: the Launch at login switch performs a real revoke

Mutation-checked: dropping the revoke call from the view model turns the test
red while Task 2's pure intent test stays green — which is exactly the gap
gotcha #34 is about."
```

---

### Task 5: Ship it — wire the app and verify on the real system

**Files:**
- Modify: `app/Carabiner/MenuBarController.swift:57-65`

**Interfaces:**
- Consumes: `LiveLoginItemController` (Task 1), `LivePermissionChecker.init(…loginItem:)` (Task 3)

- [ ] **Step 1: Make the injection explicit at the construction site**

In `MenuBarController.showOnboarding()`, add the argument to the existing
`LivePermissionChecker(...)` call, after `serverState:`:

```swift
                                               serverState: { [weak self] in self?.grabServer?.state ?? .stopped },
                                               // Explicit rather than relying on the default,
                                               // so the one real construction site names every
                                               // seam it depends on.
                                               loginItem: LiveLoginItemController()),
```

- [ ] **Step 2: Full test run**

```bash
cd /Users/wissevellinga/Documents/OFF-PISTE/Carabiner/app
export CARABINER_TEAM_ID=SDC6T5U9G3
xcodegen generate
xcodebuild -project Carabiner.xcodeproj -scheme Carabiner -destination 'platform=macOS' \
  -derivedDataPath /tmp/carabiner-test test 2>&1 | grep -E "Executed|error:|failed" | tail -5
```

Expected: everything passes (227+ Swift tests plus the new ones).

- [ ] **Step 3: Build and install**

Use a **different** derived-data path from the test run — a `test` action leaves
`CarabinerTests.xctest` inside the bundle and `build` does not remove it (gotcha #27):

```bash
xcodebuild -project Carabiner.xcodeproj -scheme Carabiner -configuration Debug \
  -derivedDataPath /tmp/carabiner-dd build 2>&1 | tail -3
pkill -x Carabiner; rm -rf ~/Applications/Carabiner.app
cp -R /tmp/carabiner-dd/Build/Products/Debug/Carabiner.app ~/Applications/
open ~/Applications/Carabiner.app
```

Keep exactly one copy of this bundle id on disk (gotchas #11, #27):

```bash
ls -d /Applications/Carabiner.app ~/Applications/Carabiner.app 2>/dev/null
```

- [ ] **Step 4: Verify on the real system — needs a human**

Nothing above proves macOS actually registers anything; the suite only ever drove a fake.

1. Status menu → **Setup & Permissions**. A sixth row, "Launch at login", reads **off**.
2. Toggle it **on** → Carabiner appears in System Settings → Login Items & Extensions.
3. Toggle it **off** → it disappears from that list, **without** System Settings opening.
4. Turn it on again, then switch Carabiner off inside System Settings. Reopen the window:
   the row reads `.denied` — a cross and "Open System Settings", **not** "Allow".
5. **The one that actually proves the feature:** log out and back in. Carabiner is running,
   and clicking an Instagram button downloads with **no** "Open Carabiner?" prompt.

- [ ] **Step 5: Commit, and record the result honestly**

```bash
cd /Users/wissevellinga/Documents/OFF-PISTE/Carabiner
git add app/Carabiner/MenuBarController.swift
git commit -m "feat: offer Launch at login in Setup & Permissions

Chrome's 'Open Carabiner?' dialog has no 'always allow' checkbox, so every cold
launch prompts forever. This removes the cause rather than smoothing it; the
cold-launch fallback stays for anyone who declines."
```

Then update `CLAUDE.md`'s status section with what a human actually verified — and, if step 4.5
was not performed, say so rather than implying it. An unlogged-out login item is "registered",
not "verified".

---

## Self-Review

**Spec coverage:** mechanism (Task 1) · row + copy + default-off (Task 2) · status mapping incl. `.notFound` (Task 1) · deep link (Task 2, verified) · errors visible (Tasks 3-4) · testing split with disclosed limits (Tasks 1-4) · known limitation and human checklist (Task 5). No gaps.

**One spec correction made here:** the spec says a failed toggle "surfaces the thrown reason" in the row. Showing a reason would need a new `PermissionStatus` case carrying a message, which is more churn than the failure justifies. What is implemented instead: the row reads the **real** status back, so a failed register presents as still-off (never a lying switch), and the reason is logged via `NSLog`. The spec should be amended to match rather than left describing something the plan does not build.

**Type consistency:** `LoginItemStatus` / `LoginItemControlling` / `LiveLoginItemController` / `loginItemStatus(_:)` / `loginItemSettingsURL` / `canRevokeInProcess` / `ToggleIntent.revoke` / `PermissionChecking.revoke(_:completion:)` are each defined once and used with the same spelling throughout.
