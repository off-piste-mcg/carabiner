# Carabiner.app Phase 1 — Core Menu-Bar App — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A runnable macOS menu-bar app that, on a hotkey or menu click, reads the front browser tab's URL and grabs its media via the existing `carabiner` script, then shows a branded notification.

**Architecture:** Native Swift/AppKit menu-bar–only app (`LSUIElement`). Swift owns the UX (status item, global hotkey, browser-tab reading, notifications); it shells out to the repo's existing, proven `carabiner` script for the actual grab. Phase 1 uses the Homebrew-installed `carabiner`/deps on the dev machine — bundling binaries and signing come in later phases.

**Tech Stack:** Swift 5.9+/AppKit, XcodeGen (reproducible `.xcodeproj` from `project.yml`), the `KeyboardShortcuts` Swift package, `UserNotifications`. Build/test with Xcode 15+ on this machine.

## Global Constraints

- **Minimum macOS: 13.0 (Ventura).** Set `MACOSX_DEPLOYMENT_TARGET = 13.0`.
- **Menu-bar only:** `LSUIElement = true` (no Dock icon, no main window).
- **Reuse, don't reimplement:** the grab pipeline stays in the repo's `carabiner` script. The app never re-implements yt-dlp/gallery-dl/ffmpeg orchestration.
- **App lives in `app/`** subfolder of the existing repo (`github.com/off-piste-mcg/carabiner`).
- **Branding:** app + notification icon is the OFF-PISTE logo (`LOGO.jpg` at repo root), Apple rounded-rect.
- **Bundle identifier:** `com.offpiste.carabiner`.
- Phase 1 finds `carabiner` at `/opt/homebrew/bin/carabiner` (dev machine). Bundling is Phase 2 — do not hardcode this anywhere except `GrabRunner`'s single default.

---

### Task 1: Project scaffold — a menu-bar app that launches

**Files:**
- Create: `app/project.yml`
- Create: `app/Carabiner/App.swift`
- Create: `app/Carabiner/MenuBarController.swift`
- Create: `app/Carabiner/Info.plist`
- Create: `app/Carabiner/Assets.xcassets/AppIcon.appiconset/Contents.json` (+ PNGs, generated)
- Create: `app/.gitignore`
- Create: `app/README.md`

**Interfaces:**
- Produces: `MenuBarController` class with `init()` that installs an `NSStatusItem` and a menu; `AppDelegate` retains one `MenuBarController`.

- [ ] **Step 1: Install XcodeGen (build-time tool)**

Run: `brew install xcodegen`
Expected: `xcodegen --version` prints a version.

- [ ] **Step 2: Generate the AppIcon from the logo**

Reuse the rounded-rect approach already proven in this repo. Run from repo root:

```bash
mkdir -p app/Carabiner/Assets.xcassets/AppIcon.appiconset build
ffmpeg -y -loglevel error -i LOGO.jpg -vf \
"scale=1024:1024,format=rgba,geq=r='r(X,Y)':g='g(X,Y)':b='b(X,Y)':a='clip(255*(230-hypot(max(max(230-X,0),max(X-794,0)),max(max(230-Y,0),max(Y-794,0)))),0,255)'" \
-frames:v 1 build/appicon_1024.png
ICONSET=app/Carabiner/Assets.xcassets/AppIcon.appiconset
for s in 16 32 128 256 512; do
  sips -z $s $s   build/appicon_1024.png --out "$ICONSET/icon_${s}.png" >/dev/null
  sips -z $((s*2)) $((s*2)) build/appicon_1024.png --out "$ICONSET/icon_${s}@2x.png" >/dev/null
done
cp build/appicon_1024.png "$ICONSET/icon_512@2x.png"
```

- [ ] **Step 3: Write the appiconset manifest**

Create `app/Carabiner/Assets.xcassets/AppIcon.appiconset/Contents.json`:

```json
{
  "images": [
    {"idiom":"mac","scale":"1x","size":"16x16","filename":"icon_16.png"},
    {"idiom":"mac","scale":"2x","size":"16x16","filename":"icon_16@2x.png"},
    {"idiom":"mac","scale":"1x","size":"32x32","filename":"icon_32.png"},
    {"idiom":"mac","scale":"2x","size":"32x32","filename":"icon_32@2x.png"},
    {"idiom":"mac","scale":"1x","size":"128x128","filename":"icon_128.png"},
    {"idiom":"mac","scale":"2x","size":"128x128","filename":"icon_128@2x.png"},
    {"idiom":"mac","scale":"1x","size":"256x256","filename":"icon_256.png"},
    {"idiom":"mac","scale":"2x","size":"256x256","filename":"icon_256@2x.png"},
    {"idiom":"mac","scale":"1x","size":"512x512","filename":"icon_512.png"},
    {"idiom":"mac","scale":"2x","size":"512x512","filename":"icon_512@2x.png"}
  ],
  "info": {"author":"xcode","version":1}
}
```

- [ ] **Step 4: Write `app/project.yml`**

```yaml
name: Carabiner
options:
  bundleIdPrefix: com.offpiste
  deploymentTarget:
    macOS: "13.0"
packages:
  KeyboardShortcuts:
    url: https://github.com/sindresorhus/KeyboardShortcuts
    from: 2.0.0
targets:
  Carabiner:
    type: application
    platform: macOS
    sources: [Carabiner]
    dependencies:
      - package: KeyboardShortcuts
    info:
      path: Carabiner/Info.plist
      properties:
        LSUIElement: true
        CFBundleName: Carabiner
        CFBundleDisplayName: Carabiner
        NSHumanReadableCopyright: "OFF-PISTE"
    settings:
      base:
        PRODUCT_BUNDLE_IDENTIFIER: com.offpiste.carabiner
        MARKETING_VERSION: "0.1.0"
        CURRENT_PROJECT_VERSION: "1"
        GENERATE_INFOPLIST_FILE: NO
  CarabinerTests:
    type: bundle.unit-test
    platform: macOS
    sources: [CarabinerTests]
    dependencies:
      - target: Carabiner
```

- [ ] **Step 5: Write a minimal `Info.plist`**

Create `app/Carabiner/Info.plist`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key><string>$(EXECUTABLE_NAME)</string>
  <key>CFBundleIdentifier</key><string>$(PRODUCT_BUNDLE_IDENTIFIER)</string>
  <key>CFBundleName</key><string>Carabiner</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$(MARKETING_VERSION)</string>
  <key>CFBundleVersion</key><string>$(CURRENT_PROJECT_VERSION)</string>
  <key>LSMinimumSystemVersion</key><string>$(MACOSX_DEPLOYMENT_TARGET)</string>
  <key>LSUIElement</key><true/>
  <key>NSAppleEventsUsageDescription</key>
  <string>Carabiner reads your active browser tab's URL so it can grab the media you're viewing.</string>
</dict>
</plist>
```

- [ ] **Step 6: Write `App.swift`**

Create `app/Carabiner/App.swift`:

```swift
import AppKit

@main
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var menuBar: MenuBarController?

    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory) // menu-bar only
        app.run()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        menuBar = MenuBarController()
    }
}
```

- [ ] **Step 7: Write `MenuBarController.swift` (skeleton)**

Create `app/Carabiner/MenuBarController.swift`:

```swift
import AppKit

final class MenuBarController: NSObject {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

    override init() {
        super.init()
        if let button = statusItem.button {
            button.image = NSImage(named: "AppIcon")
            button.image?.size = NSSize(width: 18, height: 18)
            button.image?.isTemplate = false
        }
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Grab current tab", action: #selector(grab), keyEquivalent: ""))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit Carabiner", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        menu.items.forEach { $0.target = self }
        statusItem.menu = menu
    }

    @objc private func grab() {
        NSLog("Carabiner: grab clicked (wired up in Task 6)")
    }
}
```

- [ ] **Step 8: Write `app/.gitignore` and `app/README.md`**

`app/.gitignore`:
```
Carabiner.xcodeproj/
build/
.DS_Store
DerivedData/
*.xcuserstate
```

`app/README.md`:
```markdown
# Carabiner.app (native menu-bar app)

Native wrapper around the repo's `carabiner` script. See
`docs/superpowers/specs/2026-07-29-carabiner-mac-app-design.md`.

