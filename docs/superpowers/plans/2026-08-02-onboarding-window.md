# First-Run Setup & Permissions Window Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A branded first-run checklist window that triggers every macOS permission prompt with an explanation next to it, tests the hotkey, and doubles as the diagnostics page — per `docs/superpowers/specs/2026-08-02-onboarding-design.md`.

**Architecture:** Pure presentation models (`RowPresentation`, `HotkeyTestModel`) unit-tested like `BannerPlanner`; a `PermissionChecking` seam wrapping the OS calls (UNUserNotificationCenter, `AEDeterminePermissionToAutomateTarget`); a thin programmatic-AppKit window; wiring in `App.swift` and `MenuBarController`.

**Tech Stack:** Swift/AppKit, XcodeGen, XCTest. No new dependencies.

## Global Constraints

- Build ritual: `export CARABINER_TEAM_ID=$(security find-certificate -a -c "Apple Development" -p | openssl x509 -noout -subject | tr ',/' '\n\n' | sed -nE 's/.*OU=([A-Z0-9]{10}).*/\1/p' | head -1)`, then `cd app && xcodegen generate` **after adding any new file** (XcodeGen globs resolve at generation time), then `xcodebuild -project Carabiner.xcodeproj -scheme Carabiner -destination 'platform=macOS' test`.
- Every build signs (gotcha #11). Never launch the inner binary to test notifications.
- Commit style: imperative subject, body explains the why, trailer `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`.
- Copy is fixed by this plan (from the spec): use the strings verbatim; don't improvise.
- Brand: accent `#2D5BFF`, `NSFont.monospacedSystemFont` for the how-to, `AppIcon` image for the logo (NOT `StatusIcon` — that one is a template and renders flat).
- macOS 13 minimum (existing project setting) — all APIs used here exist on 13.

---

### Task 1: Pure permission models

**Files:**
- Create: `app/Carabiner/Onboarding/PermissionModels.swift`
- Modify: `app/Carabiner/TabReader.swift` (add `Browser.bundleId`)
- Test: `app/CarabinerTests/PermissionModelsTests.swift`

**Interfaces:**
- Consumes: `Browser` enum (exists in `TabReader.swift`).
- Produces (later tasks rely on these exact names):
  - `enum PermissionStatus: Equatable { case notDetermined, granted, denied, targetNotRunning }`
  - `enum PermissionRow: CaseIterable { case notifications, browserAccess, carouselDialog }` with `var title: String`, `var why: String`
  - `struct RowPresentation: Equatable` with `tick: Tick` (`enum Tick { case pending, ok, cross }`), `buttonTitle: String?`, `action: Action` (`enum Action: Equatable { case request, openSystemSettings, none }`), `detail: String?`
  - `func presentation(for status: PermissionStatus) -> RowPresentation` on `PermissionRow`
  - `Browser.bundleId: String`

- [ ] **Step 1: Write the failing tests**

```swift
// app/CarabinerTests/PermissionModelsTests.swift
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
```

- [ ] **Step 2: Regenerate and run to verify failure**

Run (from `app/`, with `CARABINER_TEAM_ID` exported as in Global Constraints):
`xcodegen generate && xcodebuild -project Carabiner.xcodeproj -scheme Carabiner -destination 'platform=macOS' test 2>&1 | grep -E 'error:|TEST '`
Expected: compile errors — `PermissionRow`/`PermissionStatus` not in scope, `Browser` has no `bundleId`.

- [ ] **Step 3: Implement the models**

```swift
// app/Carabiner/Onboarding/PermissionModels.swift
import Foundation

/// The four states a permission row can be in. `targetNotRunning` exists because the
/// Automation prompt (and even the passive check) needs the target app alive — a closed
/// Chrome is indistinguishable from "never asked", so it presents as pending, not broken.
enum PermissionStatus: Equatable {
    case notDetermined, granted, denied, targetNotRunning
}

/// The permission rows of the setup window. The hotkey test is NOT one of these — it has
/// its own state machine (HotkeyTestModel); nothing about it is a TCC permission.
enum PermissionRow: CaseIterable {
    case notifications, browserAccess, carouselDialog

    enum Tick { case pending, ok, cross }
    enum Action: Equatable { case request, openSystemSettings, none }

    var title: String {
        switch self {
        case .notifications:  return "Notifications"
        case .browserAccess:  return "Browser access"
        case .carouselDialog: return "Carousel dialog"
        }
    }

    var why: String {
        switch self {
        case .notifications:  return "So you see when a grab finishes — or why it didn't."
        case .browserAccess:  return "To read the address of the post you're looking at."
        case .carouselDialog: return "So Carabiner can ask 'this slide or the whole set?'."
        }
    }

    func presentation(for status: PermissionStatus) -> RowPresentation {
        switch status {
        case .granted:
            return RowPresentation(tick: .ok, buttonTitle: nil, action: .none, detail: nil)
        case .denied:
            return RowPresentation(tick: .cross, buttonTitle: "Open System Settings",
                                   action: .openSystemSettings, detail: nil)
        case .notDetermined:
            return RowPresentation(tick: .pending, buttonTitle: "Allow", action: .request, detail: nil)
        case .targetNotRunning:
            return RowPresentation(tick: .pending, buttonTitle: "Allow", action: .request,
                                   detail: "Chrome will open first")
        }
    }
}

struct RowPresentation: Equatable {
    let tick: PermissionRow.Tick
    let buttonTitle: String?
    let action: PermissionRow.Action
    let detail: String?
}
```

And in `app/Carabiner/TabReader.swift`, inside `enum Browser`, after `var appName`:

```swift
    /// TCC identifies Automation targets by bundle id, not name.
    var bundleId: String {
        switch self {
        case .chrome: return "com.google.Chrome"
        case .safari: return "com.apple.Safari"
        case .brave:  return "com.brave.Browser"
        case .edge:   return "com.microsoft.edgemac"
        case .arc:    return "company.thebrowser.Browser"
        }
    }
```

- [ ] **Step 4: Regenerate, run tests, verify pass**

Same command as Step 2. Expected: `** TEST SUCCEEDED **`, `PermissionModelsTests` listed as passed.

- [ ] **Step 5: Commit**

```bash
git add app/Carabiner/Onboarding/PermissionModels.swift app/Carabiner/TabReader.swift app/CarabinerTests/PermissionModelsTests.swift
git commit -m "feat(app): pure permission-row models for the setup window

Status → presentation is pure data so it is testable; the OS statuses
arrive later through the PermissionChecking seam.

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 2: Hotkey test state machine

**Files:**
- Create: `app/Carabiner/Onboarding/HotkeyTestModel.swift`
- Test: `app/CarabinerTests/HotkeyTestModelTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces:
  - `struct HotkeyTestModel` with `enum State: Equatable { case idle, listening, confirmed, timedOut }`, `private(set) var state: State`, mutating `beginTest()`, `hotkeyFired()`, `timeout()`, and `var presentation: HotkeyTestPresentation`
  - `struct HotkeyTestPresentation: Equatable { let tick: PermissionRow.Tick; let buttonTitle: String?; let detail: String? }`
  - `HotkeyTestModel.hint` (static let, the gotcha-#14 text — the window's timeout path shows it)

- [ ] **Step 1: Write the failing tests**

```swift
// app/CarabinerTests/HotkeyTestModelTests.swift
import XCTest
@testable import Carabiner

final class HotkeyTestModelTests: XCTestCase {

    func testIdleOffersTest() {
        let m = HotkeyTestModel()
        XCTAssertEqual(m.state, .idle)
        XCTAssertEqual(m.presentation, HotkeyTestPresentation(
            tick: .pending, buttonTitle: "Test", detail: "Press ⌃⌥⌘V when asked."))
    }

    func testListeningPrompts() {
        var m = HotkeyTestModel()
        m.beginTest()
        XCTAssertEqual(m.state, .listening)
        XCTAssertEqual(m.presentation, HotkeyTestPresentation(
            tick: .pending, buttonTitle: nil, detail: "Press ⌃⌥⌘V now…"))
    }

    func testFireConfirms() {
        var m = HotkeyTestModel()
        m.beginTest()
        m.hotkeyFired()
        XCTAssertEqual(m.state, .confirmed)
        XCTAssertEqual(m.presentation.tick, .ok)
        XCTAssertNil(m.presentation.buttonTitle)
    }

    /// A silently-lost chord looks exactly like a broken app (gotcha #14) — the timeout
    /// text is the one place that failure mode gets explained, so it is pinned verbatim.
    func testTimeoutShowsTheShortcutHint() {
        var m = HotkeyTestModel()
        m.beginTest()
        m.timeout()
        XCTAssertEqual(m.state, .timedOut)
        XCTAssertEqual(m.presentation.tick, .cross)
        XCTAssertEqual(m.presentation.buttonTitle, "Test again")
        XCTAssertEqual(m.presentation.detail, HotkeyTestModel.hint)
    }

    /// A fire after the window stopped listening (timeout, or never started) is a real
    /// grab, not a test result — the model must not swallow it into a state change.
    func testFireOutsideListeningIsIgnored() {
        var m = HotkeyTestModel()
        m.hotkeyFired()
        XCTAssertEqual(m.state, .idle)
        m.beginTest()
        m.timeout()
        m.hotkeyFired()
        XCTAssertEqual(m.state, .timedOut)
    }

    /// Timeout arriving after a successful fire (the Timer raced the keystroke) must not
    /// downgrade a confirmed hotkey to a failure.
    func testLateTimeoutDoesNotUnconfirm() {
        var m = HotkeyTestModel()
        m.beginTest()
        m.hotkeyFired()
        m.timeout()
        XCTAssertEqual(m.state, .confirmed)
    }
}
```

- [ ] **Step 2: Regenerate and run to verify failure**

`xcodegen generate && xcodebuild -project Carabiner.xcodeproj -scheme Carabiner -destination 'platform=macOS' test 2>&1 | grep -E 'error:|TEST '`
Expected: compile errors — `HotkeyTestModel` not in scope.

- [ ] **Step 3: Implement**

```swift
// app/Carabiner/Onboarding/HotkeyTestModel.swift
import Foundation

struct HotkeyTestPresentation: Equatable {
    let tick: PermissionRow.Tick
    let buttonTitle: String?
    let detail: String?
}

/// The hotkey row's state machine. Listening is the only honest check there is:
/// RegisterEventHotKey fails silently when another owner holds the chord (gotcha #14),
/// so the app can never *know* it lost the hotkey — it can only notice nothing arrived.
struct HotkeyTestModel {
    enum State: Equatable { case idle, listening, confirmed, timedOut }

    static let hint = "Nothing arrived. If you installed the Carabiner Shortcut before, "
        + "remove its keyboard shortcut in the Shortcuts app — a hotkey has exactly one owner."

    private(set) var state: State = .idle

    mutating func beginTest() { state = .listening }

    mutating func hotkeyFired() {
        guard state == .listening else { return }
        state = .confirmed
    }

    mutating func timeout() {
        guard state == .listening else { return }
        state = .timedOut
    }

    var presentation: HotkeyTestPresentation {
        switch state {
        case .idle:
            return HotkeyTestPresentation(tick: .pending, buttonTitle: "Test",
                                          detail: "Press ⌃⌥⌘V when asked.")
        case .listening:
            return HotkeyTestPresentation(tick: .pending, buttonTitle: nil,
                                          detail: "Press ⌃⌥⌘V now…")
        case .confirmed:
            return HotkeyTestPresentation(tick: .ok, buttonTitle: nil, detail: nil)
        case .timedOut:
            return HotkeyTestPresentation(tick: .cross, buttonTitle: "Test again",
                                          detail: Self.hint)
        }
    }
}
```

- [ ] **Step 4: Run tests, verify pass**

Same command. Expected: `** TEST SUCCEEDED **` with `HotkeyTestModelTests` passing.

- [ ] **Step 5: Commit**

```bash
git add app/Carabiner/Onboarding/HotkeyTestModel.swift app/CarabinerTests/HotkeyTestModelTests.swift
git commit -m "feat(app): hotkey-test state machine

Listening is the only honest check for a silently-lost chord (gotcha
#14); the timeout hint is the one place that failure mode is explained.

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 3: Live permission checker

**Files:**
- Create: `app/Carabiner/Onboarding/PermissionChecker.swift`

**Interfaces:**
- Consumes: `PermissionRow`, `PermissionStatus`, `Browser.bundleId` (Task 1).
- Produces:
  - `protocol PermissionChecking { func status(for: PermissionRow, completion: @escaping (PermissionStatus) -> Void); func request(_: PermissionRow, completion: @escaping (PermissionStatus) -> Void); func openSystemSettings(for: PermissionRow) }`
  - `final class LivePermissionChecker: PermissionChecking` with `init(browser: Browser)`
  - All completions are called on the **main queue** — the window binds them straight to UI.

No unit tests (spec: thin OS calls behind the seam); verified by build here and manually in Task 6.

- [ ] **Step 1: Implement**

```swift
// app/Carabiner/Onboarding/PermissionChecker.swift
import AppKit
import UserNotifications

/// The seam between the setup window and the OS. Everything behind it is a thin
/// wrapper over TCC/UNUserNotificationCenter — deliberately untested (the OS owns the
/// behaviour); everything in front of it is pure and tested.
protocol PermissionChecking {
    /// Passive: never shows a prompt. Completion on the main queue.
    func status(for row: PermissionRow, completion: @escaping (PermissionStatus) -> Void)
    /// Active: shows the OS prompt (launching the browser first when it must be
    /// running for the prompt to appear). Completion on the main queue.
    func request(_ row: PermissionRow, completion: @escaping (PermissionStatus) -> Void)
    func openSystemSettings(for row: PermissionRow)
}

final class LivePermissionChecker: PermissionChecking {
    private let browser: Browser
    private static let systemEventsId = "com.apple.systemevents"

    init(browser: Browser) { self.browser = browser }

    func status(for row: PermissionRow, completion: @escaping (PermissionStatus) -> Void) {
        switch row {
        case .notifications:
            UNUserNotificationCenter.current().getNotificationSettings { settings in
                let s: PermissionStatus
                switch settings.authorizationStatus {
                case .authorized, .provisional: s = .granted
                case .denied:                   s = .denied
                default:                        s = .notDetermined
                }
                DispatchQueue.main.async { completion(s) }
            }
        case .browserAccess:
            automation(bundleId: browser.bundleId, ask: false, completion: completion)
        case .carouselDialog:
            automation(bundleId: Self.systemEventsId, ask: false, completion: completion)
        }
    }

    func request(_ row: PermissionRow, completion: @escaping (PermissionStatus) -> Void) {
        switch row {
        case .notifications:
            UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, error in
                if let error { NSLog("Carabiner: notification authorization failed: %@", error.localizedDescription) }
                DispatchQueue.main.async { completion(granted ? .granted : .denied) }
            }
        case .browserAccess:
            // The Automation prompt only appears while the target is running.
            ensureRunning(bundleId: browser.bundleId) { [browser] running in
                guard running else { completion(.targetNotRunning); return }
                self.automation(bundleId: browser.bundleId, ask: true, completion: completion)
            }
        case .carouselDialog:
            // System Events is an always-available agent; no launch dance needed.
            automation(bundleId: Self.systemEventsId, ask: true, completion: completion)
        }
    }

    func openSystemSettings(for row: PermissionRow) {
        let url: String
        switch row {
        case .notifications:
            url = "x-apple.systempreferences:com.apple.preference.notifications"
        case .browserAccess, .carouselDialog:
            url = "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation"
        }
        if let u = URL(string: url) { NSWorkspace.shared.open(u) }
    }

    /// AEDeterminePermissionToAutomateTarget blocks (with ask=true, for as long as the
    /// prompt is up), so it always runs off the main thread.
    private func automation(bundleId: String, ask: Bool,
                            completion: @escaping (PermissionStatus) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let target = NSAppleEventDescriptor(bundleIdentifier: bundleId)
            let err = AEDeterminePermissionToAutomateTarget(target.aeDesc, typeWildCard, typeWildCard, ask)
            let s: PermissionStatus
            switch Int(err) {
            case Int(noErr):          s = .granted
            case -1744:               s = .notDetermined   // errAEEventWouldRequireUserConsent
            case Int(procNotFound):   s = .targetNotRunning // -600: target not running — TCC can't even report
            default:                  s = .denied           // -1743 errAEEventNotPermitted et al
            }
            DispatchQueue.main.async { completion(s) }
        }
    }

    private func ensureRunning(bundleId: String, then: @escaping (Bool) -> Void) {
        if !NSRunningApplication.runningApplications(withBundleIdentifier: bundleId).isEmpty {
            then(true); return
        }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) else {
            then(false); return
        }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration()) { app, _ in
            DispatchQueue.main.async { then(app != nil) }
        }
    }
}
```

- [ ] **Step 2: Regenerate, build, and confirm the whole suite still passes**

`xcodegen generate && xcodebuild -project Carabiner.xcodeproj -scheme Carabiner -destination 'platform=macOS' test 2>&1 | grep -E 'error:|TEST '`
Expected: `** TEST SUCCEEDED **` (no new tests; this task must not break existing ones).

- [ ] **Step 3: Commit**

```bash
git add app/Carabiner/Onboarding/PermissionChecker.swift
git commit -m "feat(app): live permission checker behind the PermissionChecking seam

