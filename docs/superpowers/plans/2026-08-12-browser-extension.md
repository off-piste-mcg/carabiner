# Carabiner in-page download button — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Put an OFF-PISTE download button on Instagram posts in Chrome and Safari that hands the post URL to `Carabiner.app`, which grabs it with the existing engine.

**Architecture:** A browser extension injects a button and reads the post's shortcode from the DOM. It POSTs the resulting permalink to a loopback HTTP listener inside `Carabiner.app`, which routes it through the existing `MenuBarController` grab path (ring, banners, `GrabRunner`, bash engine — all unchanged) and streams `::progress:` events back as NDJSON so the button can draw its own ring. The extension never touches media.

**Tech Stack:** Swift/AppKit + Network.framework (`NWListener`) in the app; MV3 WebExtension (plain JS, no build tooling, no dependencies) for the extension; `node:test` for extension unit tests; XcodeGen for the Safari app-extension target.

**Spec:** `docs/superpowers/specs/2026-08-12-browser-extension-design.md`

## Global Constraints

- **Port is fixed at `51847`**, bound to `127.0.0.1` only — never `0.0.0.0`. On bind failure the app surfaces it in onboarding; it must NOT silently pick another port.
- **Only two accepted origin schemes:** `chrome-extension://` and `safari-web-extension://`. No exact-ID allowlist (Safari's origin is a random per-install UUID).
- **The POST must be sent from the extension's background service worker**, never a content script — a content-script fetch carries `https://www.instagram.com` and is correctly rejected.
- **Server-side URL allowlist:** Instagram (`/p/`, `/reel/`, `/reels/`, `/tv/`), YouTube, Pinterest only. Everything else → `400`.
- **One grab at a time.** A second `POST /grab` while busy → `409`.
- **The extension contains no download code.** No API scraping, no CDN URLs, no `chrome.downloads`.
- **The bash engine (`carabiner`) is not modified by this plan.** If a task seems to need an engine change, stop and escalate.
- **Scope:** feed, profile grid, permalink pages. NOT stories.
- **Every permission is granted from the Setup & Permissions window** with a live-status Allow row — never written instructions telling the user to go find System Settings.
- **Build outside iCloud:** always `-derivedDataPath /tmp/carabiner-dd` (gotcha #13).
- Team ID must be exported before `xcodegen generate` (gotcha #12):
  ```bash
  export CARABINER_TEAM_ID=$(security find-certificate -a -c "Apple Development" -p \
    | openssl x509 -noout -subject | tr ',/' '\n\n' \
    | sed -nE 's/.*OU=([A-Z0-9]{10}).*/\1/p' | head -1)
  ```

## File Structure

| Path | Responsibility |
|---|---|
| `extension/manifest.json` | Chrome MV3 manifest. Safari build derives from it. |
| `extension/src/shortcode.js` | Pure: DOM node → Instagram permalink. Unit-tested. |
| `extension/src/content.js` | Finds posts, injects the button host, renders ring state. |
| `extension/src/worker.js` | Background service worker: the only thing that talks to the app. |
| `extension/test/shortcode.test.js` | `node:test` unit tests over saved DOM fixtures. |
| `extension/test/fixtures/*.html` | Real captured Instagram markup. |
| `extension/build.sh` | Produces `dist/chrome/` and copies into the Safari appex resources. |
| `app/Carabiner/Server/GrabGate.swift` | **Pure** origin + URL validation. Unit-tested. |
| `app/Carabiner/Server/GrabEvent.swift` | **Pure** `ProgressEvent` → NDJSON line. Unit-tested. |
| `app/Carabiner/Server/GrabServer.swift` | `NWListener`, minimal HTTP, routes `/health` and `/grab`. |
| `app/Carabiner/Onboarding/PermissionModels.swift` | +`browserButton` row (and `fullDiskAccess` if Task 1 confirms). |
| `app/CarabinerSafariExtension/` | Safari Web Extension appex target. |
| `app/CarabinerTests/GrabGateTests.swift` | Both directions of every gate. |
| `app/CarabinerTests/GrabEventTests.swift` | Wire format. |

---

### Task 1: Determine whether Safari cookies need Full Disk Access

This gates whether the onboarding gains an extra row, so it runs before any code. It needs no extension and no build.

**Files:**
- Modify: `docs/superpowers/specs/2026-08-12-browser-extension-design.md` (record the finding)

- [ ] **Step 1: Confirm Safari is logged into Instagram**

Open Safari, visit `https://www.instagram.com/`, confirm you are logged in. Quit Safari (the cookie file is flushed on quit).

- [ ] **Step 2: Read the current Full Disk Access state for Carabiner**

Run: `sqlite3 "$HOME/Library/Application Support/com.apple.TCC/TCC.db" "select service,client,auth_value from access where service='kTCCServiceSystemPolicyAllFiles'" 2>&1 || echo "TCC.db unreadable (expected without FDA for Terminal) — rely on step 3"`

Expected: either a listing, or an authorization error. Either is fine — step 3 is the real test.

- [ ] **Step 3: Attempt a Safari-cookie grab through the installed app's own binaries**

```bash
APP=~/Applications/Carabiner.app
CARABINER_NO_NOTIFY=1 CARABINER_BIN="$APP/Contents/Resources/bin" \
  "$APP/Contents/Resources/carabiner" -b safari \
  'https://www.instagram.com/p/SHORTCODE/' 2>&1 | tail -20
```

Replace `SHORTCODE` with a real public post. Expected: **either** a saved file (Safari cookies readable → no FDA row needed) **or** an error mentioning permission / `Cookies.binarycookies` / "could not find safari cookies" (FDA needed).

- [ ] **Step 4: Record the verdict in the spec**

Edit the "Safari cookies may need Full Disk Access" risk in the spec. Replace the "Verify on a machine that has never granted it" sentence with the actual outcome, the date, and the exact command used. If FDA **is** needed, add this line: `**Confirmed needed — Task 9 must add a fullDiskAccess row.**`

Do not soften the result. If it failed, say it failed.

- [ ] **Step 5: Commit**

```bash
git add docs/superpowers/specs/2026-08-12-browser-extension-design.md
git commit -m "docs: record whether Safari cookies need Full Disk Access"
```

---

### Task 2: Prove the local channel — minimal extension in both browsers

The entire access-control design rests on browsers sending an `Origin` header we can trust. Verify it against both real browsers before building anything on top.

**Files:**
- Create: `extension/manifest.json`
- Create: `extension/src/worker.js`
- Create: `extension/README.md`

**Interfaces:**
- Produces: the manifest and service worker skeleton every later extension task builds on. `worker.js` exposes a message listener for `{type: "grab", url}` from content scripts.

- [ ] **Step 1: Write the manifest**

`extension/manifest.json`:

```json
{
  "manifest_version": 3,
  "name": "Carabiner",
  "version": "0.1.0",
  "description": "Download the Instagram post you're looking at, cleanly, with Carabiner.",
  "permissions": ["scripting"],
  "host_permissions": [
    "*://*.instagram.com/*",
    "http://127.0.0.1:51847/*"
  ],
  "background": { "service_worker": "src/worker.js", "type": "module" },
  "content_scripts": [
    {
      "matches": ["*://*.instagram.com/*"],
      "js": ["src/content.js"],
      "run_at": "document_idle"
    }
  ],
  "icons": { "128": "icons/icon128.png" }
}
```

- [ ] **Step 2: Write the minimal service worker**

`extension/src/worker.js`:

```js
const ENDPOINT = "http://127.0.0.1:51847";

// The ONLY place that talks to the app. A content script's fetch would carry
// instagram.com as its origin and the app would reject it — correctly.
chrome.runtime.onMessage.addListener((msg, _sender, sendResponse) => {
  if (msg?.type !== "grab") return false;
  fetch(`${ENDPOINT}/grab`, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ url: msg.url, browser: msg.browser }),
  })
    .then((r) => sendResponse({ status: r.status }))
    .catch((e) => sendResponse({ error: String(e) }));
  return true; // keep the message channel open for the async reply
});
```

- [ ] **Step 3: Create a stub content script so the manifest loads**

`extension/src/content.js`:

```js
// Replaced in Task 7. Present so the manifest is valid and the extension loads.
console.log("[carabiner] content script loaded");
```

- [ ] **Step 4: Start a header-dumping listener**

Run in one terminal: `while true; do printf 'HTTP/1.1 204 No Content\r\nAccess-Control-Allow-Origin: *\r\nAccess-Control-Allow-Headers: content-type\r\n\r\n' | nc -l 127.0.0.1 51847; echo "--- request end ---"; done`

- [ ] **Step 5: Load the extension in Chrome and fire one request**

Chrome → `chrome://extensions` → Developer mode on → "Load unpacked" → select `extension/`. Open `https://www.instagram.com/`, open the extension's service worker console (link on the extensions page), and run:

```js
chrome.runtime.sendMessage({type: "grab", url: "https://www.instagram.com/p/TEST/", browser: "chrome"}, console.log)
```

Expected in the `nc` terminal: a `POST /grab` with a header `Origin: chrome-extension://<32 chars>`.

- [ ] **Step 6: Repeat in Safari**

Convert and run the extension for Safari:

```bash
xcrun safari-web-extension-converter extension --macos-only --no-open --project-location /tmp/carabiner-safari-spike
```

Open the generated Xcode project, run it, enable the extension in Safari → Settings → Extensions, allow it on instagram.com, then repeat the `sendMessage` call from Safari's Web Inspector for the extension's background page.

Expected: `Origin: safari-web-extension://<UUID>`.

- [ ] **Step 7: Record the result — this is the gate**

If **both** send `Origin`, append to the spec's risk 1: `**Verified <date>: Chrome sends chrome-extension://<id>, Safari sends safari-web-extension://<uuid>.**`

If **Safari does not**, STOP and escalate. Do not proceed to Task 3 — the access-control design needs replacing with a pairing token surfaced in the onboarding window, which changes Tasks 3, 8 and 9.

- [ ] **Step 8: Write `extension/README.md`**

Document: how to load unpacked in Chrome, how to run the Safari converter, the fixed port, and the rule that only the service worker may call the app.

- [ ] **Step 9: Commit**

```bash
git add extension docs/superpowers/specs/2026-08-12-browser-extension-design.md
git commit -m "feat(extension): manifest and service worker skeleton, origin verified in both browsers"
```

---

### Task 3: The access gate, as a pure function

**Files:**
- Create: `app/Carabiner/Server/GrabGate.swift`
- Test: `app/CarabinerTests/GrabGateTests.swift`

**Interfaces:**
- Produces: `enum GrabGate { static func check(origin: String?, url: String?) -> GateVerdict }` and `enum GateVerdict: Equatable { case ok(url: String); case rejected(status: Int, reason: String) }`

- [ ] **Step 1: Write the failing tests — both directions of both gates**

Gotcha #25's lesson is the reason this task exists as its own unit: a gate tested only on what it should reject proves nothing about what it should accept.

`app/CarabinerTests/GrabGateTests.swift`:

```swift
import XCTest
@testable import Carabiner

final class GrabGateTests: XCTestCase {
    let post = "https://www.instagram.com/p/C1a2b3c4d5e/"

    // --- origin, both directions ---
    func testAcceptsChromeExtensionOrigin() {
        XCTAssertEqual(GrabGate.check(origin: "chrome-extension://abcdefghijklmnop", url: post),
                       .ok(url: post))
    }
    func testAcceptsSafariExtensionOrigin() {
        XCTAssertEqual(GrabGate.check(origin: "safari-web-extension://1E7A-UUID", url: post),
                       .ok(url: post))
    }
    func testRejectsWebPageOrigin() {
        guard case .rejected(let status, _) = GrabGate.check(origin: "https://www.instagram.com", url: post)
        else { return XCTFail("a web page origin must be rejected") }
        XCTAssertEqual(status, 403)
    }
    func testRejectsMissingOrigin() {
        guard case .rejected(let status, _) = GrabGate.check(origin: nil, url: post)
        else { return XCTFail("a missing origin must be rejected") }
        XCTAssertEqual(status, 403)
    }
    func testRejectsOriginThatMerelyContainsTheScheme() {
        // https://evil.example/chrome-extension:// must not pass a substring check.
        guard case .rejected = GrabGate.check(origin: "https://evil.example/chrome-extension://x", url: post)
        else { return XCTFail("scheme must be a prefix, not a substring") }
    }

    // --- url allowlist, both directions ---
    func testAcceptsReelAndTv() {
        XCTAssertEqual(GrabGate.check(origin: "chrome-extension://a", url: "https://www.instagram.com/reel/C9/"),
                       .ok(url: "https://www.instagram.com/reel/C9/"))
        XCTAssertEqual(GrabGate.check(origin: "chrome-extension://a", url: "https://www.instagram.com/tv/C9/"),
                       .ok(url: "https://www.instagram.com/tv/C9/"))
    }
    func testAcceptsYouTubeAndPinterest() {
        for u in ["https://www.youtube.com/watch?v=abc", "https://youtu.be/abc",
                  "https://www.pinterest.com/pin/12345/"] {
            XCTAssertEqual(GrabGate.check(origin: "chrome-extension://a", url: u), .ok(url: u))
        }
    }
    func testRejectsArbitraryHost() {
        guard case .rejected(let status, _) = GrabGate.check(origin: "chrome-extension://a",
                                                            url: "https://evil.example/payload.mp4")
        else { return XCTFail("an arbitrary host must be rejected") }
        XCTAssertEqual(status, 400)
    }
    func testRejectsLookalikeHost() {
        guard case .rejected = GrabGate.check(origin: "chrome-extension://a",
                                              url: "https://instagram.com.evil.example/p/C1/")
        else { return XCTFail("host must match on a domain boundary") }
    }
    func testRejectsNonHttpScheme() {
        guard case .rejected = GrabGate.check(origin: "chrome-extension://a", url: "file:///etc/passwd")
        else { return XCTFail("non-http(s) must be rejected") }
    }
    func testRejectsMissingUrl() {
        guard case .rejected(let status, _) = GrabGate.check(origin: "chrome-extension://a", url: nil)
        else { return XCTFail("a missing url must be rejected") }
        XCTAssertEqual(status, 400)
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

```bash
cd app && xcodegen generate && xcodebuild -project Carabiner.xcodeproj -scheme Carabiner \
  -destination 'platform=macOS' -derivedDataPath /tmp/carabiner-dd test
```

Expected: FAIL — `cannot find 'GrabGate' in scope`.

- [ ] **Step 3: Implement the gate**

`app/Carabiner/Server/GrabGate.swift`:

```swift
import Foundation

enum GateVerdict: Equatable {
    case ok(url: String)
    case rejected(status: Int, reason: String)
}

/// Pure. The listener does I/O; this decides. Kept separate for the same reason
/// `BannerPlanner` is: the I/O layer can't be unit-tested, so the decision must be.
enum GrabGate {
    /// A web page can never have one of these schemes, and the browser — not the page —
    /// sets the Origin header, so this cannot be forged from a page. Exact extension IDs
    /// are deliberately NOT allowlisted: Safari's origin is a random per-install UUID.
    static let allowedOriginSchemes = ["chrome-extension://", "safari-web-extension://"]

    /// Host must match exactly or on a dot boundary, so `instagram.com.evil.example`
    /// cannot pass by suffix.
    private static let allowedHosts = [
        "instagram.com", "youtube.com", "youtu.be", "pinterest.com",
    ]

    static func check(origin: String?, url: String?) -> GateVerdict {
        guard let origin, allowedOriginSchemes.contains(where: { origin.hasPrefix($0) }) else {
            return .rejected(status: 403, reason: "origin not an extension")
        }
        guard let url, let parsed = URL(string: url),
              let scheme = parsed.scheme?.lowercased(), scheme == "https" || scheme == "http",
              let host = parsed.host?.lowercased()
        else {
            return .rejected(status: 400, reason: "unusable url")
        }
        let hostAllowed = allowedHosts.contains { host == $0 || host.hasSuffix("." + $0) }
        guard hostAllowed else { return .rejected(status: 400, reason: "host not allowed") }
        return .ok(url: url)
    }
}
```

- [ ] **Step 4: Add the file to the target and run the tests**

`app/project.yml` already globs the `Carabiner` directory, so `Server/` is picked up automatically. Run:

```bash
cd app && xcodegen generate && xcodebuild -project Carabiner.xcodeproj -scheme Carabiner \
  -destination 'platform=macOS' -derivedDataPath /tmp/carabiner-dd test
```

Expected: PASS, all 11 tests.

- [ ] **Step 5: Commit**

```bash
git add app/Carabiner/Server/GrabGate.swift app/CarabinerTests/GrabGateTests.swift
git commit -m "feat(app): pure origin + URL gate for the extension channel"
```

---

### Task 4: The NDJSON wire format, as a pure function

**Files:**
- Create: `app/Carabiner/Server/GrabEvent.swift`
- Test: `app/CarabinerTests/GrabEventTests.swift`

**Interfaces:**
- Consumes: `ProgressEvent`, `GrabResult` (existing).
- Produces: `enum GrabEvent { static func line(for: ProgressEvent) -> String; static func line(forUser: String) -> String; static func line(for: GrabResult) -> String }` — each returns one newline-terminated JSON object.

- [ ] **Step 1: Write the failing tests**

`app/CarabinerTests/GrabEventTests.swift`:

```swift
import XCTest
@testable import Carabiner

final class GrabEventTests: XCTestCase {
    private func decode(_ line: String) -> [String: Any] {
        XCTAssertTrue(line.hasSuffix("\n"), "every event must be newline-terminated")
        return (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any] ?? [:]
    }

    func testDownloadCarriesPercent() {
        let o = decode(GrabEvent.line(for: .download(percent: 42.5)))
        XCTAssertEqual(o["stage"] as? String, "download")
        XCTAssertEqual(o["pct"] as? Double, 42.5)
    }
    func testDownloadWithoutPercentOmitsIt() {
        let o = decode(GrabEvent.line(for: .download(percent: nil)))
        XCTAssertEqual(o["stage"] as? String, "download")
        XCTAssertNil(o["pct"])
    }
    func testItemCarriesIndexAndTotal() {
        let o = decode(GrabEvent.line(for: .item(index: 2, total: 5)))
        XCTAssertEqual(o["stage"] as? String, "item")
        XCTAssertEqual(o["index"] as? Int, 2)
        XCTAssertEqual(o["total"] as? Int, 5)
    }
    func testPromptIsItsOwnStage() {
        XCTAssertEqual(decode(GrabEvent.line(for: .prompt))["stage"] as? String, "prompt")
    }
    func testUserLine() {
        XCTAssertEqual(decode(GrabEvent.line(forUser: "@offpiste"))["from"] as? String, "@offpiste")
    }
    func testSuccessResult() {
        let o = decode(GrabEvent.line(for: GrabResult(ok: true, message: "C1_fixed.mp4", user: "@a")))
        XCTAssertEqual(o["result"] as? String, "ok")
        XCTAssertEqual(o["message"] as? String, "C1_fixed.mp4")
    }
    func testCancelledIsItsOwnResultNotAFailure() {
        // The button must show nothing special for a deliberate cancel — same rule as
        // the banner (gotcha #22).
        let o = decode(GrabEvent.line(for: GrabResult(ok: false, message: "Nothing saved", cancelled: true)))
        XCTAssertEqual(o["result"] as? String, "cancelled")
    }
    func testFailureResult() {
        let o = decode(GrabEvent.line(for: GrabResult(ok: false, message: "cookies expired")))
        XCTAssertEqual(o["result"] as? String, "error")
        XCTAssertEqual(o["message"] as? String, "cookies expired")
    }
    func testMessageWithQuotesIsEscaped() {
        let line = GrabEvent.line(for: GrabResult(ok: false, message: "he said \"no\"\nand left"))
        XCTAssertEqual(line.filter { $0 == "\n" }.count, 1, "a message newline must not split the event")
        XCTAssertEqual(decode(line)["message"] as? String, "he said \"no\"\nand left")
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run the `xcodebuild … test` command from Task 3 Step 2. Expected: FAIL — `cannot find 'GrabEvent' in scope`.

- [ ] **Step 3: Implement**

`app/Carabiner/Server/GrabEvent.swift`:

```swift
import Foundation

/// One JSON object per line (NDJSON). Newline-delimited rather than SSE because the
/// client only needs "a sequence of objects" and `\n` framing is trivially correct on
/// both sides. JSONSerialization does the escaping — hand-built JSON would break the
/// framing the first time a filename contained a quote or an error message a newline.
enum GrabEvent {
    static func line(for event: ProgressEvent) -> String {
        switch event {
        case .probe:  return encode(["stage": "probe"])
        case .prompt: return encode(["stage": "prompt"])
        case .save:   return encode(["stage": "save"])
        case .download(let pct):
            var o: [String: Any] = ["stage": "download"]
            if let pct { o["pct"] = pct }
            return encode(o)
        case .item(let index, let total):
            return encode(["stage": "item", "index": index, "total": total])
        case .convert(let mode):
            return encode(["stage": "convert", "mode": mode.rawValue])
        }
    }

    static func line(forUser user: String) -> String { encode(["from": user]) }

    static func line(for result: GrabResult) -> String {
        let state = result.cancelled ? "cancelled" : (result.ok ? "ok" : "error")
        return encode(["result": state, "message": result.message])
    }

    private static func encode(_ object: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: object),
              let json = String(data: data, encoding: .utf8)
        else { return "{\"result\":\"error\",\"message\":\"encode failed\"}\n" }
        return json + "\n"
    }
}
```

- [ ] **Step 4: Run to verify the tests pass**

Run the `xcodebuild … test` command. Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add app/Carabiner/Server/GrabEvent.swift app/CarabinerTests/GrabEventTests.swift
git commit -m "feat(app): NDJSON wire format for streamed grab progress"
```

---

### Task 5: Extract a grab entry point that takes an explicit URL

`MenuBarController.grab()` currently resolves the front tab and grabs in one method. The server needs the second half without the first, and both callers must share `busy`, the ring and the notifier — two independent grab paths would double-post banners and race the ring.

**Files:**
- Modify: `app/Carabiner/MenuBarController.swift:67-133`

**Interfaces:**
- Produces:
  ```swift
  var isBusy: Bool { get }
  func grab(url: String,
            browser: Browser,
            observer: ((ProgressEvent) -> Void)? = nil,
            userObserver: ((String) -> Void)? = nil,
            completion: ((GrabResult) -> Void)? = nil)
  ```
  Must be called on the main queue. `observer`/`completion` are invoked on the main queue.

- [ ] **Step 1: Add `isBusy` and split `grab()`**

In `MenuBarController.swift`, add above `grab()`:

```swift
    /// The server refuses a second concurrent grab rather than queueing it — see
    /// GrabServer's 409 path.
    var isBusy: Bool { busy }
```

Then change `@objc func grab()` so everything from `NSLog("Carabiner: grabbing %@", url)` onward is replaced by a call to the new method, and add the new method after it:

```swift
    @objc func grab() {
        guard !busy else {
            NSLog("Carabiner: grab ignored — a grab is already running")
            return
        }
        ringStarted = false
        notifier.grabStarted()
        let url: String
        switch tabReader.resolve() {
        case .url(let u):
            url = u
        case .notAuthorized:
            NSLog("Carabiner: grab aborted — not authorised to control %@", Self.browser.appName)
            notifier.finished(GrabResult(ok: false, message: "Allow Carabiner to control \(Self.browser.appName) under System Settings → Privacy & Security → Automation, then try again"))
            ring.finish(success: false)
            return
        case .nothing:
            NSLog("Carabiner: grab aborted — no URL in the front tab or the clipboard")
            notifier.finished(GrabResult(ok: false, message: "No link in your browser tab or clipboard"))
            ring.finish(success: false)
            return
        }
        grab(url: url, browser: Self.browser)
    }

    /// The shared grab path. The hotkey reaches it after resolving the front tab; the
    /// browser button reaches it with a URL the page already knew. Both share `busy`,
    /// the ring and the notifier — two independent paths would double-post banners.
    ///
    /// `grabStarted()` is NOT posted here: the hotkey posts it before the AppleScript
    /// tab read, which is itself part of the wait. The button's caller posts it instead.
    func grab(url: String,
              browser: Browser,
              observer: ((ProgressEvent) -> Void)? = nil,
              userObserver: ((String) -> Void)? = nil,
              completion: ((GrabResult) -> Void)? = nil) {
        NSLog("Carabiner: grabbing %@ (cookies: %@)", url, browser.rawValue)
        busy = true
        var runner = self.runner
        runner.browser = browser
        runner.onProgress = { [weak self] event in
            DispatchQueue.main.async {
                guard let self else { return }
                if !self.ringStarted, event.beginsActivity {
                    self.ringStarted = true
                    self.ring.begin()
                }
                if self.ringStarted { self.ring.handle(event) }
                self.notifier.handle(event)
                observer?(event)
            }
        }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let result = runner.run(url: url)
            DispatchQueue.main.async {
                NSLog("Carabiner: grab %@ — %@",
                      result.ok ? "succeeded" : (result.cancelled ? "cancelled" : "failed"),
                      result.message)
                if let user = result.user { userObserver?(user) }
                self.ring.finish(success: result.ok)
                self.notifier.finished(result)
                self.busy = false
                completion?(result)
            }
        }
    }
```

Note `runner` is copied into a local `var` because `GrabRunner` is a struct and each grab now sets its own `browser`.

- [ ] **Step 2: Verify the hotkey path still works**

```bash
cd app && xcodegen generate && xcodebuild -project Carabiner.xcodeproj -scheme Carabiner \
  -configuration Debug -derivedDataPath /tmp/carabiner-dd build
pkill -x Carabiner; rm -rf ~/Applications/Carabiner.app
cp -R /tmp/carabiner-dd/Build/Products/Debug/Carabiner.app ~/Applications/ && open ~/Applications/Carabiner.app
```

Open an Instagram post in Chrome, press ⌃⌥⌘V. Expected: working banner → ring → file in `~/Downloads` → outcome banner. Confirm with the filename-diff method (never timestamps):

```bash
ls -1 ~/Downloads > /tmp/before.txt   # before the grab
ls -1 ~/Downloads | diff /tmp/before.txt - | grep '^>'
```

- [ ] **Step 3: Run the unit tests**

Run the `xcodebuild … test` command. Expected: PASS, no regressions.

- [ ] **Step 4: Commit**

```bash
git add app/Carabiner/MenuBarController.swift
git commit -m "refactor(app): share one grab path between the hotkey and an explicit URL"
```

---

### Task 6: The listener — `/health` only

Ship the socket before the grab route so a failure here is unambiguous.

**Files:**
- Create: `app/Carabiner/Server/GrabServer.swift`
- Modify: `app/Carabiner/App.swift` (start it)

**Interfaces:**
- Consumes: `GrabGate.check`, `MenuBarController.isBusy` / `.grab(url:browser:…)`.
- Produces:
  ```swift
  final class GrabServer {
      enum State: Equatable { case stopped, listening, failed(String) }
      var state: State { get }
      var lastSeen: [String: Date] { get }   // keyed by browser name reported by the extension
      init(port: UInt16 = 51847, controller: MenuBarController)
      func start()
  }
  ```

- [ ] **Step 1: Implement the listener with `/health`**

`app/Carabiner/Server/GrabServer.swift`:

```swift
import Foundation
import Network

/// A loopback-only HTTP/1.1 listener for the browser extension. Hand-rolled rather than
/// pulling in a server package: it serves exactly two routes and the whole surface is
/// small enough to audit, which matters for something holding an open port.
///
/// Bound to 127.0.0.1 ONLY. Never 0.0.0.0 — that would expose it to the network.
final class GrabServer {
    enum State: Equatable { case stopped, listening, failed(String) }

    private let port: UInt16
    private weak var controller: MenuBarController?
    private var listener: NWListener?
    private let queue = DispatchQueue(label: "com.offpiste.carabiner.server")

    private(set) var state: State = .stopped
    /// Which browsers have proven they can reach us, and when. This is what turns an
    /// onboarding row green — a real connection, never a guess.
    private(set) var lastSeen: [String: Date] = [:]

    init(port: UInt16 = 51847, controller: MenuBarController) {
        self.port = port
        self.controller = controller
    }

    func start() {
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: NWEndpoint.Port(rawValue: port)!)
        params.allowLocalEndpointReuse = true
        do {
            let l = try NWListener(using: params)
            l.stateUpdateHandler = { [weak self] s in
                guard let self else { return }
                switch s {
                case .ready:
                    self.state = .listening
                    NSLog("Carabiner: extension server listening on 127.0.0.1:%d", Int(self.port))
                case .failed(let e):
                    // Deliberately NOT retrying on another port: the extension has no way
                    // to discover a moved port, so a silent move presents as a button that
                    // does nothing. Surfacing it in onboarding is the honest failure.
                    self.state = .failed(e.localizedDescription)
                    NSLog("Carabiner: extension server failed — %@", e.localizedDescription)
                default: break
                }
            }
            l.newConnectionHandler = { [weak self] c in self?.accept(c) }
            l.start(queue: queue)
            listener = l
        } catch {
            state = .failed(error.localizedDescription)
            NSLog("Carabiner: extension server could not start — %@", error.localizedDescription)
        }
    }

    private func accept(_ connection: NWConnection) {
        connection.start(queue: queue)
        receiveRequest(connection, buffer: Data())
    }

    /// Reads until headers are complete and the declared body has arrived. Requests here
    /// are a few hundred bytes; anything over 64 KB is refused rather than buffered.
    private func receiveRequest(_ c: NWConnection, buffer: Data) {
        c.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            var buf = buffer
            if let data { buf.append(data) }
            if error != nil || (isComplete && buf.isEmpty) { c.cancel(); return }
            guard buf.count <= 64 * 1024 else {
                self.respond(c, status: 413, body: "too large"); return
            }
            guard let request = HTTPRequest(buf) else {
                if isComplete { c.cancel() } else { self.receiveRequest(c, buffer: buf) }
                return
            }
            self.route(request, on: c)
        }
    }

    private func route(_ request: HTTPRequest, on c: NWConnection) {
        if request.method == "OPTIONS" { return preflight(request, on: c) }
        switch request.path {
        case "/health": health(request, on: c)
        default: respond(c, status: 404, body: "no such route")
        }
    }

    private func health(_ request: HTTPRequest, on c: NWConnection) {
        // The health check is gated too: an arbitrary page must not be able to fingerprint
        // that Carabiner is installed. A dummy URL keeps the one gate function in charge.
        guard case .ok = GrabGate.check(origin: request.origin,
                                        url: "https://www.instagram.com/p/health/") else {
            return respond(c, status: 403, body: "forbidden")
        }
        if let browser = request.query["browser"], !browser.isEmpty {
            DispatchQueue.main.async { self.lastSeen[browser] = Date() }
        }
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        respond(c, status: 200, origin: request.origin,
                contentType: "application/json",
                body: "{\"app\":\"carabiner\",\"version\":\"\(version)\"}")
    }

    private func preflight(_ request: HTTPRequest, on c: NWConnection) {
        guard let origin = request.origin,
              GrabGate.allowedOriginSchemes.contains(where: { origin.hasPrefix($0) })
        else { return respond(c, status: 403, body: "forbidden") }
        respond(c, status: 204, origin: origin, body: "")
    }

    fileprivate func respond(_ c: NWConnection, status: Int, origin: String? = nil,
                             contentType: String = "text/plain", body: String) {
        var head = "HTTP/1.1 \(status) \(Self.reason(status))\r\n"
        head += "Content-Type: \(contentType)\r\n"
        head += "Content-Length: \(body.utf8.count)\r\n"
        // Echo only an origin the gate already accepted — never `*`, which would let any
        // page read the response.
        if let origin { head += "Access-Control-Allow-Origin: \(origin)\r\n" }
        head += "Access-Control-Allow-Headers: content-type\r\nConnection: close\r\n\r\n"
        c.send(content: Data((head + body).utf8), completion: .contentProcessed { _ in c.cancel() })
    }

    private static func reason(_ status: Int) -> String {
        switch status {
        case 200: return "OK"
        case 204: return "No Content"
        case 400: return "Bad Request"
        case 403: return "Forbidden"
        case 404: return "Not Found"
        case 409: return "Conflict"
        case 413: return "Payload Too Large"
        default:  return "Error"
        }
    }
}

/// Minimal HTTP/1.1 request. Returns nil while the request is still incomplete, so the
/// caller keeps reading.
struct HTTPRequest {
    let method: String
    let path: String
    let query: [String: String]
    let headers: [String: String]
    let body: String

    init?(_ data: Data) {
        guard let text = String(data: data, encoding: .utf8),
              let headEnd = text.range(of: "\r\n\r\n") else { return nil }
        let head = String(text[text.startIndex..<headEnd.lowerBound])
        var lines = head.components(separatedBy: "\r\n")
        guard !lines.isEmpty else { return nil }
        let requestLine = lines.removeFirst().components(separatedBy: " ")
        guard requestLine.count >= 2 else { return nil }
        method = requestLine[0]
        let target = requestLine[1]
        let parts = target.components(separatedBy: "?")
        path = parts[0]
        var q: [String: String] = [:]
        if parts.count > 1 {
            for pair in parts[1].components(separatedBy: "&") {
                let kv = pair.components(separatedBy: "=")
                if kv.count == 2 { q[kv[0]] = kv[1].removingPercentEncoding ?? kv[1] }
            }
        }
        query = q
        var h: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            h[String(line[line.startIndex..<colon]).lowercased()] =
                String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
        }
        headers = h
        let bodyText = String(text[headEnd.upperBound...])
        // Wait for the whole declared body before routing.
        if let declared = Int(h["content-length"] ?? "0"), bodyText.utf8.count < declared { return nil }
        body = bodyText
    }

    var origin: String? { headers["origin"] }
}
```

- [ ] **Step 2: Start the server from `App.swift`**

In `App.swift`, after the `MenuBarController` is created, add a stored property and start it:

```swift
    private var grabServer: GrabServer?
```

and in `applicationDidFinishLaunching`, after the controller exists:

```swift
        let server = GrabServer(controller: controller)
        server.start()
        grabServer = server
        controller.grabServer = server
```

Add `weak var grabServer: GrabServer?` to `MenuBarController` (used by onboarding in Task 9). Use the actual local variable name `App.swift` already uses for the controller.

- [ ] **Step 3: Build, install, and prove `/health` both directions**

```bash
cd app && xcodegen generate && xcodebuild -project Carabiner.xcodeproj -scheme Carabiner \
  -configuration Debug -derivedDataPath /tmp/carabiner-dd build
pkill -x Carabiner; rm -rf ~/Applications/Carabiner.app
cp -R /tmp/carabiner-dd/Build/Products/Debug/Carabiner.app ~/Applications/ && open ~/Applications/Carabiner.app
```

Then:

```bash
# Accepted — an extension origin
curl -s -o /dev/null -w '%{http_code}\n' -H 'Origin: chrome-extension://abc' \
  'http://127.0.0.1:51847/health?browser=chrome'          # expect 200
# Rejected — a web page origin
curl -s -o /dev/null -w '%{http_code}\n' -H 'Origin: https://www.instagram.com' \
  http://127.0.0.1:51847/health                            # expect 403
# Rejected — no origin at all
curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:51847/health   # expect 403
# Not reachable from off-machine
curl -s -m 3 -o /dev/null -w '%{http_code}\n' \
  "http://$(ipconfig getifaddr en0):51847/health" || echo "refused (correct)"
```

All four must behave as annotated. If the loopback-only check *succeeds* in connecting, the bind is wrong — stop and fix before continuing.

- [ ] **Step 4: Commit**

```bash
git add app/Carabiner/Server/GrabServer.swift app/Carabiner/App.swift app/Carabiner/MenuBarController.swift
git commit -m "feat(app): loopback listener for the browser extension, /health only"
```

---

### Task 7: The `/grab` route with streamed progress

**Files:**
- Modify: `app/Carabiner/Server/GrabServer.swift`

**Interfaces:**
- Consumes: `GrabEvent.line(for:)`, `MenuBarController.grab(url:browser:observer:userObserver:completion:)`, `MenuBarController.isBusy`.

- [ ] **Step 1: Add the route**

In `GrabServer.route(_:on:)`, add before `default`:

```swift
        case "/grab": grab(request, on: c)
```

And add the method:

```swift
    private func grab(_ request: HTTPRequest, on c: NWConnection) {
        guard request.method == "POST" else { return respond(c, status: 404, body: "POST only") }
        let payload = (try? JSONSerialization.jsonObject(with: Data(request.body.utf8))) as? [String: Any]
        switch GrabGate.check(origin: request.origin, url: payload?["url"] as? String) {
        case .rejected(let status, let reason):
            NSLog("Carabiner: /grab rejected (%d) — %@", status, reason)
            respond(c, status: status, origin: request.origin, body: reason)
        case .ok(let url):
            let browser = Browser(rawValue: (payload?["browser"] as? String) ?? "") ?? .chrome
            if let name = payload?["browser"] as? String {
                DispatchQueue.main.async { self.lastSeen[name] = Date() }
            }
            DispatchQueue.main.async { [weak self] in
                guard let self, let controller = self.controller else {
                    self?.respond(c, status: 500, origin: request.origin, body: "no controller"); return
                }
                guard !controller.isBusy else {
                    // Refused, not queued: a queue would let a stray double-click stack
                    // grabs the user can no longer see or cancel.
                    self.respond(c, status: 409, origin: request.origin, body: "a grab is already running")
                    return
                }
                self.stream(url: url, browser: browser, controller: controller,
                            origin: request.origin, on: c)
            }
        }
    }

    /// Sends headers immediately, then one NDJSON line per event, then the terminal
    /// result. The connection stays open for the whole grab — that open connection IS
    /// the progress channel.
    private func stream(url: String, browser: Browser, controller: MenuBarController,
                        origin: String?, on c: NWConnection) {
        var head = "HTTP/1.1 200 OK\r\nContent-Type: application/x-ndjson\r\n"
        if let origin { head += "Access-Control-Allow-Origin: \(origin)\r\n" }
        head += "Cache-Control: no-store\r\nConnection: close\r\n\r\n"
        c.send(content: Data(head.utf8), completion: .contentProcessed { _ in })

        let write: (String) -> Void = { line in
            c.send(content: Data(line.utf8), completion: .contentProcessed { _ in })
        }
        // The app still posts its own banner: it is what reports the filename and the
        // @user. The in-page ring is additional feedback, not a replacement.
        controller.notifyGrabStarted()
        controller.grab(
            url: url,
            browser: browser,
            observer: { event in write(GrabEvent.line(for: event)) },
            userObserver: { user in write(GrabEvent.line(forUser: user)) },
            completion: { result in
                write(GrabEvent.line(for: result))
                c.cancel()
            })
    }
```

- [ ] **Step 2: Expose the working banner to the server**

`notifier` is private on `MenuBarController`. Add:

```swift
    /// The hotkey posts this itself before the tab read; the browser button has no tab
    /// read, so its caller posts it at the moment the request arrives.
    func notifyGrabStarted() { notifier.grabStarted() }
```

- [ ] **Step 3: Build, install, and grab for real over the socket**

Build and install with the Task 6 Step 3 commands, then:

```bash
ls -1 ~/Downloads > /tmp/before.txt
curl -N -s -H 'Origin: chrome-extension://abc' -H 'content-type: application/json' \
  -d '{"url":"https://www.instagram.com/p/SHORTCODE/","browser":"chrome"}' \
  http://127.0.0.1:51847/grab
ls -1 ~/Downloads | diff /tmp/before.txt - | grep '^>'
```

Expected: NDJSON lines arriving **progressively** (not all at once at the end), ending with `{"result":"ok",...}`, and a new file in `~/Downloads`. Use a single-image post so it completes fast.

- [ ] **Step 4: Prove the 409**

Start a grab of a large reel in one terminal, and while it runs fire the same `curl` in another. Expected: the second returns `409`.

- [ ] **Step 5: Prove a hostile page is refused**

```bash
curl -s -o /dev/null -w '%{http_code}\n' -H 'Origin: https://evil.example' -H 'content-type: application/json' \
  -d '{"url":"https://www.instagram.com/p/SHORTCODE/"}' http://127.0.0.1:51847/grab   # expect 403
curl -s -o /dev/null -w '%{http_code}\n' -H 'Origin: chrome-extension://abc' -H 'content-type: application/json' \
  -d '{"url":"https://evil.example/x.mp4"}' http://127.0.0.1:51847/grab                # expect 400
```

- [ ] **Step 6: Commit**

```bash
git add app/Carabiner/Server/GrabServer.swift app/Carabiner/MenuBarController.swift
git commit -m "feat(app): /grab route streaming NDJSON progress to the extension"
```

---

### Task 8: Shortcode extraction, unit-tested against real markup

**Files:**
- Create: `extension/src/shortcode.js`
- Create: `extension/test/shortcode.test.js`
- Create: `extension/test/fixtures/feed-post.html`, `extension/test/fixtures/grid-thumb.html`, `extension/test/fixtures/permalink.html`

**Interfaces:**
- Produces: `export function permalinkFor(element)` → `"https://www.instagram.com/p/<code>/"` or `null`. Takes any element inside a post; walks up to the post container and finds the permalink anchor.

- [ ] **Step 1: Capture real fixtures**

In Chrome on instagram.com, for each of a feed post, a profile-grid thumbnail, and an open permalink page, right-click the post → Inspect → on the enclosing `article` (feed) or `a` (grid) → Copy → Copy outerHTML. Save each into the fixture path above, wrapped so the file is a complete document:

```html
<!doctype html><html><body>
<!-- paste the copied outerHTML here -->
</body></html>
```

Trim any base64 image data to keep the files readable.

- [ ] **Step 2: Write the failing tests**

`extension/test/shortcode.test.js`:

```js
import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { JSDOM } from "jsdom";
import { permalinkFor } from "../src/shortcode.js";

const load = (name) =>
  new JSDOM(readFileSync(new URL(`./fixtures/${name}`, import.meta.url), "utf8")).window.document;

test("finds the permalink from inside a feed post", () => {
  const doc = load("feed-post.html");
  const img = doc.querySelector("img");
  assert.match(permalinkFor(img), /^https:\/\/www\.instagram\.com\/(p|reel)\/[\w-]+\/$/);
});

test("finds the permalink from a grid thumbnail", () => {
  const doc = load("grid-thumb.html");
  assert.match(permalinkFor(doc.querySelector("a")), /^https:\/\/www\.instagram\.com\/(p|reel)\/[\w-]+\/$/);
});

test("finds the permalink on an open post page", () => {
  const doc = load("permalink.html");
  assert.match(permalinkFor(doc.querySelector("article") ?? doc.body),
               /^https:\/\/www\.instagram\.com\/(p|reel)\/[\w-]+\/$/);
});

test("returns null rather than throwing when there is no post", () => {
  const doc = new JSDOM("<!doctype html><body><div id=x>nothing here</div></body>").window.document;
  assert.equal(permalinkFor(doc.getElementById("x")), null);
});

test("ignores query strings and trailing junk", () => {
  const doc = new JSDOM(
    `<!doctype html><body><article><a href="/p/C1a2b3c4/?img_index=3"><img></a></article></body>`
  ).window.document;
  assert.equal(permalinkFor(doc.querySelector("img")), "https://www.instagram.com/p/C1a2b3c4/");
});

test("does not mistake a profile link for a post link", () => {
  const doc = new JSDOM(
    `<!doctype html><body><article><a href="/offpiste.mcg/"><img></a></article></body>`
  ).window.document;
  assert.equal(permalinkFor(doc.querySelector("img")), null);
});
```

- [ ] **Step 3: Add jsdom and run to verify failure**

```bash
cd extension && npm init -y >/dev/null && npm pkg set type=module && npm i -D jsdom
node --test test/
```

Expected: FAIL — cannot find `../src/shortcode.js`.

`jsdom` is a **dev-only** dependency for tests. The shipped extension has zero dependencies — do not import it from `src/`.

- [ ] **Step 4: Implement**

`extension/src/shortcode.js`:

```js
// Instagram's markup changes without warning, so this is deliberately forgiving: walk up
// looking for a post container, then find the first anchor that looks like a permalink.
// It must NEVER throw — a null return simply means "no button here".
const POST_HREF = /^\/(p|reel|reels|tv)\/([\w-]+)/;

export function permalinkFor(element) {
  if (!element) return null;
  let node = element;
  for (let depth = 0; node && depth < 12; depth++) {
    const link = findPostLink(node);
    if (link) return link;
    node = node.parentElement;
  }
  return null;
}

function findPostLink(node) {
  if (typeof node.querySelectorAll !== "function") return null;
  const candidates = [];
  if (node.tagName === "A") candidates.push(node);
  candidates.push(...node.querySelectorAll("a[href]"));
  for (const a of candidates) {
    // getAttribute, not .href: jsdom and about:blank resolve relative URLs differently,
    // and the raw attribute is what Instagram actually writes.
    const href = a.getAttribute("href") || "";
    const match = POST_HREF.exec(href);
    if (match) return `https://www.instagram.com/${match[1] === "reels" ? "reel" : match[1]}/${match[2]}/`;
  }
  return null;
}
```

- [ ] **Step 5: Run to verify the tests pass**

```bash
cd extension && node --test test/
```

Expected: PASS, 6 tests.

- [ ] **Step 6: Commit**

```bash
git add extension
git commit -m "feat(extension): permalink extraction with fixture-based tests"
```

---

### Task 9: The button — injection, shadow DOM, ring

**Files:**
- Modify: `extension/src/content.js`
- Modify: `extension/src/worker.js`

**Interfaces:**
- Consumes: `permalinkFor` (Task 8); the worker's `{type:"grab", url, browser}` message (Task 2).
- Produces: worker messages `{type:"progress", …}` / `{type:"done", …}` broadcast back to the originating tab.

- [ ] **Step 1: Rewrite the content script**

`extension/src/content.js`:

```js
import { permalinkFor } from "./shortcode.js";

const MARK = "data-carabiner";
const SIZE = 28;

// Shadow DOM so Instagram's CSS cannot reach our button and ours cannot leak into the
// page. Without it, one Instagram style change silently reshapes the button.
function makeButton(url) {
  const host = document.createElement("div");
  host.style.cssText = "position:absolute;top:8px;right:8px;z-index:9999;";
  const root = host.attachShadow({ mode: "closed" });
  root.innerHTML = `
    <style>
      button { width:${SIZE}px; height:${SIZE}px; border:0; border-radius:50%;
               background:rgba(0,0,0,.65); cursor:pointer; display:grid;
               place-items:center; padding:0; backdrop-filter:blur(4px); }
      button:hover { background:rgba(45,91,255,.9); }
      svg { width:16px; height:16px; }
      .track { stroke:rgba(255,255,255,.25); }
      .fill  { stroke:#fff; stroke-linecap:round;
               transform:rotate(-90deg); transform-origin:center;
               transition:stroke-dasharray .2s linear; }
      .hidden { display:none; }
    </style>
    <button title="Save with Carabiner">
      <svg viewBox="0 0 24 24" fill="none" class="glyph">
        <path d="M12 3v12m0 0 4-4m-4 4-4-4M4 19h16" stroke="#fff" stroke-width="2" stroke-linecap="round"/>
      </svg>
      <svg viewBox="0 0 24 24" fill="none" class="ring hidden">
        <circle class="track" cx="12" cy="12" r="9" stroke-width="2.5"/>
        <circle class="fill"  cx="12" cy="12" r="9" stroke-width="2.5" stroke-dasharray="0 57"/>
      </svg>
    </button>`;
  const button = root.querySelector("button");
  const glyph = root.querySelector(".glyph");
  const ring = root.querySelector(".ring");
  const fill = root.querySelector(".fill");

  const setRing = (fraction) => {
    glyph.classList.add("hidden");
    ring.classList.remove("hidden");
    fill.setAttribute("stroke-dasharray", `${(57 * fraction).toFixed(1)} 57`);
  };
  const settle = (symbol, colour) => {
    ring.classList.add("hidden");
    glyph.classList.remove("hidden");
    glyph.innerHTML = symbol;
    button.style.background = colour;
  };

  button.addEventListener("click", (e) => {
    e.preventDefault();
    e.stopPropagation();          // do not let the click open the post
    setRing(0.02);                // immediate acknowledgement, before anything downloads
    chrome.runtime.sendMessage({ type: "grab", url, browser: detectBrowser() }, (reply) => {
      if (reply?.error) settle(CROSS, "rgba(200,40,40,.9)");
    });
  });

  host.__carabiner = { setRing, settle, url };
  return host;
}

const TICK = `<path d="M5 13l4 4L19 7" stroke="#fff" stroke-width="2.5" stroke-linecap="round" fill="none"/>`;
const CROSS = `<path d="M6 6l12 12M18 6L6 18" stroke="#fff" stroke-width="2.5" stroke-linecap="round"/>`;

function detectBrowser() {
  return navigator.userAgent.includes("Safari") && !navigator.userAgent.includes("Chrome")
    ? "safari" : "chrome";
}

// Progress is broadcast to the tab, and the most recently clicked button owns it. Only
// one grab runs at a time (the app returns 409 otherwise), so a single owner is correct.
let active = null;

chrome.runtime.onMessage.addListener((msg) => {
  if (!active) return;
  if (msg.type === "progress") {
    // The ring means "downloading" — the same rule the menu-bar ring follows. Stages
    // before real work (probe, prompt) must not advance it.
    if (msg.stage === "download" && typeof msg.pct === "number") active.__carabiner.setRing(msg.pct / 100);
    else if (msg.stage === "item") active.__carabiner.setRing(msg.index / Math.max(msg.total, 1));
    else if (msg.stage === "convert" || msg.stage === "save") active.__carabiner.setRing(1);
  } else if (msg.type === "done") {
    if (msg.result === "ok") active.__carabiner.settle(TICK, "rgba(40,160,80,.9)");
    else if (msg.result === "cancelled") active.__carabiner.settle("", "rgba(0,0,0,.65)");
    else active.__carabiner.settle(CROSS, "rgba(200,40,40,.9)");
    active = null;
  }
});

function attach(container) {
  if (container.hasAttribute(MARK)) return;
  const url = permalinkFor(container);
  if (!url) return;                       // no shortcode, no button. Never throw.
  container.setAttribute(MARK, "1");
  if (getComputedStyle(container).position === "static") container.style.position = "relative";
  const host = makeButton(url);
  host.addEventListener("click", () => { active = host; }, true);
  container.appendChild(host);
}

function scan() {
  for (const el of document.querySelectorAll("article, a[href^='/p/'], a[href^='/reel/']")) {
    try { attach(el); } catch (_) { /* one bad node must not kill the observer */ }
  }
}

new MutationObserver(scan).observe(document.body, { childList: true, subtree: true });
scan();
```

- [ ] **Step 2: Make the manifest load the content script as a module**

ES module imports do not work in a classic content script. Change the manifest's `content_scripts` entry to inject a loader, and add the real script to web-accessible resources:

```json
  "content_scripts": [
    { "matches": ["*://*.instagram.com/*"], "js": ["src/loader.js"], "run_at": "document_idle" }
  ],
  "web_accessible_resources": [
    { "resources": ["src/content.js", "src/shortcode.js"], "matches": ["*://*.instagram.com/*"] }
  ]
```

`extension/src/loader.js`:

```js
// Content scripts can't use `import` directly, so load the real module into the page's
// isolated world via a script tag pointing at a web-accessible resource.
const s = document.createElement("script");
s.type = "module";
s.src = chrome.runtime.getURL("src/content.js");
document.documentElement.appendChild(s);
```

- [ ] **Step 3: Stream progress from the worker back to the tab**

Replace `extension/src/worker.js`'s fetch handler so it reads the NDJSON stream and relays each line:

```js
const ENDPOINT = "http://127.0.0.1:51847";

chrome.runtime.onMessage.addListener((msg, sender, sendResponse) => {
  if (msg?.type !== "grab") return false;
  const tabId = sender.tab?.id;
  run(msg, tabId).catch((e) => {
    if (tabId) chrome.tabs.sendMessage(tabId, { type: "done", result: "error", message: String(e) });
  });
  sendResponse({ accepted: true });
  return true;
});

async function run(msg, tabId) {
  let response;
  try {
    response = await post(msg);
  } catch (_) {
    // The app isn't running. Launch it via the URL scheme, then retry once.
    await launchApp();
    await new Promise((r) => setTimeout(r, 2500));
    response = await post(msg);
  }
  if (response.status === 409) {
    return relay(tabId, { type: "done", result: "error", message: "A grab is already running" });
  }
  if (!response.ok) {
    return relay(tabId, { type: "done", result: "error", message: `Carabiner said ${response.status}` });
  }
  const reader = response.body.getReader();
  const decoder = new TextDecoder();
  let buffer = "";
  for (;;) {
    const { value, done } = await reader.read();
    if (done) break;
    buffer += decoder.decode(value, { stream: true });
    const lines = buffer.split("\n");
    buffer = lines.pop();                        // keep the partial line
    for (const line of lines) {
      if (!line.trim()) continue;
      const event = JSON.parse(line);
      if (event.result) relay(tabId, { type: "done", ...event });
      else relay(tabId, { type: "progress", ...event });
    }
  }
}

function post(msg) {
  return fetch(`${ENDPOINT}/grab`, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ url: msg.url, browser: msg.browser }),
  });
}

