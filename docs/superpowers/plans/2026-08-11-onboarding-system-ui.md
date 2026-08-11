# Onboarding System UI + Notification Verification Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Rebuild the Setup & Permissions window as a stock-looking macOS pane, and stop the notifications row reporting success it hasn't verified.

**Architecture:** The tested pure layer (`PermissionModels`, `HotkeyTestModel`) keeps all decisions and gains one new pure function for the notification verdict. `LivePermissionChecker` shrinks to an OS-value fetcher. The hand-built `NSStackView` layout is replaced by a SwiftUI `Form` hosted in the existing `NSWindowController`, with a small `ObservableObject` bridging the two.

**Tech Stack:** Swift, AppKit (window lifecycle), SwiftUI (`Form` + `.formStyle(.grouped)`), UserNotifications, XCTest.

## Global Constraints

- **Deployment target: macOS 13.0.** `Form`, `.formStyle(.grouped)` and `LabeledContent` are all macOS 13+ — do not use anything newer.
- **Verified available on this SDK:** `UNNotificationSettings.alertSetting`; SF Symbols `checkmark.circle.fill`, `exclamationmark.triangle.fill`, `circle.dotted`.
- **Do not change** which permissions exist, their order, their copy, the hotkey test's behaviour, or when the window auto-opens.
- **Do not add a fourth `PermissionStatus` case.** "Authorized but invisible" maps onto `.denied` — the user's remedy is identical.
- **Drop** the OFF-PISTE blue `#2D5BFF` from this window; use the system accent.
- **Keep** `OnboardingWindowController` as the owner of window lifecycle, the hotkey timer/intercept, `windowDidBecomeKey` refresh, `windowWillClose` cancel, and the `onboardingShown` defaults key.
- The OS seam (`LivePermissionChecker`) stays deliberately untested; judgement moves in front of it.
- Build with `CARABINER_TEAM_ID` exported; tests run via `xcodebuild ... -destination 'platform=macOS' test`.

---

### Task 1: The pure notification verdict

**Files:**
- Modify: `app/Carabiner/Onboarding/PermissionModels.swift`
- Test: `app/CarabinerTests/PermissionModelsTests.swift`

**Interfaces:**
- Consumes: `PermissionStatus` (existing).
- Produces, for Task 2: a free function
  `notificationStatus(authorization: UNAuthorizationStatus, alert: UNNotificationSetting) -> PermissionStatus`

- [ ] **Step 1: Write the failing tests**

Append to `app/CarabinerTests/PermissionModelsTests.swift`, inside the class:

```swift
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
```

Add the import at the top of the file, below `@testable import Carabiner`:

```swift
import UserNotifications
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
export CARABINER_TEAM_ID=$(security find-certificate -a -c "Apple Development" -p \
  | openssl x509 -noout -subject | tr ',/' '\n\n' \
  | sed -nE 's/.*OU=([A-Z0-9]{10}).*/\1/p' | head -1)
cd app && xcodegen generate && xcodebuild -project Carabiner.xcodeproj -scheme Carabiner \
  -destination 'platform=macOS' test 2>&1 | tail -20
```
Expected: compile failure — `cannot find 'notificationStatus' in scope`.

- [ ] **Step 3: Write the implementation**

In `app/Carabiner/Onboarding/PermissionModels.swift`, change the import line at the top from `import Foundation` to:

```swift
import Foundation
import UserNotifications
```

Then append at the end of the file:

```swift
/// The notifications row's verdict, kept pure so it can be tested — the OS values it
/// judges come from APIs a test runner cannot drive.
///
/// Granted requires BOTH that we are authorized AND that alerts are actually visible.
/// Authorization can be on while the alert style is "None", in which case notifications
/// land silently in Notification Centre and never appear on screen. For Carabiner that is
/// indistinguishable from broken: the banner is the whole feature, and a grab that
/// finishes invisibly looks exactly like a hotkey that never fired (gotchas #14, #22).
///
/// Both failures return .denied rather than a new case, because the user's action is the
/// same either way — open System Settings and fix it.
func notificationStatus(authorization: UNAuthorizationStatus,
                        alert: UNNotificationSetting) -> PermissionStatus {
    switch authorization {
    case .authorized, .provisional:
        return alert == .enabled ? .granted : .denied
    case .denied:
        return .denied
    default:
        return .notDetermined
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run the same `xcodebuild ... test` command as Step 2.
Expected: all tests pass, including the six new ones.

- [ ] **Step 5: Commit**

```bash
git add app/Carabiner/Onboarding/PermissionModels.swift app/CarabinerTests/PermissionModelsTests.swift
git commit -m "feat(onboarding): pure notification verdict requiring visible alerts"
```

---

### Task 2: Make the checker use the verdict on both paths

The bug is not only in `request` — the passive `status` path has the same blind spot, so an already-broken install shows a false tick when the window opens.

**Files:**
- Modify: `app/Carabiner/Onboarding/PermissionChecker.swift:22-39` (the `.notifications` case of `status`)
- Modify: `app/Carabiner/Onboarding/PermissionChecker.swift:41-47` (the `.notifications` case of `request`)

**Interfaces:**
- Consumes: `notificationStatus(authorization:alert:)` from Task 1.
- Produces: no new API. `PermissionChecking` is unchanged, so the window needs no edits for this task.

- [ ] **Step 1: Replace the `.notifications` case in `status(for:)`**

Replace lines 24-33 (the `case .notifications:` block inside `status`) with:

```swift
        case .notifications:
            UNUserNotificationCenter.current().getNotificationSettings { settings in
                let s = notificationStatus(authorization: settings.authorizationStatus,
                                           alert: settings.alertSetting)
                DispatchQueue.main.async { completion(s) }
            }