Automation checks run off-main (AEDeterminePermissionToAutomateTarget
blocks while the prompt is up) and the browser is launched first when it
must be running for the prompt to exist.

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 4: The window

**Files:**
- Create: `app/Carabiner/Onboarding/OnboardingWindowController.swift`

**Interfaces:**
- Consumes: `PermissionRow.presentation(for:)`, `HotkeyTestModel`, `PermissionChecking`/`LivePermissionChecker` (Tasks 1-3).
- Produces:
  - `final class OnboardingWindowController: NSWindowController, NSWindowDelegate` with `init(checker: PermissionChecking, hotkeyIntercept: @escaping (@escaping () -> Void) -> Void, clearIntercept: @escaping () -> Void)` and `func show()`
  - Sets `UserDefaults` key `"onboardingShown"` on close. Task 5 reads that exact key.
  - `hotkeyIntercept` is called with a one-shot handler when the Test button is pressed; `clearIntercept` is called on timeout and on window close. Task 5 provides both from `MenuBarController`.

No unit tests (thin AppKit glue; all decisions live in the tested models). Verified visually in Task 6.

- [ ] **Step 1: Implement**

```swift
// app/Carabiner/Onboarding/OnboardingWindowController.swift
import AppKit

/// The setup & diagnostics window. Deliberately thin: all decisions come from
/// PermissionRow.presentation(for:) and HotkeyTestModel, which are tested; this file
/// only lays out rows and forwards button clicks.
final class OnboardingWindowController: NSWindowController, NSWindowDelegate {
    private let checker: PermissionChecking
    private let hotkeyIntercept: (@escaping () -> Void) -> Void
    private let clearIntercept: () -> Void

    private var hotkeyModel = HotkeyTestModel()
    private var hotkeyTimer: Timer?
    private var rowViews: [PermissionRow: RowView] = [:]
    private var hotkeyRowView: RowView!

    private static let accent = NSColor(srgbRed: 0x2D / 255.0, green: 0x5B / 255.0,
                                        blue: 0xFF / 255.0, alpha: 1)
    static let shownDefaultsKey = "onboardingShown"

    init(checker: PermissionChecking,
         hotkeyIntercept: @escaping (@escaping () -> Void) -> Void,
         clearIntercept: @escaping () -> Void) {
        self.checker = checker
        self.hotkeyIntercept = hotkeyIntercept
        self.clearIntercept = clearIntercept
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 480),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Carabiner Setup"
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        window.contentView = buildContent()
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    func show() {
        refreshAll()
        NSApp.activate(ignoringOtherApps: true)
        window?.center()
        window?.makeKeyAndOrderFront(nil)
    }

    // MARK: - layout

    private func buildContent() -> NSView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.edgeInsets = NSEdgeInsets(top: 24, left: 28, bottom: 20, right: 28)

        let logo = NSImageView(image: NSApp.applicationIconImage)
        logo.symbolConfiguration = nil
        logo.translatesAutoresizingMaskIntoConstraints = false
        logo.widthAnchor.constraint(equalToConstant: 56).isActive = true
        logo.heightAnchor.constraint(equalToConstant: 56).isActive = true

        let pitch = label("Clip a post. Keep the file.", font: .boldSystemFont(ofSize: 16))
        let howTo = label(
            "1  Open an Instagram post in Chrome\n2  Press ⌃⌥⌘V\n3  The file lands in ~/Downloads\n\nCarousels ask: this slide, or all of them.",
            font: .monospacedSystemFont(ofSize: 12, weight: .regular))

        stack.addArrangedSubview(logo)
        stack.addArrangedSubview(pitch)
        stack.addArrangedSubview(howTo)
        stack.addArrangedSubview(separator())

        for row in PermissionRow.allCases {
            let v = RowView(title: row.title, why: row.why) { [weak self] in self?.act(on: row) }
            rowViews[row] = v
            stack.addArrangedSubview(v)
        }
        hotkeyRowView = RowView(title: "Hotkey", why: "One keystroke, from anywhere.") { [weak self] in
            self?.beginHotkeyTest()
        }
        stack.addArrangedSubview(hotkeyRowView)

        stack.addArrangedSubview(separator())
        stack.addArrangedSubview(label(
            "Your first grab may ask for access to Chrome's \"Safe Storage\" — click Always Allow. That's macOS guarding Chrome's cookies, which Carabiner reads to act as you.",
            font: .systemFont(ofSize: 11), color: .secondaryLabelColor))
        return stack
    }

    private func label(_ text: String, font: NSFont, color: NSColor = .labelColor) -> NSTextField {
        let l = NSTextField(wrappingLabelWithString: text)
        l.font = font
        l.textColor = color
        l.isSelectable = false
        return l
    }

    private func separator() -> NSBox {
        let b = NSBox()
        b.boxType = .separator
        return b
    }

    // MARK: - permission rows

    private func refreshAll() {
        for row in PermissionRow.allCases { refresh(row) }
        hotkeyRowView.apply(hotkeyModel.presentation)
    }

    private func refresh(_ row: PermissionRow) {
        checker.status(for: row) { [weak self] status in
            self?.rowViews[row]?.apply(row.presentation(for: status))
        }
    }

    private func act(on row: PermissionRow) {
        checker.status(for: row) { [weak self] status in
            guard let self else { return }
            switch row.presentation(for: status).action {
            case .request:
                self.checker.request(row) { _ in self.refresh(row) }
            case .openSystemSettings:
                self.checker.openSystemSettings(for: row)
            case .none:
                self.refresh(row)
            }
        }
    }

    // MARK: - hotkey test

    private func beginHotkeyTest() {
        hotkeyModel.beginTest()
        hotkeyRowView.apply(hotkeyModel.presentation)
        hotkeyIntercept { [weak self] in
            guard let self else { return }
            self.hotkeyTimer?.invalidate()
            self.hotkeyModel.hotkeyFired()
            self.hotkeyRowView.apply(self.hotkeyModel.presentation)
        }
        hotkeyTimer?.invalidate()
        hotkeyTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: false) { [weak self] _ in
            guard let self else { return }
            self.clearIntercept()
            self.hotkeyModel.timeout()
            self.hotkeyRowView.apply(self.hotkeyModel.presentation)
        }
    }

    // MARK: - NSWindowDelegate

    func windowDidBecomeKey(_ notification: Notification) { refreshAll() }

    func windowWillClose(_ notification: Notification) {
        hotkeyTimer?.invalidate()
        clearIntercept()
        UserDefaults.standard.set(true, forKey: Self.shownDefaultsKey)
    }
}

/// One row: name + why on the left, detail/status + button on the right.
private final class RowView: NSView {
    private let statusLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(wrappingLabelWithString: "")
    private let button = NSButton(title: "", target: nil, action: nil)
    private let onButton: () -> Void

    init(title: String, why: String, onButton: @escaping () -> Void) {
        self.onButton = onButton
        super.init(frame: .zero)

        let name = NSTextField(labelWithString: title)
        name.font = .systemFont(ofSize: 13, weight: .semibold)
        let whyLabel = NSTextField(wrappingLabelWithString: why)
        whyLabel.font = .systemFont(ofSize: 11)
        whyLabel.textColor = .secondaryLabelColor
        detailLabel.font = .systemFont(ofSize: 11)
        detailLabel.textColor = .secondaryLabelColor
        statusLabel.font = .systemFont(ofSize: 13)

        button.target = self
        button.action = #selector(buttonTapped)
        button.bezelStyle = .rounded

        let left = NSStackView(views: [name, whyLabel, detailLabel])
        left.orientation = .vertical
        left.alignment = .leading
        left.spacing = 2
        let root = NSStackView(views: [left, NSView(), statusLabel, button])
        root.orientation = .horizontal
        root.alignment = .centerY
        root.translatesAutoresizingMaskIntoConstraints = false
        addSubview(root)
        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: leadingAnchor),
            root.trailingAnchor.constraint(equalTo: trailingAnchor),
            root.topAnchor.constraint(equalTo: topAnchor),
            root.bottomAnchor.constraint(equalTo: bottomAnchor),
            widthAnchor.constraint(greaterThanOrEqualToConstant: 404),
        ])
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    @objc private func buttonTapped() { onButton() }

    func apply(_ p: RowPresentation) {
        apply(tick: p.tick, buttonTitle: p.buttonTitle, detail: p.detail)
    }

    func apply(_ p: HotkeyTestPresentation) {
        apply(tick: p.tick, buttonTitle: p.buttonTitle, detail: p.detail)
    }

    private func apply(tick: PermissionRow.Tick, buttonTitle: String?, detail: String?) {
        switch tick {
        case .ok:      statusLabel.stringValue = "✓"; statusLabel.textColor = .systemGreen
        case .cross:   statusLabel.stringValue = "✗"; statusLabel.textColor = .systemRed
        case .pending: statusLabel.stringValue = "○"; statusLabel.textColor = .tertiaryLabelColor
        }
        button.title = buttonTitle ?? ""
        button.isHidden = buttonTitle == nil
        detailLabel.stringValue = detail ?? ""
        detailLabel.isHidden = detail == nil
    }
}
```