async function launchApp() {
  // No return channel and a one-time browser prompt — acceptable purely as a launcher.
  const tab = await chrome.tabs.create({ url: "carabiner://launch", active: false });
  setTimeout(() => chrome.tabs.remove(tab.id).catch(() => {}), 1500);
}

function relay(tabId, message) {
  if (tabId) chrome.tabs.sendMessage(tabId, message).catch(() => {});
}

// Announce ourselves so the onboarding row can turn green on a real connection.
chrome.runtime.onInstalled.addListener(ping);
chrome.runtime.onStartup.addListener(ping);
function ping() {
  const browser = navigator.userAgent.includes("Safari") && !navigator.userAgent.includes("Chrome")
    ? "safari" : "chrome";
  fetch(`${ENDPOINT}/health?browser=${browser}`).catch(() => {});
}
```

Add `"tabs"` to the manifest's `permissions` array (needed for `chrome.tabs.sendMessage` and `chrome.tabs.create`).

- [ ] **Step 4: Register the `carabiner://` URL scheme in the app**

In `app/project.yml`, under the Carabiner target's `info.properties`, add:

```yaml
        CFBundleURLTypes:
          - CFBundleURLName: com.offpiste.carabiner
            CFBundleURLSchemes: [carabiner]
```

In `App.swift`, add to the `NSApplicationDelegate`:

```swift
    /// The extension opens `carabiner://launch` purely to start the app when it isn't
    /// running; the real request then arrives over HTTP. There is nothing to do here —
    /// being launched IS the effect.
    func application(_ application: NSApplication, open urls: [URL]) {
        NSLog("Carabiner: launched via URL scheme (%@)", urls.first?.absoluteString ?? "?")
    }
```

- [ ] **Step 5: Test it in Chrome, end to end**

Rebuild and reinstall the app (Task 6 Step 3 commands). Reload the unpacked extension. Then:

1. Open `https://www.instagram.com/` logged in, scroll to a post.
2. Confirm a button appears in the top-right of the post's media.
3. `ls -1 ~/Downloads > /tmp/before.txt`, click it.
4. Expected: ring advances → tick → the app's outcome banner names the file → `ls -1 ~/Downloads | diff /tmp/before.txt - | grep '^>'` shows it.
5. Quit Carabiner, click the button again. Expected: the app launches and the grab completes.

- [ ] **Step 6: Commit**

```bash
git add extension app/project.yml app/Carabiner/App.swift
git commit -m "feat(extension): in-page button with live progress ring"
```

---

### Task 10: Ship the Safari extension inside the app

**Files:**
- Create: `app/CarabinerSafariExtension/Info.plist`
- Create: `app/CarabinerSafariExtension/SafariWebExtensionHandler.swift`
- Create: `extension/build.sh`
- Modify: `app/project.yml`