```

- [ ] **Step 2: Replace the `.notifications` case in `request(_:)`**

Replace lines 43-47 (the `case .notifications:` block inside `request`) with:

```swift
        case .notifications:
            // The `granted` flag is deliberately ignored. It reports what the prompt
            // returned, not what the system ended up with — on 2026-08-11 a user allowed
            // the prompt and still had "Allow notifications" switched off, so the row went
            // green while nothing was ever delivered. Ask the OS what is actually true.
            UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, error in
                if let error { NSLog("Carabiner: notification authorization failed: %@", error.localizedDescription) }
                UNUserNotificationCenter.current().getNotificationSettings { settings in
                    let s = notificationStatus(authorization: settings.authorizationStatus,
                                               alert: settings.alertSetting)
                    DispatchQueue.main.async { completion(s) }
                }
            }
```

- [ ] **Step 3: Build and run the suite**

```bash
cd app && xcodebuild -project Carabiner.xcodeproj -scheme Carabiner \
  -destination 'platform=macOS' test 2>&1 | tail -12
```
Expected: `** TEST SUCCEEDED **`. No test covers the seam itself by design; this step is checking nothing else broke.

- [ ] **Step 4: Verify the healthy case by hand**

```bash
cd app && xcodebuild -project Carabiner.xcodeproj -scheme Carabiner \
  -configuration Debug -derivedDataPath build build 2>&1 | tail -3
pkill -x Carabiner; rm -rf ~/Applications/Carabiner.app
cp -R build/Build/Products/Debug/Carabiner.app ~/Applications/ && open ~/Applications/Carabiner.app
```
Open the setup window from the status menu. Expected: the notifications row shows a tick, because notifications are currently working on this machine. **If it shows a warning instead, stop** — that means the verdict is wrong for a healthy install, which is worse than the bug being fixed.

- [ ] **Step 5: Commit**

```bash
git add app/Carabiner/Onboarding/PermissionChecker.swift
git commit -m "fix(onboarding): verify notification state instead of trusting the prompt"
```

---

### Task 3: SF Symbol names for the status ticks

Small and pure, so it lands before the view that consumes it.

**Files:**
- Modify: `app/Carabiner/Onboarding/PermissionModels.swift`
- Test: `app/CarabinerTests/PermissionModelsTests.swift`

**Interfaces:**
- Produces, for Task 5: `PermissionRow.Tick.symbolName: String` and `PermissionRow.Tick.isFailure: Bool`.

- [ ] **Step 1: Write the failing tests**

Append inside the test class:

```swift
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
```

Add to the imports at the top of the test file:

```swift
import AppKit
```

- [ ] **Step 2: Run tests to verify they fail**

Run the `xcodebuild ... test` command from Task 1 Step 2.
Expected: compile failure — `value of type 'PermissionRow.Tick' has no member 'symbolName'`.

- [ ] **Step 3: Write the implementation**

Append to `app/Carabiner/Onboarding/PermissionModels.swift`:

```swift
extension PermissionRow.Tick {
    /// Verified present on the macOS 13 floor by PermissionModelsTests.
    var symbolName: String {
        switch self {
        case .ok:      return "checkmark.circle.fill"
        case .cross:   return "exclamationmark.triangle.fill"
        case .pending: return "circle.dotted"
        }
    }