- [ ] **Step 2: Regenerate, build, confirm the suite still passes**

`xcodegen generate && xcodebuild -project Carabiner.xcodeproj -scheme Carabiner -destination 'platform=macOS' test 2>&1 | grep -E 'error:|TEST '`
Expected: `** TEST SUCCEEDED **`.

- [ ] **Step 3: Commit**

```bash
git add app/Carabiner/Onboarding/OnboardingWindowController.swift
git commit -m "feat(app): setup & permissions window

Thin AppKit over the tested models: rows render presentation(for:),
buttons forward to the checker, the hotkey test drives HotkeyTestModel
with a 10s timer.

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 5: Wiring — first launch, menu item, hotkey intercept

**Files:**
- Modify: `app/Carabiner/App.swift` (drop unconditional notification request; show window on first launch)
- Modify: `app/Carabiner/MenuBarController.swift` (menu item, window ownership, one-shot intercept)
- Modify: `app/Carabiner/Notifier.swift` (delete `requestAuthorization` — the checker owns requesting now)
- Test: `app/CarabinerTests/GrabRunnerTests.swift` (no change — this step just must not break it)

**Interfaces:**
- Consumes: `OnboardingWindowController` (Task 4), `LivePermissionChecker` (Task 3).
- Produces: `MenuBarController.showOnboarding()` and `MenuBarController.hotkeyTestHandler: (() -> Void)?` — `grab()` consumes the handler one-shot, before doing anything else.

- [ ] **Step 1: MenuBarController — intercept, menu item, window**

In `MenuBarController`, add properties after `ringStarted`:

```swift
    /// One-shot: set by the setup window's hotkey test. When present, the next hotkey
    /// fire is a test, not a grab — consumed before anything else in grab().
    var hotkeyTestHandler: (() -> Void)?
    private var onboarding: OnboardingWindowController?