- [ ] **Step 1: Write the build script**

`extension/build.sh`:

```bash
#!/usr/bin/env bash
# Copies the single extension source into both delivery shapes. One source tree, two
# builds — the Safari appex gets a copy at build time, Chrome gets a zip for the store.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
dist="$here/dist"
rm -rf "$dist"; mkdir -p "$dist/chrome"
cp -R "$here/manifest.json" "$here/src" "$here/icons" "$dist/chrome/"
(cd "$dist/chrome" && zip -qr ../carabiner-chrome.zip .)
echo "✓ $dist/carabiner-chrome.zip"
```

`chmod +x extension/build.sh`. Create `extension/icons/icon128.png` by exporting the OFF-PISTE mark from `Carabiner_svg.svg` at 128×128.

- [ ] **Step 2: Write the Safari handler**

`app/CarabinerSafariExtension/SafariWebExtensionHandler.swift`:

```swift
import SafariServices

/// Required by Safari even when unused: our extension talks to the app over the loopback
/// socket like Chrome's does, so there is no native messaging to handle here. Keeping the
/// transport identical across browsers is the point — one code path, one failure mode.
class SafariWebExtensionHandler: NSObject, NSExtensionRequestHandling {
    func beginRequest(with context: NSExtensionContext) {
        context.completeRequest(returningItems: nil, completionHandler: nil)
    }
}
```