## Dev build
```bash
cd app
xcodegen generate
open Carabiner.xcodeproj   # or: xcodebuild -scheme Carabiner build
```
```
(The `.xcodeproj` is generated from `project.yml`, so it's gitignored.)

- [ ] **Step 9: Generate the project and build**

Run:
```bash
cd app && xcodegen generate && xcodebuild -project Carabiner.xcodeproj -scheme Carabiner -configuration Debug build CODE_SIGNING_ALLOWED=NO
```
Expected: `BUILD SUCCEEDED`.

- [ ] **Step 10: Launch and eyeball**

Run: find the built app under DerivedData (or set a fixed `-derivedDataPath build`), then `open build/Build/Products/Debug/Carabiner.app`.
Expected: the OFF-PISTE logo appears in the menu bar; clicking it shows "Grab current tab" and "Quit Carabiner"; no Dock icon.

- [ ] **Step 11: Commit**

```bash
git add app docs
git commit -m "feat(app): scaffold menu-bar app (XcodeGen, logo status item)"
```

---

### Task 2: TabReader — resolve the URL to grab

**Files:**
- Create: `app/Carabiner/TabReader.swift`
- Create: `app/CarabinerTests/TabReaderTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces:
  - `enum Browser: String { case chrome, safari, brave, edge, arc }`
  - `struct TabReader { var browser: Browser; func isURL(_ s: String) -> Bool; func resolveURL(argument: String?, tabURL: () -> String?, clipboard: () -> String?) -> String? }`
  - `func frontTabURL(for browser: Browser) -> String?` (AppleScript; not unit-tested)

- [ ] **Step 1: Write failing tests for the pure logic**

Create `app/CarabinerTests/TabReaderTests.swift`:

```swift
import XCTest
@testable import Carabiner

final class TabReaderTests: XCTestCase {
    let r = TabReader(browser: .chrome)

    func testIsURL() {
        XCTAssertTrue(r.isURL("https://www.instagram.com/reel/x/"))
        XCTAssertTrue(r.isURL("http://localhost:3000"))
        XCTAssertFalse(r.isURL("not a url"))
        XCTAssertFalse(r.isURL(""))
    }

    func testResolvePrefersArgument() {
        let out = r.resolveURL(argument: "https://a.com/x",
                               tabURL: { "https://tab.com/y" },
                               clipboard: { "https://clip.com/z" })
        XCTAssertEqual(out, "https://a.com/x")
    }

    func testResolveFallsBackToTabThenClipboard() {
        XCTAssertEqual(r.resolveURL(argument: nil, tabURL: { "https://tab.com/y" }, clipboard: { "https://clip.com/z" }), "https://tab.com/y")
        XCTAssertEqual(r.resolveURL(argument: nil, tabURL: { nil }, clipboard: { "https://clip.com/z" }), "https://clip.com/z")
        XCTAssertNil(r.resolveURL(argument: nil, tabURL: { "junk" }, clipboard: { nil }))
    }
}
```

- [ ] **Step 2: Run tests, verify they fail**

Run: `cd app && xcodegen generate && xcodebuild -project Carabiner.xcodeproj -scheme Carabiner -destination 'platform=macOS' test CODE_SIGNING_ALLOWED=NO`
Expected: FAIL — `TabReader` undefined.

- [ ] **Step 3: Implement `TabReader.swift`**

Create `app/Carabiner/TabReader.swift`:

```swift
import AppKit

enum Browser: String, CaseIterable {
    case chrome, safari, brave, edge, arc
    var appName: String {
        switch self {
        case .chrome: return "Google Chrome"
        case .safari: return "Safari"
        case .brave:  return "Brave Browser"
        case .edge:   return "Microsoft Edge"
        case .arc:    return "Arc"
        }
    }
}

struct TabReader {
    var browser: Browser

    func isURL(_ s: String) -> Bool {
        guard let r = s.range(of: "^https?://", options: [.regularExpression, .caseInsensitive]) else { return false }
        return r.lowerBound == s.startIndex
    }

    /// Argument wins; else the browser tab; else the clipboard. Injectable for tests.
    func resolveURL(argument: String?,
                    tabURL: () -> String?,
                    clipboard: () -> String?) -> String? {
        if let a = argument, isURL(a) { return a }
        if let t = tabURL(), isURL(t) { return t }
        if let c = clipboard(), isURL(c) { return c }
        return nil
    }

    /// Convenience wiring the real sources.
    func resolve(argument: String? = nil) -> String? {
        resolveURL(argument: argument,
                   tabURL: { frontTabURL(for: browser) },
                   clipboard: { NSPasteboard.general.string(forType: .string) })
    }
}

func frontTabURL(for browser: Browser) -> String? {
    let script: String
    if browser == .safari {
        script = "tell application \"\(browser.appName)\" to get URL of front document"
    } else {
        script = "tell application \"\(browser.appName)\" to get URL of active tab of front window"
    }
    var err: NSDictionary?
    let out = NSAppleScript(source: script)?.executeAndReturnError(&err)
    return out?.stringValue
}
```

- [ ] **Step 4: Run tests, verify they pass**

Run: `cd app && xcodebuild -project Carabiner.xcodeproj -scheme Carabiner -destination 'platform=macOS' test CODE_SIGNING_ALLOWED=NO`
Expected: PASS (3 tests).

- [ ] **Step 5: Commit**

```bash
git add app
git commit -m "feat(app): TabReader — resolve URL from arg/browser-tab/clipboard"
```

---

### Task 3: GrabRunner — shell out to the `carabiner` script

**Files:**
- Create: `app/Carabiner/GrabRunner.swift`
- Create: `app/CarabinerTests/GrabRunnerTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces:
  - `struct GrabResult { let ok: Bool; let message: String }`
  - `struct GrabRunner { var executable: String; func run(url: String) -> GrabResult }`
  - `run` executes `executable` with the URL as its single argument, non-TTY, with `CARABINER_NO_NOTIFY=1` set, and maps exit 0 → `ok:true`, else `ok:false` with the last non-empty stderr/stdout line as `message`.

- [ ] **Step 1: Write a failing test using a stub script**

Create `app/CarabinerTests/GrabRunnerTests.swift`:

```swift
import XCTest
@testable import Carabiner

final class GrabRunnerTests: XCTestCase {
    private func writeStub(_ body: String) -> String {
        let path = NSTemporaryDirectory() + "carabiner-stub-\(UUID().uuidString).sh"
        try! ("#!/bin/bash\n" + body).write(toFile: path, atomically: true, encoding: .utf8)
        try! FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
        return path
    }

    func testSuccessExitZero() {
        let stub = writeStub("echo '  ✓ ABC_fixed.mp4'; echo Done; exit 0")
        let result = GrabRunner(executable: stub).run(url: "https://x/y")
        XCTAssertTrue(result.ok)
    }

    func testFailureReportsLastLine() {
        let stub = writeStub("echo 'trying'; echo '✗ not logged in' 1>&2; exit 1")
        let result = GrabRunner(executable: stub).run(url: "https://x/y")
        XCTAssertFalse(result.ok)
        XCTAssertTrue(result.message.contains("not logged in"))
    }
}
```

- [ ] **Step 2: Run test, verify it fails**

Run: `cd app && xcodegen generate && xcodebuild -project Carabiner.xcodeproj -scheme Carabiner -destination 'platform=macOS' test CODE_SIGNING_ALLOWED=NO`
Expected: FAIL — `GrabRunner` undefined.

- [ ] **Step 3: Implement `GrabRunner.swift`**

Create `app/Carabiner/GrabRunner.swift`:

```swift
import Foundation

struct GrabResult {
    let ok: Bool
    let message: String
}

struct GrabRunner {
    /// Phase 1: the Homebrew-installed script. Phase 2 swaps this for the bundled copy.
    var executable: String = "/opt/homebrew/bin/carabiner"

    func run(url: String) -> GrabResult {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: executable)
        proc.arguments = [url]
        var env = ProcessInfo.processInfo.environment
        env["CARABINER_NO_NOTIFY"] = "1"          // the app owns notifications
        proc.environment = env

        let outPipe = Pipe(), errPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = errPipe

        do { try proc.run() } catch {
            return GrabResult(ok: false, message: "Couldn't launch carabiner: \(error.localizedDescription)")
        }
        let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()