    /// Drives the row's tint. Only a cross is a problem the user must act on; pending is
    /// merely "not asked yet" and should not read as an error.
    var isFailure: Bool { self == .cross }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run the `xcodebuild ... test` command.
Expected: `** TEST SUCCEEDED **`.

- [ ] **Step 5: Commit**

```bash
git add app/Carabiner/Onboarding/PermissionModels.swift app/CarabinerTests/PermissionModelsTests.swift
git commit -m "feat(onboarding): SF Symbol names for status ticks"
```

---

### Task 4: The view model bridging AppKit state to SwiftUI

**Files:**
- Create: `app/Carabiner/Onboarding/OnboardingViewModel.swift`

**Interfaces:**
- Consumes: `PermissionChecking`, `PermissionRow`, `PermissionStatus`, `RowPresentation`, `HotkeyTestPresentation`.
- Produces, for Tasks 5 and 6:
  - `final class OnboardingViewModel: ObservableObject`
  - `@Published private(set) var statuses: [PermissionRow: PermissionStatus]`
  - `@Published var hotkey: HotkeyTestPresentation`
  - `func refreshAll()`
  - `func act(on row: PermissionRow)`
  - `var onBeginHotkeyTest: () -> Void` (set by the controller, which owns the timer)

- [ ] **Step 1: Create the file**

```swift
import Foundation
import SwiftUI

/// Bridges the OS-facing checker to SwiftUI. Holds no decisions of its own: every verdict
/// comes from PermissionRow.presentation(for:) or HotkeyTestModel, both of which are pure
/// and tested. This exists only because SwiftUI needs an ObservableObject to observe.
@MainActor
final class OnboardingViewModel: ObservableObject {
    @Published private(set) var statuses: [PermissionRow: PermissionStatus] = [:]
    @Published var hotkey: HotkeyTestPresentation = HotkeyTestModel().presentation

    /// The hotkey test needs a Timer and the app's hotkey intercept, both of which belong
    /// to the window controller. The view model just reports the button was pressed.
    var onBeginHotkeyTest: () -> Void = {}

    private let checker: PermissionChecking

    init(checker: PermissionChecking) { self.checker = checker }

    func refreshAll() {
        for row in PermissionRow.allCases { refresh(row) }
    }

    func refresh(_ row: PermissionRow) {
        checker.status(for: row) { [weak self] status in
            self?.statuses[row] = status
        }
    }

    func presentation(for row: PermissionRow) -> RowPresentation {
        row.presentation(for: statuses[row] ?? .notDetermined)
    }

    func act(on row: PermissionRow) {
        checker.status(for: row) { [weak self] status in
            guard let self else { return }
            switch row.presentation(for: status).action {
            case .request:
                self.checker.request(row) { [weak self] _ in self?.refresh(row) }
            case .openSystemSettings:
                self.checker.openSystemSettings(for: row)
            case .none:
                self.refresh(row)
            }
        }
    }
}
```

- [ ] **Step 2: Build to check it compiles**

```bash
cd app && xcodegen generate && xcodebuild -project Carabiner.xcodeproj -scheme Carabiner \
  -configuration Debug -derivedDataPath build build 2>&1 | tail -4
```
Expected: `** BUILD SUCCEEDED **`. The file is not referenced yet; this only proves it compiles.

- [ ] **Step 3: Commit**

```bash
git add app/Carabiner/Onboarding/OnboardingViewModel.swift
git commit -m "feat(onboarding): view model bridging the checker to SwiftUI"
```

---

### Task 5: The SwiftUI window body

**Files:**
- Create: `app/Carabiner/Onboarding/OnboardingView.swift`

**Interfaces:**
- Consumes: `OnboardingViewModel`, `PermissionRow`, `RowPresentation`, `HotkeyTestPresentation`, `PermissionRow.Tick.symbolName` / `.isFailure`.
- Produces, for Task 6: `struct OnboardingView: View`, initialised as `OnboardingView(model: someViewModel)`.

- [ ] **Step 1: Create the file**

```swift
import SwiftUI

/// The setup window's body. Deliberately dumb: it renders whatever the view model's
/// presentations say and forwards taps. Nothing here decides anything.
struct OnboardingView: View {
    @ObservedObject var model: OnboardingViewModel

    var body: some View {
        Form {
            Section {
                ForEach(PermissionRow.allCases, id: \.self) { row in
                    let p = model.presentation(for: row)
                    SetupRow(tick: p.tick,
                             title: row.title,
                             why: row.why,
                             detail: p.detail,
                             buttonTitle: p.buttonTitle) { model.act(on: row) }
                }
                SetupRow(tick: model.hotkey.tick,
                         title: "Hotkey",
                         why: "One keystroke, from anywhere.",
                         detail: model.hotkey.detail,
                         buttonTitle: model.hotkey.buttonTitle) { model.onBeginHotkeyTest() }
            } header: {
                header
            } footer: {
                Text("Your first grab may ask for access to Chrome's \"Safe Storage\" — "
                     + "click Always Allow. That's macOS guarding Chrome's cookies, which "
                     + "Carabiner reads to act as you.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.top, 4)
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var header: some View {
        VStack(spacing: 6) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 64, height: 64)
            Text("Carabiner").font(.title2).bold()
            Text("Clip a post. Keep the file.")
                .font(.body)
                .foregroundStyle(.secondary)
            Text("Open an Instagram post in Chrome, press ⌃⌥⌘V, and the file lands in "
                 + "your Downloads folder. Carousels ask: this slide, or all of them.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.top, 2)
        }
        .frame(maxWidth: .infinity)
        .padding(.bottom, 12)
        .textCase(nil)          // Section headers uppercase by default; this is prose.
    }
}

/// One row: SF Symbol status, name + reason, optional detail, optional action button.
private struct SetupRow: View {
    let tick: PermissionRow.Tick
    let title: String
    let why: String
    let detail: String?
    let buttonTitle: String?
    let action: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: tick.symbolName)
                .foregroundStyle(tick == .ok ? Color.green
                                 : tick.isFailure ? Color.red : Color.secondary)
                .font(.body)
                .frame(width: 18)
                .padding(.top, 1)

            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.body)
                Text(why).font(.callout).foregroundStyle(.secondary)
                if let detail {
                    Text(detail).font(.callout).foregroundStyle(.secondary)
                }
            }

            Spacer(minLength: 8)

            if let buttonTitle {
                Button(buttonTitle, action: action)
            }
        }
        .padding(.vertical, 2)
    }
}
```

- [ ] **Step 2: Build to check it compiles**

```bash
cd app && xcodegen generate && xcodebuild -project Carabiner.xcodeproj -scheme Carabiner \
  -configuration Debug -derivedDataPath build build 2>&1 | tail -4
```
Expected: `** BUILD SUCCEEDED **`. If the compiler rejects `.foregroundStyle` on macOS 13, replace both uses with `.foregroundColor` — it is the pre-13 spelling and still available.

- [ ] **Step 3: Commit**

```bash
git add app/Carabiner/Onboarding/OnboardingView.swift
git commit -m "feat(onboarding): SwiftUI grouped-form setup window body"
```

---

### Task 6: Host the SwiftUI view and delete the hand-built layout

**Files:**
- Modify: `app/Carabiner/Onboarding/OnboardingWindowController.swift` (replace lines 1-224 — the whole file)

**Interfaces:**
- Consumes: `OnboardingView`, `OnboardingViewModel` from Tasks 4-5.
- Produces: unchanged public surface — `init(checker:hotkeyIntercept:clearIntercept:)`, `show()`, `static let shownDefaultsKey`. `App.swift` needs no edits.

- [ ] **Step 1: Replace the whole file**

```swift
import AppKit
import SwiftUI

/// The setup & diagnostics window. Owns everything AppKit-shaped — the window, the
/// hotkey-test timer, and the intercept lifecycle — and hands rendering to SwiftUI.
/// All decisions still live in PermissionRow.presentation(for:) and HotkeyTestModel.
final class OnboardingWindowController: NSWindowController, NSWindowDelegate {
    private let hotkeyIntercept: (@escaping () -> Void) -> Void
    private let clearIntercept: () -> Void

    private var hotkeyModel = HotkeyTestModel()
    private var hotkeyTimer: Timer?
    private let model: OnboardingViewModel

    static let shownDefaultsKey = "onboardingShown"

    init(checker: PermissionChecking,
         hotkeyIntercept: @escaping (@escaping () -> Void) -> Void,
         clearIntercept: @escaping () -> Void) {
        self.hotkeyIntercept = hotkeyIntercept
        self.clearIntercept = clearIntercept
        self.model = OnboardingViewModel(checker: checker)

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 480),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Carabiner Setup"
        window.isReleasedWhenClosed = false
        super.init(window: window)

        window.delegate = self
        // The SwiftUI body is width-pinned and vertically self-sizing, so let the hosting
        // controller drive the window's height rather than the 480 above.
        window.contentViewController = NSHostingController(rootView: OnboardingView(model: model))
        model.onBeginHotkeyTest = { [weak self] in self?.beginHotkeyTest() }
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    func show() {
        UserDefaults.standard.set(true, forKey: Self.shownDefaultsKey)
        model.refreshAll()
        NSApp.activate(ignoringOtherApps: true)
        window?.center()
        window?.makeKeyAndOrderFront(nil)
    }

    // MARK: - hotkey test

    private func beginHotkeyTest() {
        hotkeyModel.beginTest()
        model.hotkey = hotkeyModel.presentation
        hotkeyIntercept { [weak self] in
            guard let self else { return }
            self.hotkeyTimer?.invalidate()
            self.hotkeyModel.hotkeyFired()
            self.model.hotkey = self.hotkeyModel.presentation
        }
        hotkeyTimer?.invalidate()
        hotkeyTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: false) { [weak self] _ in
            guard let self else { return }
            self.clearIntercept()
            self.hotkeyModel.timeout()
            self.model.hotkey = self.hotkeyModel.presentation
        }
    }

    // MARK: - NSWindowDelegate

    func windowDidBecomeKey(_ notification: Notification) { model.refreshAll() }

    func windowWillClose(_ notification: Notification) {
        hotkeyTimer?.invalidate()
        clearIntercept()
        hotkeyModel.cancel()
        model.hotkey = hotkeyModel.presentation
    }
}
```

- [ ] **Step 2: Build and run the full suite**

```bash
cd app && xcodegen generate && xcodebuild -project Carabiner.xcodeproj -scheme Carabiner \
  -destination 'platform=macOS' test 2>&1 | tail -12
```
Expected: `** TEST SUCCEEDED **`. `HotkeyTestModelTests` and `PermissionModelsTests` must still pass untouched — they test the layer this task did not change.

- [ ] **Step 3: Install and look at it**

```bash
cd app && xcodebuild -project Carabiner.xcodeproj -scheme Carabiner \
  -configuration Debug -derivedDataPath build build 2>&1 | tail -3
pkill -x Carabiner; rm -rf ~/Applications/Carabiner.app
cp -R build/Build/Products/Debug/Carabiner.app ~/Applications/ && open ~/Applications/Carabiner.app
```

Open the setup window from the status menu and check, by eye:
- grouped rounded panel, system accent on buttons, no OFF-PISTE blue
- SF Symbol status icons, not `✓ ✗ ○` text
- the window is tall enough for its content with no clipping and no dead space
- rows still show correct statuses, and the hotkey **Test** button still works end to end

- [ ] **Step 4: Check dark mode**

Switch System Settings → Appearance → Dark, reopen the window. Expected: panel, text and symbols all legible; nothing hard-coded light.

- [ ] **Step 5: Commit**

```bash
git add app/Carabiner/Onboarding/OnboardingWindowController.swift
git commit -m "feat(onboarding): host the SwiftUI form, delete the hand-built layout"
```

---

## After the plan

The window ships in the next DMG, not this one — `v0.1.0` is already published. When cutting the next release, `scripts/release.sh` needs its keychain re-check fix first (the notary profile is validated once at startup, so a keychain locking mid-run kills the run hours in and the exit trap discards the built app).

Record in `CLAUDE.md` once verified on a real build: that the setup window is SwiftUI hosted in an AppKit controller, and that the notifications row requires `alertSetting == .enabled` — so a future reader does not "simplify" it back to trusting `requestAuthorization`'s flag.

## Self-review

**Spec coverage.** Verdict function → Task 1. Both checker paths (`request` and `status`) → Task 2. SF Symbols → Task 3. SwiftUI `Form`/`.formStyle(.grouped)` host, header, footer, dropped accent, dropped monospace, self-sizing window → Tasks 4-6. `RowView` deleted → Task 6 (whole-file replacement). Kept: `shownDefaultsKey`, hotkey timer/intercept, `windowDidBecomeKey`, `windowWillClose`, all copy → Task 6. Test table (six rows) → Task 1 Step 1. Out-of-scope items appear in no task. Covered.

**Placeholders.** None — every code step carries literal text, and Task 5 Step 2 names the exact fallback (`.foregroundStyle` → `.foregroundColor`) rather than saying "fix if broken".

**Type consistency.** `notificationStatus(authorization:alert:)` defined Task 1, called Task 2. `Tick.symbolName` / `.isFailure` defined Task 3, consumed Task 5. `OnboardingViewModel` with `statuses`, `hotkey`, `refreshAll()`, `refresh(_:)`, `presentation(for:)`, `act(on:)`, `onBeginHotkeyTest` defined Task 4, consumed Tasks 5-6. `OnboardingView(model:)` defined Task 5, constructed Task 6. Controller's public surface unchanged, so `App.swift` is untouched — consistent with it appearing in no task's file list.