`app/CarabinerSafariExtension/Info.plist`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDisplayName</key><string>Carabiner</string>
  <key>NSExtension</key>
  <dict>
    <key>NSExtensionPointIdentifier</key><string>com.apple.Safari.web-extension</string>
    <key>NSExtensionPrincipalClass</key>
    <string>$(PRODUCT_MODULE_NAME).SafariWebExtensionHandler</string>
  </dict>
</dict>
</plist>
```

- [ ] **Step 3: Add the target to `project.yml`**

Add under `targets:`:

```yaml
  CarabinerSafariExtension:
    type: app-extension
    platform: macOS
    sources:
      - CarabinerSafariExtension
      # The extension source itself, copied in as a folder reference so Safari sees
      # manifest.json at the resource root — the same `type: folder` reasoning as
      # .deps/bin above.
      - path: ../extension/dist/chrome
        buildPhase: resources
        type: folder
    info:
      path: CarabinerSafariExtension/Info.plist
    settings:
      base:
        PRODUCT_BUNDLE_IDENTIFIER: com.offpiste.carabiner.SafariExtension
        CODE_SIGN_STYLE: Automatic
        CODE_SIGN_IDENTITY: "Apple Development"
        DEVELOPMENT_TEAM: ${CARABINER_TEAM_ID}
        ENABLE_HARDENED_RUNTIME: YES
        GENERATE_INFOPLIST_FILE: NO
      configs:
        Release:
          CODE_SIGN_STYLE: Manual
          CODE_SIGN_IDENTITY: "Developer ID Application"
          DEVELOPMENT_TEAM: ${CARABINER_RELEASE_TEAM_ID}
          OTHER_CODE_SIGN_FLAGS: "--timestamp"
          CODE_SIGN_INJECT_BASE_ENTITLEMENTS: NO