        let combined = (String(data: outData, encoding: .utf8) ?? "")
                     + "\n" + (String(data: errData, encoding: .utf8) ?? "")
        let lastLine = combined.split(separator: "\n").map(String.init)
            .last(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) ?? ""

        if proc.terminationStatus == 0 {
            return GrabResult(ok: true, message: "Saved to Downloads")
        } else {
            return GrabResult(ok: false, message: lastLine.replacingOccurrences(of: "✗ ", with: ""))
        }
    }
}
```

- [ ] **Step 4: Run tests, verify they pass**

Run: `cd app && xcodebuild -project Carabiner.xcodeproj -scheme Carabiner -destination 'platform=macOS' test CODE_SIGNING_ALLOWED=NO`
Expected: PASS.

- [ ] **Step 5: Add the `CARABINER_NO_NOTIFY` gate to the script**

Modify the repo's `carabiner` script `notify()` function (top of the function body), so the app can own notifications. Change:

```bash
notify() {  # $1 = title line, $2 = body
  [ "$NOTIFY" -eq 1 ] || return 0
```
to:
```bash
notify() {  # $1 = title line, $2 = body
  [ -n "${CARABINER_NO_NOTIFY:-}" ] && return 0
  [ "$NOTIFY" -eq 1 ] || return 0
```

- [ ] **Step 6: Verify the script still runs standalone**

Run: `bash -n carabiner && CARABINER_NO_NOTIFY=1 ./carabiner -h >/dev/null && echo OK`
Expected: `OK`.

- [ ] **Step 7: Commit**

```bash
git add app carabiner
git commit -m "feat(app): GrabRunner shells out to carabiner; add CARABINER_NO_NOTIFY gate"
```

---

### Task 4: Notifier — branded success/failure banner

**Files:**
- Create: `app/Carabiner/Notifier.swift`

**Interfaces:**
- Consumes: `GrabResult`.
- Produces: `struct Notifier { func requestAuthorization(); func show(_ result: GrabResult) }` — posts a `UNUserNotificationCenter` notification titled "Carabiner", subtitle ✓/✗, body = `result.message`. Icon is the app icon (branded) automatically because the app posts it.

- [ ] **Step 1: Implement `Notifier.swift`**

Create `app/Carabiner/Notifier.swift`:

```swift
import UserNotifications

struct Notifier {
    func requestAuthorization() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    func show(_ result: GrabResult) {
        let content = UNMutableNotificationContent()
        content.title = "Carabiner"
        content.subtitle = result.ok ? "✓ Saved to Downloads" : "✗ Grab failed"
        content.body = result.message
        let req = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(req)
    }
}
```

- [ ] **Step 2: Build to verify it compiles**

Run: `cd app && xcodegen generate && xcodebuild -project Carabiner.xcodeproj -scheme Carabiner build CODE_SIGNING_ALLOWED=NO`
Expected: BUILD SUCCEEDED.

- [ ] **Step 3: Manual verification is deferred to Task 6**

The notification only makes sense once wired to a real grab; it's verified end-to-end in Task 6, Step 4. (No standalone test — `UNUserNotificationCenter` needs a running signed-ish app context.)

- [ ] **Step 4: Commit**

```bash
git add app
git commit -m "feat(app): branded Notifier via UserNotifications"
```

---

### Task 5: Global hotkey

**Files:**
- Create: `app/Carabiner/Hotkey.swift`

**Interfaces:**
- Consumes: `KeyboardShortcuts` package.
- Produces: `extension KeyboardShortcuts.Name { static let grab }` with default ⌃⌥⌘V; `enum Hotkey { static func onGrab(_ handler: @escaping () -> Void) }`.

- [ ] **Step 1: Implement `Hotkey.swift`**

Create `app/Carabiner/Hotkey.swift`:

```swift
import KeyboardShortcuts

extension KeyboardShortcuts.Name {
    static let grab = Self("grab", default: .init(.v, modifiers: [.control, .option, .command]))
}

enum Hotkey {
    static func onGrab(_ handler: @escaping () -> Void) {
        KeyboardShortcuts.onKeyUp(for: .grab) { handler() }
    }
}
```

- [ ] **Step 2: Build to verify the package resolves and it compiles**

Run: `cd app && xcodegen generate && xcodebuild -project Carabiner.xcodeproj -scheme Carabiner build CODE_SIGNING_ALLOWED=NO`
Expected: BUILD SUCCEEDED (KeyboardShortcuts fetched).

- [ ] **Step 3: Commit**

```bash
git add app
git commit -m "feat(app): global grab hotkey (⌃⌥⌘V) via KeyboardShortcuts"
```

---

### Task 6: Wire it together — end-to-end grab

**Files:**
- Modify: `app/Carabiner/MenuBarController.swift`
- Modify: `app/Carabiner/App.swift`

**Interfaces:**
- Consumes: `TabReader`, `GrabRunner`, `Notifier`, `Hotkey`.
- Produces: a working grab triggered by menu or hotkey.

- [ ] **Step 1: Flesh out `MenuBarController` to perform a grab**

Replace the body of `MenuBarController.swift` with:

```swift
import AppKit

final class MenuBarController: NSObject {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let notifier = Notifier()
    private let tabReader = TabReader(browser: .chrome)
    private let runner = GrabRunner()
    private var busy = false

    override init() {
        super.init()
        if let button = statusItem.button {
            button.image = NSImage(named: "AppIcon")
            button.image?.size = NSSize(width: 18, height: 18)
        }
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Grab current tab", action: #selector(grab), keyEquivalent: ""))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit Carabiner", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        menu.items.forEach { $0.target = self }
        statusItem.menu = menu
    }

    @objc func grab() {
        guard !busy else { return }
        guard let url = tabReader.resolve() else {
            notifier.show(GrabResult(ok: false, message: "No link in your browser tab or clipboard"))
            return
        }
        busy = true
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let result = self.runner.run(url: url)
            DispatchQueue.main.async {
                self.notifier.show(result)
                self.busy = false
            }
        }
    }
}
```

- [ ] **Step 2: Request notification auth + register the hotkey at launch**

In `App.swift`, replace `applicationDidFinishLaunching` with:

```swift
    func applicationDidFinishLaunching(_ notification: Notification) {
        let controller = MenuBarController()
        menuBar = controller
        Notifier().requestAuthorization()
        Hotkey.onGrab { [weak controller] in controller?.grab() }
    }
```

- [ ] **Step 3: Build and run**

Run:
```bash
cd app && xcodegen generate && \
xcodebuild -project Carabiner.xcodeproj -scheme Carabiner -configuration Debug -derivedDataPath build build CODE_SIGNING_ALLOWED=NO && \
open build/Build/Products/Debug/Carabiner.app
```
Expected: BUILD SUCCEEDED, app launches to the menu bar.

- [ ] **Step 4: Manual end-to-end verification**

1. First launch: click **Allow** on the "Carabiner would like to send notifications" prompt.
2. Open an Instagram reel in Chrome (logged in).
3. Press **⌃⌥⌘V** (or menu → Grab current tab). First run: **Allow** the "control Google Chrome" prompt; **Always Allow** any Keychain prompt.
4. Expected: within a few seconds a **Carabiner** notification "✓ Saved to Downloads" appears, and the `.mp4` is in `~/Downloads`.
5. Try again on a non-media tab (e.g. localhost) → notification "✗ Grab failed" with a reason.

- [ ] **Step 5: Commit**

```bash
git add app
git commit -m "feat(app): wire menu + hotkey → tab → grab → branded notification"
```

---

## Phase 1 Definition of Done

- `cd app && xcodegen generate && xcodebuild ... test` passes (TabReader + GrabRunner unit tests).
- The app launches to the menu bar (logo icon, no Dock icon).
- Hotkey/menu grabs the current browser tab's media to `~/Downloads`.
- A **branded** "Carabiner" notification reports success/failure.
- The reused `carabiner` script is unchanged except the one-line `CARABINER_NO_NOTIFY` gate.

**Out of scope (later phases):** bundling yt-dlp/ffmpeg/gallery-dl (Phase 2), native carousel popover (Phase 3), signing + notarization + DMG (Phase 4), Sparkle auto-update (Phase 5).