```

At the very top of `grab()` (before the `busy` guard — a test press must work even while a grab runs):

```swift
        if let test = hotkeyTestHandler {
            hotkeyTestHandler = nil
            test()
            return
        }
```

In `init()`, insert a menu item between the grab item and the separator:

```swift
        let setupItem = NSMenuItem(title: "Setup & Permissions…", action: #selector(showOnboarding), keyEquivalent: "")
        setupItem.target = self
        menu.addItem(setupItem)
```

And add the method:

```swift
    @objc func showOnboarding() {
        if onboarding == nil {
            onboarding = OnboardingWindowController(
                checker: LivePermissionChecker(browser: Self.browser),
                hotkeyIntercept: { [weak self] handler in self?.hotkeyTestHandler = handler },
                clearIntercept: { [weak self] in self?.hotkeyTestHandler = nil })
        }
        onboarding?.show()
    }
```

- [ ] **Step 2: App.swift — first-launch show, drop the launch-time request**

Replace `applicationDidFinishLaunching` with:

```swift
    func applicationDidFinishLaunching(_ notification: Notification) {
        let controller = MenuBarController()
        menuBar = controller
        Hotkey.onGrab { [weak controller] in controller?.grab() }
        // No unconditional notification request any more: on a fresh install the setup
        // window is the only thing that triggers permission prompts, so every prompt
        // appears next to its explanation instead of naked at first launch.
        if !UserDefaults.standard.bool(forKey: OnboardingWindowController.shownDefaultsKey) {
            controller.showOnboarding()
        }
    }
```

- [ ] **Step 3: Notifier — delete `requestAuthorization`**

Remove the whole `requestAuthorization` method from `Notifier.swift` (its only caller was `App.swift`; `LivePermissionChecker.request(.notifications)` is the requester now, with the same logging).

- [ ] **Step 4: Regenerate, run the whole suite**

`xcodegen generate && xcodebuild -project Carabiner.xcodeproj -scheme Carabiner -destination 'platform=macOS' test 2>&1 | grep -E 'error:|TEST '`
Expected: `** TEST SUCCEEDED **` — nothing in the existing suites may break.

- [ ] **Step 5: Commit**

```bash
git add app/Carabiner/App.swift app/Carabiner/MenuBarController.swift app/Carabiner/Notifier.swift
git commit -m "feat(app): show setup window on first launch, add menu re-entry

The launch-time notification request moves into the window: on a fresh
install every permission prompt now appears next to its explanation.
The hotkey test intercepts one fire ahead of grab().

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 6: End-to-end verification & docs

**Files:**
- Modify: `CLAUDE.md` (app bullet + verification findings)

- [ ] **Step 1: Build the installable app and install it**

```bash
cd app && ./..//scripts/fetch-deps.sh
xcodebuild -project Carabiner.xcodeproj -scheme Carabiner -configuration Debug -derivedDataPath build build 2>&1 | grep -E 'error:|BUILD '
pkill -x Carabiner; rm -rf ~/Applications/Carabiner.app
cp -R build/Build/Products/Debug/Carabiner.app ~/Applications/ && open ~/Applications/Carabiner.app
```
Expected: `** BUILD SUCCEEDED **`; app running. (If the build fails on "detritus", retry — iCloud xattr race, gotcha #13.)

- [ ] **Step 2: Simulate a fresh user and walk every row**

```bash
defaults delete com.offpiste.carabiner onboardingShown
tccutil reset AppleEvents com.offpiste.carabiner
pkill -x Carabiner && open ~/Applications/Carabiner.app
```
Verify, in order — with **Chrome quit** at the start, deliberately:
1. Window appears on launch (fresh flag).
2. Browser access row shows ○ with "Chrome will open first"; its Allow launches Chrome, then the OS prompt appears; Allow → row turns ✓.
3. Carousel dialog row: Allow → System Events prompt → ✓. **Then run a real carousel grab and confirm the this-slide/all dialog appears without any further prompt** — this is the spec's flagged assumption (TCC attributes the script's osascript to the app); if a second prompt appears, the row must target whatever TCC actually recorded — stop and investigate before shipping.
4. Notifications row reflects current state; if granted from before, ✓ with no button.
5. Hotkey test: Test → press ⌃⌥⌘V → ✓, and no grab ran. Let it time out once (don't press) → ✗ + the Shortcut hint + "Test again".
6. Close the window; relaunch the app → window does not reappear; "Setup & Permissions…" menu item reopens it.
7. Run a normal grab end-to-end and confirm banners/ring still behave (nothing in this feature may regress the grab path).

- [ ] **Step 3: Update CLAUDE.md**

In the `app/` bullet of "Current state — BUILT", after the progress-ring sentence, add:

```markdown
  First launch opens a branded **Setup & Permissions** window (reopenable via the
  status menu): per-permission Allow rows with live status — notifications, browser
  Automation (launches the browser first; the OS can neither prompt nor report for a
  closed target), System Events for the carousel dialog — plus a hotkey test that
  catches the silently-lost-chord case (gotcha #14). On fresh installs it is the only
  thing that triggers permission prompts. See
  `docs/superpowers/specs/2026-08-02-onboarding-design.md`.
```

Record in the same commit anything Step 2 disproved (especially the TCC-attribution assumption) — corrections go in the spec's row section or a new gotcha if it cost real time.

- [ ] **Step 4: Commit**

```bash
git add CLAUDE.md docs/superpowers/specs/2026-08-02-onboarding-design.md
git commit -m "docs: record the setup window in CLAUDE.md after end-to-end verification

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

## Self-review notes

- Spec coverage: window trigger/flag (T5), menu re-entry (T5), all four rows (T1-T4), notifications request moved out of launch (T5), Chrome-not-running quirk (T3, verified T6), System Events attribution verification (T6 step 2.3), footnote + copy (T4), testing strategy (T1/T2 unit, T6 manual), out-of-scope untouched.
- Names cross-checked: `PermissionStatus`/`PermissionRow`/`RowPresentation`/`presentation(for:)` (T1) used verbatim in T3/T4; `HotkeyTestPresentation` (T2) in T4; `shownDefaultsKey` (T4) in T5; `hotkeyTestHandler`/`showOnboarding()` (T5) match T4's closures.
- The `RowView.widthAnchor >= 404` keeps rows from collapsing in the stack — cosmetic floor, adjust freely at implementation if layout looks off.