```

And add to the `Carabiner` target's `dependencies`:

```yaml
      - target: CarabinerSafariExtension
        embed: true
```

Unlike `Resources/`, `PlugIns/` **is** auto-signed by Xcode (gotcha #19), so the appex needs no entry in the manual signing loop.

- [ ] **Step 4: Build, install, enable in Safari**

```bash
./extension/build.sh
cd app && xcodegen generate && xcodebuild -project Carabiner.xcodeproj -scheme Carabiner \
  -configuration Debug -derivedDataPath /tmp/carabiner-dd build
pkill -x Carabiner; rm -rf ~/Applications/Carabiner.app
cp -R /tmp/carabiner-dd/Build/Products/Debug/Carabiner.app ~/Applications/ && open ~/Applications/Carabiner.app
```

Safari → Settings → Extensions → enable Carabiner → set instagram.com to "Allow". Verify the appex is embedded and hardened:

```bash
codesign -dv ~/Applications/Carabiner.app/Contents/PlugIns/CarabinerSafariExtension.appex 2>&1 | grep flags
```

Expected: `flags=0x10000(runtime)`.

- [ ] **Step 5: Grab from the feed in Safari**

Same procedure as Task 9 Step 5, in Safari. If Task 1 found that Safari cookies need Full Disk Access, expect the grab to fail with a cookie error until Task 11's row is used — note it and continue.

- [ ] **Step 6: Commit**

```bash
git add app/CarabinerSafariExtension app/project.yml extension/build.sh extension/icons
git commit -m "feat(app): ship the Safari extension inside Carabiner.app"
```

---

### Task 11: Onboarding rows

**Files:**
- Modify: `app/Carabiner/Onboarding/PermissionModels.swift`
- Modify: `app/Carabiner/Onboarding/PermissionChecker.swift`
- Modify: `app/Carabiner/Onboarding/OnboardingViewModel.swift`
- Test: `app/CarabinerTests/PermissionModelsTests.swift`

- [ ] **Step 1: Write the failing tests**

Append to `app/CarabinerTests/PermissionModelsTests.swift`:

```swift
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
```

If Task 1 confirmed Full Disk Access is required, add these too:

```swift
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
}
```

- [ ] **Step 2: Run to verify failure**

Run the `xcodebuild … test` command. Expected: FAIL — no `.browserButton` case.

- [ ] **Step 3: Add the row(s)**

In `PermissionModels.swift`, add `case browserButton` to `PermissionRow` (and `case fullDiskAccess` only if Task 1 confirmed it), then extend each `switch` in that file:

```swift
        case .browserButton:  return "Instagram button"
```
```swift
        case .browserButton:  return "So you can save a post straight from your feed."
```

Add the status helper:

```swift
/// Green means a browser's extension has genuinely reached the app — never a guess about
/// whether something is "probably installed". A stale check-in is not proof.
func browserButtonStatus(lastSeen: Date?, now: Date,
                         freshness: TimeInterval = 60 * 60 * 24 * 14) -> PermissionStatus {
    guard let lastSeen, now.timeIntervalSince(lastSeen) < freshness else { return .notDetermined }
    return .granted
}
```

Then add the row-aware intent wrapper. `toggleAction(desired:status:)` is a free function today and stays exactly as it is — this only lets a row that cannot be prompted override it:

```swift
extension PermissionRow {
    /// Most rows can trigger their own OS prompt, so they defer to the shared rule.
    /// A row that macOS provides no way to prompt for can only deep-link.
    func intent(desired: Bool, status: PermissionStatus) -> ToggleIntent {
        guard desired else { return toggleAction(desired: desired, status: status) }
        return canBePrompted ? toggleAction(desired: desired, status: status) : .openSystemSettings
    }

    var canBePrompted: Bool {
        switch self {
        case .notifications, .browserAccess, .carouselDialog, .browserButton: return true
        // Only if Task 1 confirmed it:
        // case .fullDiskAccess: return false
        }
    }
}
```

If adding `fullDiskAccess`, its deep link is `x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles`. Detect its real state by attempting the Safari cookie read — never by assuming. Point `OnboardingViewModel` at `row.intent(desired:status:)` wherever it currently calls `toggleAction` directly.

- [ ] **Step 4: Wire the row's Allow action**

In `OnboardingViewModel.swift`, the `.browserButton` request action opens the install page for each detected browser:

```swift
    /// Unlisted Web Store listing — installable by direct link only. Replace with the
    /// real ID once the listing exists (Task 12).
    static let chromeWebStoreURL = "https://chromewebstore.google.com/detail/PLACEHOLDER_ID"

    func installBrowserButton() {
        if isInstalled("com.google.Chrome") {
            NSWorkspace.shared.open(URL(string: Self.chromeWebStoreURL)!)
        }
        if isInstalled("com.apple.Safari") {
            SFSafariApplication.showPreferencesForExtension(
                withIdentifier: "com.offpiste.carabiner.SafariExtension")
        }
    }
```

Import `SafariServices`. Read the row's live status from `controller.grabServer?.lastSeen`.

- [ ] **Step 5: Run the tests and check the window**

Run the `xcodebuild … test` command — expected PASS. Then rebuild, install, open Setup & Permissions from the status menu, and confirm: the Instagram button row is present, its Allow opens the right place per browser, and it turns green only after a browser's extension has actually called `/health`.

- [ ] **Step 6: Commit**

```bash
git add app/Carabiner/Onboarding app/CarabinerTests/PermissionModelsTests.swift
git commit -m "feat(onboarding): Allow rows for the browser button"
```

---

### Task 12: Publish, document, and verify end to end

**Files:**
- Modify: `README.md`
- Modify: `CLAUDE.md`
- Modify: `app/Carabiner/Onboarding/OnboardingViewModel.swift` (real store ID)

- [ ] **Step 1: Publish the unlisted Chrome listing**

Register the Chrome Web Store developer account ($5, one-off). Upload `extension/dist/carabiner-chrome.zip`. Set visibility to **Unlisted**. In the privacy justification, state plainly: the `127.0.0.1` host permission is used to hand the post URL to the companion macOS app, and the extension performs no downloads and collects no data.

- [ ] **Step 2: Put the real ID in the app and rebuild**

Replace `PLACEHOLDER_ID` in `chromeWebStoreURL` with the published listing's ID, rebuild, reinstall.

- [ ] **Step 3: Full end-to-end verification, both browsers**

For **each** of Chrome and Safari, with `ls -1 ~/Downloads > /tmp/before.txt` before each grab and the diff after:

1. A single-image post from the **feed**.
2. A **profile grid** thumbnail.
3. A **video reel** from a permalink page — then open the result in QuickTime Player and confirm it plays.
4. A **mixed video+image carousel** (both OFF-PISTE posts qualify — gotcha #15's second failure only shows on a mixed post). Confirm the native dialog appears, that "This slide" and "All" both work, and that **Cancel downloads nothing and posts no banner** (gotcha #24).

Record actual results. Any step that fails is a finding, not a footnote.

- [ ] **Step 4: Update `README.md`**

Add an "Instagram button" section: install Carabiner, open Setup & Permissions, click Allow on the row for your browser, then a button appears on Instagram posts. Note it is Instagram-only and that the hotkey remains the answer for YouTube and Pinterest.

- [ ] **Step 5: Update `CLAUDE.md`**

Add to "What this project is": a **third front end**, the browser extension, sharing the engine with the app and the Shortcut. Add to "Where things are": `extension/` and `app/CarabinerSafariExtension/`. Record as gotchas anything Tasks 1–11 earned the hard way — at minimum:

- The content-script-vs-service-worker origin rule, and why a content-script fetch is correctly rejected.
- Whether Safari cookies need Full Disk Access (the Task 1 verdict).
- That the port must never silently move.

Do not invent gotchas. Only record what was actually hit.

- [ ] **Step 6: Commit**

```bash
git add README.md CLAUDE.md app/Carabiner/Onboarding/OnboardingViewModel.swift
git commit -m "docs: browser extension install instructions and what it cost"
```

---

## Notes for whoever executes this

- **Tasks 1 and 2 are gates, not warm-ups.** If Safari does not send `Origin`, stop and escalate — Tasks 3, 9 and 11 change shape.
- **Never test the extension against the repo's `carabiner` script.** The app runs its own bundled copy from `Contents/Resources/carabiner`; editing the repo copy and re-running the installed app tests nothing.
- **Verify grabs by filename diff, never by timestamp.** gallery-dl preserves Instagram's original mtime.
- **Build with `-derivedDataPath /tmp/carabiner-dd`.** This repo is in iCloud and the signing step loses the race otherwise.
- **Leave no unsigned copy of the bundle anywhere on disk** — it poisons notifications for the signed one (gotcha #11).
