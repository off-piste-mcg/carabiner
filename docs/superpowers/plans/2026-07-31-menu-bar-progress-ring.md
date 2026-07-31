# Menu-Bar Progress Ring Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Show a progress arc around the menu-bar logo while a grab runs, driven by real progress reported by the `carabiner` script, so a slow download never looks like a dead hotkey.

**Architecture:** The script reports *what stage it is in and how far through* as `::progress:` lines on stderr; the app owns *what that looks like*. `ProgressModel` (pure) turns those lines into a 0–1 arc value using per-stage bands and a decaying creep for stages with no data. `StatusIconRenderer` (pure) turns a 0–1 value into a template `NSImage`. `RingAnimator` runs a 30fps timer only while a grab is in flight. The script never knows about arcs; the app never knows about yt-dlp.

**Tech Stack:** Swift 5 / AppKit / XCTest (app), bash (script + tests), XcodeGen.

**Spec:** `docs/superpowers/specs/2026-07-31-menu-bar-progress-ring-design.md`

## Global Constraints

- **Branch:** `progress-ring` (already created, off `phase2-bundle-deps`).
- **No new dependencies.** Three tools only: `yt-dlp`, `ffmpeg`, `gallery-dl`.
- **The status icon stays a template image** (`isTemplate = true`). No colour, no `effectiveAppearance` observation. Alpha is the only channel template rendering uses.
- **Geometry, settled on a real menu bar — do not re-derive:** composite `22 × 22` pt; mark height while busy `10` pt (resting size stays `20.5 × 16`); stroke `1.5` pt; track opacity `0.12`; arc starts at 12 o'clock and sweeps clockwise with a round cap.
- **Arc bands:** resolve `0.00–0.05`, probe `0.05–0.12`, prompt frozen, download `0.12–0.75`, convert `0.75–0.96`, save `0.96–1.00`.
- **Creep formula:** `lo + (hi - lo) * (1 - exp(-elapsed / tau))`. Tau: probe `0.9`, convert `1.6` when encoding / `0.25` when remuxing, everything else `0.7`.
- **stdout is untouchable.** It is the `✓ <filename>` channel `GrabRunner` and the Shortcut parse. All progress goes to **stderr**.
- **`set -uo pipefail` at `carabiner:31` is load-bearing** for Task 6. Do not remove it.
- **Every build signs** (gotcha #11). `CARABINER_TEAM_ID` must be exported before `xcodegen`/`xcodebuild`:
  ```bash
  export CARABINER_TEAM_ID=$(security find-certificate -a -c "Apple Development" -p \
    | openssl x509 -noout -subject | tr ',/' '\n\n' \
    | sed -nE 's/.*OU=([A-Z0-9]{10}).*/\1/p' | head -1)
  ```
- **The running app executes the bundled snapshot of `carabiner`**, not the repo copy. Any script change needs `xcodegen generate` → `xcodebuild` → reinstall before an app-driven test means anything.
- **Verification honesty:** every new assertion must be made to fail on purpose before it is trusted. A test that has never failed has not been tested.

---

## File Structure

| File | Responsibility |
|---|---|
| `app/Carabiner/ProgressModel.swift` | **new.** Marker parsing, line buffering, stage→arc-value policy. Pure, no AppKit. |
| `app/Carabiner/StatusIconRenderer.swift` | **new.** 0–1 value → composite template `NSImage`. Pure drawing, no state. |
| `app/Carabiner/RingAnimator.swift` | **new.** Owns the 30fps timer, the displayed value, and the complete/hold/fade ending. |
| `app/Carabiner/GrabRunner.swift` | **modify.** Stream stderr line-by-line; `onProgress` callback; keep progress lines out of the failure reason. |
| `app/Carabiner/MenuBarController.swift` | **modify.** Start the ring, forward events, end it. |
| `app/CarabinerTests/ProgressModelTests.swift` | **new.** |
| `app/CarabinerTests/StatusIconRendererTests.swift` | **new.** |
| `app/CarabinerTests/GrabRunnerTests.swift` | **modify.** Extend. |
| `carabiner` | **modify.** `progress()` helper and the markers. |
| `test/test-progress.sh` | **new.** Offline script tests with stubbed binaries. |

**Deviation from the spec's file list, deliberate:** the spec put the timer in `MenuBarController`. It goes in `RingAnimator` instead — `MenuBarController` is already the app's coordinator, and folding a timer, a fade state machine and a display value into it would make the one file that does the most do more. The spec's intent ("units small enough to hold in context") is better served this way.

---

### Task 1: ProgressModel — parsing and arc policy

**Files:**
- Create: `app/Carabiner/ProgressModel.swift`
- Test: `app/CarabinerTests/ProgressModelTests.swift`
- Modify: `app/project.yml` (no change needed — `sources: - Carabiner` picks up new files in the directory; confirm in Step 6)

**Interfaces:**
- Consumes: nothing.
- Produces:
  - `enum ProgressEvent: Equatable` — `.probe`, `.prompt`, `.download(percent: Double?)`, `.item(index: Int, total: Int)`, `.convert(ConvertMode)`, `.save`
  - `enum ConvertMode: String` — `.remux`, `.encode`
  - `enum ProgressStage` — `.resolve`, `.probe`, `.prompt`, `.download`, `.convert`, `.save`, `.complete`
  - `enum ProgressParser` — `static let marker: String`, `static func parse(_ line: String) -> ProgressEvent?`
  - `struct LineBuffer` — `mutating func append(_ chunk: Data) -> [String]`, `mutating func flush() -> String?`
  - `struct ProgressModel` — `init(start: Date)`, `private(set) var stage`, `mutating func apply(_ event: ProgressEvent, at: Date)`, `mutating func finish(at: Date)`, `mutating func target(at: Date) -> Double`

- [ ] **Step 1: Write the failing tests**

Create `app/CarabinerTests/ProgressModelTests.swift`:

```swift
import XCTest
@testable import Carabiner

final class ProgressParserTests: XCTestCase {
    func testParsesSimpleStages() {
        XCTAssertEqual(ProgressParser.parse("::progress:probe"), .probe)
        XCTAssertEqual(ProgressParser.parse("::progress:prompt"), .prompt)
        XCTAssertEqual(ProgressParser.parse("::progress:save"), .save)
    }

    /// yt-dlp's `%(progress._percent_str)s` is a *display* string — padded, with a percent
    /// sign. Parsing has to survive that rather than assume a bare number.
    func testParsesPaddedPercentString() {
        XCTAssertEqual(ProgressParser.parse("::progress:download:  42.3%"), .download(percent: 42.3))
        XCTAssertEqual(ProgressParser.parse("::progress:download:100.0%"), .download(percent: 100))
    }

    /// yt-dlp prints "N/A" when it does not know the total size, and gallery-dl reports no
    /// percentage at all. Both must degrade to "no data" — which makes the stage creep —
    /// rather than being dropped, which would leave the stage unset entirely.
    func testUnreadablePercentBecomesNoData() {
        XCTAssertEqual(ProgressParser.parse("::progress:download:N/A"), .download(percent: nil))
        XCTAssertEqual(ProgressParser.parse("::progress:download"), .download(percent: nil))
    }

    func testParsesItemAndConvert() {
        XCTAssertEqual(ProgressParser.parse("::progress:item:2:5"), .item(index: 2, total: 5))
        XCTAssertEqual(ProgressParser.parse("::progress:convert:remux"), .convert(.remux))
        XCTAssertEqual(ProgressParser.parse("::progress:convert:encode"), .convert(.encode))
    }

    /// Everything the tools normally print must be ignored, or ordinary log noise would
    /// drive the ring.
    func testIgnoresNonMarkerLines() {
        XCTAssertNil(ProgressParser.parse("[download] 42% of 3MiB"))
        XCTAssertNil(ProgressParser.parse(""))
        XCTAssertNil(ProgressParser.parse("::progress:nonsense"))
        XCTAssertNil(ProgressParser.parse("::progress:item:2"))
    }
}

final class LineBufferTests: XCTestCase {
    /// A marker split across two pipe reads must not be parsed as two half-lines — that
    /// would produce a garbage event and, worse, a plausible-looking one.
    func testReassemblesLineSplitAcrossChunks() {
        var buf = LineBuffer()
        XCTAssertEqual(buf.append(Data("::progr".utf8)), [])
        XCTAssertEqual(buf.append(Data("ess:probe\n".utf8)), ["::progress:probe"])
    }

    func testSplitsMultipleLinesInOneChunk() {
        var buf = LineBuffer()
        XCTAssertEqual(buf.append(Data("a\nb\nc".utf8)), ["a", "b"])
        XCTAssertEqual(buf.flush(), "c")
        XCTAssertNil(buf.flush())
    }
}

final class ProgressModelTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_000_000)
    private func at(_ s: TimeInterval) -> Date { t0.addingTimeInterval(s) }

    /// Creep must approach its ceiling and never cross it. Crossing would let an
    /// unknown-length stage claim progress belonging to the next one.
    func testCreepNeverReachesItsCeiling() {
        var m = ProgressModel(start: t0)
        m.apply(.probe, at: t0)
        XCTAssertLessThan(m.target(at: at(60)), 0.12)
        XCTAssertGreaterThan(m.target(at: at(60)), 0.119)
    }

    func testDownloadPercentMapsIntoItsBand() {
        var m = ProgressModel(start: t0)
        m.apply(.download(percent: 0), at: t0)
        XCTAssertEqual(m.target(at: t0), 0.12, accuracy: 0.001)
        m.apply(.download(percent: 100), at: at(1))
        XCTAssertEqual(m.target(at: at(1)), 0.75, accuracy: 0.001)
    }

    /// A retreating arc reads as an error. yt-dlp restarts its percentage when it moves
    /// from the video stream to the audio stream, so this is a real input, not a
    /// hypothetical one.
    func testValueNeverDecreases() {
        var m = ProgressModel(start: t0)
        m.apply(.download(percent: 80), at: t0)
        let high = m.target(at: t0)
        m.apply(.download(percent: 5), at: at(1))
        XCTAssertEqual(m.target(at: at(1)), high, accuracy: 0.0001)
    }

    /// The carousel dialog blocks on the user, not on the machine. Creeping there would
    /// claim the tool is working when it is waiting.
    func testPromptFreezesTheValue() {
        var m = ProgressModel(start: t0)
        m.apply(.probe, at: t0)
        let entry = m.target(at: at(2))
        m.apply(.prompt, at: at(2))
        XCTAssertEqual(m.target(at: at(30)), entry, accuracy: 0.0001)
    }

    /// With N items the download+convert range is divided evenly, so a five-slide carousel
    /// advances five times rather than snapping to 96% on the first file.
    func testItemsSubdivideTheDownloadConvertRange() {
        var m = ProgressModel(start: t0)
        m.apply(.item(index: 1, total: 4), at: t0)
        m.apply(.download(percent: 0), at: t0)
        XCTAssertEqual(m.target(at: t0), 0.12, accuracy: 0.001)

        m.apply(.item(index: 4, total: 4), at: at(1))
        m.apply(.convert(.encode), at: at(1))
        // Final slice, convert stage: its ceiling is the end of the whole item range.
        XCTAssertLessThanOrEqual(m.target(at: at(600)), 0.96)
        XCTAssertGreaterThan(m.target(at: at(600)), 0.95)
    }

    func testFinishGoesToFull() {
        var m = ProgressModel(start: t0)
        m.apply(.download(percent: 10), at: t0)
        m.finish(at: at(1))
        XCTAssertEqual(m.target(at: at(1)), 1.0, accuracy: 0.0001)
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

```bash
export CARABINER_TEAM_ID=$(security find-certificate -a -c "Apple Development" -p \
  | openssl x509 -noout -subject | tr ',/' '\n\n' \
  | sed -nE 's/.*OU=([A-Z0-9]{10}).*/\1/p' | head -1)
cd app && xcodegen generate
xcodebuild -project Carabiner.xcodeproj -scheme Carabiner -destination 'platform=macOS' test
```

Expected: FAIL to compile — `cannot find 'ProgressParser' in scope`.

- [ ] **Step 3: Write the implementation**

Create `app/Carabiner/ProgressModel.swift`:

```swift
import Foundation

/// One thing the script has told us about where it has got to. The script reports stages
/// and local progress; the mapping onto a circle lives here, in the app, because the
/// circle is an app concern the script must stay ignorant of.
enum ProgressEvent: Equatable {
    case probe
    case prompt
    /// `nil` means the tool cannot report a percentage (gallery-dl always, yt-dlp when the
    /// total size is unknown). That stage creeps instead.
    case download(percent: Double?)
    case item(index: Int, total: Int)
    case convert(ConvertMode)
    case save
}

enum ConvertMode: String, Equatable {
    case remux, encode
}

enum ProgressStage: Equatable {
    case resolve, probe, prompt, download, convert, save, complete
}

enum ProgressParser {
    static let marker = "::progress:"

    static func parse(_ rawLine: String) -> ProgressEvent? {
        let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
        guard line.hasPrefix(marker) else { return nil }
        let fields = line.dropFirst(marker.count).components(separatedBy: ":")
        switch fields.first {
        case "probe":  return .probe
        case "prompt": return .prompt
        case "save":   return .save
        case "download":
            return .download(percent: fields.count > 1 ? percent(fields[1]) : nil)
        case "item":
            guard fields.count > 2, let i = Int(fields[1]), let n = Int(fields[2]),
                  i > 0, n > 0 else { return nil }
            return .item(index: i, total: n)
        case "convert":
            guard fields.count > 1, let mode = ConvertMode(rawValue: fields[1]) else { return nil }
            return .convert(mode)
        default:
            return nil
        }
    }

    /// yt-dlp's `%(progress._percent_str)s` is a display string: space-padded, carrying a
    /// percent sign, and literally "N/A" before the total size is known. Parse leniently —
    /// anything unreadable becomes "no data", which creeps, rather than an event we drop.
    private static func percent(_ field: String) -> Double? {
        let cleaned = field.replacingOccurrences(of: "%", with: "")
                           .trimmingCharacters(in: .whitespaces)
        guard let v = Double(cleaned), v.isFinite else { return nil }
        return min(100, max(0, v))
    }
}

/// Accumulates arbitrary byte chunks from a pipe and hands back whole lines. Pipe reads
/// land on no particular boundary, so a marker can arrive in two pieces; parsing those
/// pieces separately would produce a plausible-looking garbage event.
struct LineBuffer {
    private var pending = Data()

    mutating func append(_ chunk: Data) -> [String] {
        pending.append(chunk)
        var out: [String] = []
        while let nl = pending.firstIndex(of: 0x0A) {
            out.append(String(data: pending[..<nl], encoding: .utf8) ?? "")
            pending = Data(pending[(nl + 1)...])
        }
        return out
    }

    /// Whatever is left when the stream ends without a trailing newline.
    mutating func flush() -> String? {
        defer { pending = Data() }
        return pending.isEmpty ? nil : String(data: pending, encoding: .utf8)
    }
}

/// Turns a sequence of events into a 0...1 arc value.
struct ProgressModel {
    private struct Slice { let index: Int; let total: Int }

    private(set) var stage: ProgressStage = .resolve
    private var stageStart: Date
    private var downloadPercent: Double?
    private var convertMode: ConvertMode = .encode
    private var slice: Slice?
    /// The value is clamped non-decreasing: yt-dlp restarts its percentage when it moves
    /// from the video stream to the audio stream, and an arc that retreats reads as an error.
    private var highWater: Double = 0
    private var frozen: Double = 0

    init(start: Date) { stageStart = start }

    mutating func apply(_ event: ProgressEvent, at now: Date) {
        switch event {
        case .probe:  enterIfChanged(.probe, at: now)
        case .prompt: enterIfChanged(.prompt, at: now)
        case .save:   enterIfChanged(.save, at: now)
        case .download(let p):
            enterIfChanged(.download, at: now)
            downloadPercent = p
        case .convert(let mode):
            convertMode = mode
            enterIfChanged(.convert, at: now)
        case .item(let i, let n):
            slice = Slice(index: i, total: n)
            // A new item always restarts the download stage, even from the download stage —
            // its creep and its percentage belong to the new slice, not the old one.
            enter(.download, at: now)
        }
    }

    mutating func finish(at now: Date) { enterIfChanged(.complete, at: now) }

    mutating func target(at now: Date) -> Double {
        let band = currentBand()
        let raw: Double
        switch stage {
        case .prompt:
            raw = frozen
        case .complete:
            raw = 1.0
        case .download where downloadPercent != nil:
            raw = band.lo + (band.hi - band.lo) * (downloadPercent! / 100)
        default:
            let elapsed = max(0, now.timeIntervalSince(stageStart))
            raw = band.lo + (band.hi - band.lo) * (1 - exp(-elapsed / Self.tau(stage, convertMode)))
        }
        highWater = max(highWater, raw)
        return highWater
    }

    // MARK: - policy

    private static let itemLo = 0.12, itemHi = 0.96
    /// Within one item's slice, download and convert keep the same 3:1 proportion they
    /// have globally (0.63 wide against 0.21).
    private static let downloadShareOfSlice = 0.75

    static func band(_ stage: ProgressStage) -> (lo: Double, hi: Double) {
        switch stage {
        case .resolve:  return (0.00, 0.05)
        case .probe:    return (0.05, 0.12)
        case .prompt:   return (0.12, 0.12)
        case .download: return (0.12, 0.75)
        case .convert:  return (0.75, 0.96)
        case .save:     return (0.96, 1.00)
        case .complete: return (1.00, 1.00)
        }
    }

    static func tau(_ stage: ProgressStage, _ mode: ConvertMode) -> Double {
        switch stage {
        case .probe:   return 0.9
        case .convert: return mode == .remux ? 0.25 : 1.6
        default:       return 0.7
        }
    }

    private func currentBand() -> (lo: Double, hi: Double) {
        let base = Self.band(stage)
        guard let slice, slice.total > 1,
              stage == .download || stage == .convert else { return base }
        let width = (Self.itemHi - Self.itemLo) / Double(slice.total)
        let lo = Self.itemLo + width * Double(slice.index - 1)
        let split = lo + width * Self.downloadShareOfSlice
        return stage == .download ? (lo, split) : (split, lo + width)
    }

    private mutating func enterIfChanged(_ s: ProgressStage, at now: Date) {
        guard s != stage else { return }
        enter(s, at: now)
    }

    private mutating func enter(_ s: ProgressStage, at now: Date) {
        if s == .prompt { frozen = highWater }
        stage = s
        stageStart = now
        downloadPercent = nil
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

```bash
cd app && xcodebuild -project Carabiner.xcodeproj -scheme Carabiner -destination 'platform=macOS' test
```

Expected: PASS, all of `ProgressParserTests`, `LineBufferTests`, `ProgressModelTests`.

- [ ] **Step 5: Prove the tests can fail**

Temporarily change `highWater = max(highWater, raw)` to `highWater = raw` and re-run. Expected: `testValueNeverDecreases` FAILS. Then change `itemHi` from `0.96` to `1.0` and re-run. Expected: `testItemsSubdivideTheDownloadConvertRange` FAILS. Revert both.

- [ ] **Step 6: Confirm XcodeGen picked the file up**

```bash
grep -c ProgressModel.swift app/Carabiner.xcodeproj/project.pbxproj
```

Expected: a number `> 0`. `app/project.yml` uses `sources: - Carabiner`, a whole-directory reference, so no edit should be needed — if this returns `0`, re-run `xcodegen generate`.

- [ ] **Step 7: Commit**

```bash
git add app/Carabiner/ProgressModel.swift app/CarabinerTests/ProgressModelTests.swift
git commit -m "feat(app): parse progress markers into an arc value

The script will report stages and local progress; the mapping onto a circle
belongs here rather than in bash, so the script stays ignorant of the ring.

Two properties are load-bearing and tested: creep approaches a stage's ceiling
without crossing it, and the value never decreases — yt-dlp restarts its
percentage when it moves from the video stream to the audio stream, and an arc
that retreats reads as an error."
```

---

### Task 2: StatusIconRenderer — the composite image

**Files:**
- Create: `app/Carabiner/StatusIconRenderer.swift`
- Test: `app/CarabinerTests/StatusIconRendererTests.swift`

**Interfaces:**
- Consumes: nothing from Task 1.
- Produces: `struct StatusIconRenderer` — `init(mark: NSImage?)`, `func idle() -> NSImage?`, `func busy(progress: Double, alpha: CGFloat) -> NSImage`, plus the geometry constants `static let side: CGFloat`, `static let markHeight: CGFloat`, `static let stroke: CGFloat`, `static let trackAlpha: CGFloat`.

- [ ] **Step 1: Write the failing test**

Create `app/CarabinerTests/StatusIconRendererTests.swift`:

```swift
import XCTest
import AppKit
@testable import Carabiner

final class StatusIconRendererTests: XCTestCase {
    private func renderer() -> StatusIconRenderer {
        StatusIconRenderer(mark: NSImage(named: "StatusIcon"))
    }

    /// Alpha at a point, 0...1. Sampled from a bitmap rendered at 1x.
    private func alpha(_ image: NSImage, x: Int, y: Int) -> CGFloat {
        let rep = NSBitmapImageRep(data: image.tiffRepresentation!)!
        return rep.colorAt(x: x, y: y)?.alphaComponent ?? 0
    }

    /// Template rendering is what makes the icon adapt to a light or dark menu bar with no
    /// appearance-handling code. Losing the flag is invisible on whichever appearance the
    /// developer happens to be using.
    func testBothImagesAreTemplates() {
        XCTAssertTrue(renderer().busy(progress: 0.5, alpha: 1).isTemplate)
        XCTAssertEqual(renderer().idle()?.isTemplate, true)
    }

    func testSizes() {
        XCTAssertEqual(renderer().busy(progress: 0.5, alpha: 1).size, NSSize(width: 22, height: 22))
        XCTAssertEqual(renderer().idle()?.size, NSSize(width: 20.5, height: 16))
    }

    /// The arc starts at 12 o'clock. At 0 progress that point carries only the faint track;
    /// at half progress it carries the arc itself.
    func testArcIsDrawnAtTwelveOClock() {
        let r = renderer()
        let empty = alpha(r.busy(progress: 0, alpha: 1), x: 11, y: 21)
        let half = alpha(r.busy(progress: 0.5, alpha: 1), x: 11, y: 21)
        XCTAssertGreaterThan(half, empty + 0.3)
    }

    /// ...and sweeps *clockwise*, so 6 o'clock is reached only after half the circle.
    /// A counter-clockwise arc passes the twelve-o'clock test above and fails this one.
    func testArcSweepsClockwise() {
        let r = renderer()
        let quarter = alpha(r.busy(progress: 0.25, alpha: 1), x: 11, y: 1)
        let threeQuarters = alpha(r.busy(progress: 0.75, alpha: 1), x: 11, y: 1)
        XCTAssertGreaterThan(threeQuarters, quarter + 0.3)
    }

    /// The fade at the end of a grab has to actually fade.
    func testAlphaScalesTheWholeComposite() {
        let r = renderer()
        let opaque = alpha(r.busy(progress: 1, alpha: 1), x: 11, y: 21)
        let faded = alpha(r.busy(progress: 1, alpha: 0.25), x: 11, y: 21)
        XCTAssertLessThan(faded, opaque)
    }

    /// A missing asset must not crash the menu bar — it draws the ring and no mark.
    func testSurvivesAMissingMark() {
        let r = StatusIconRenderer(mark: nil)
        XCTAssertEqual(r.busy(progress: 0.5, alpha: 1).size, NSSize(width: 22, height: 22))
        XCTAssertNil(r.idle())
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

```bash
cd app && xcodebuild -project Carabiner.xcodeproj -scheme Carabiner -destination 'platform=macOS' test
```

Expected: FAIL to compile — `cannot find 'StatusIconRenderer' in scope`.

- [ ] **Step 3: Write the implementation**

Create `app/Carabiner/StatusIconRenderer.swift`:

```swift
import AppKit

/// Draws the status item's image: the resting mark, or the mark shrunk inside a progress
/// ring. Pure — a value in, an image out, no state and no timers.
///
/// Geometry was settled by running a throwaway prototype on a real menu bar rather than
/// derived, because a true circle does not fit around the mark at its resting size: the
/// mark is 20.5 x 16pt, so a ring around it lands near 25pt diameter in a 22-24pt bar.
/// Hence the shrink to 10pt for the duration of a grab. See the design doc.
struct StatusIconRenderer {
    static let side: CGFloat = 22
    static let markHeight: CGFloat = 10
    static let stroke: CGFloat = 1.5
    static let trackAlpha: CGFloat = 0.12
    /// The asset is cropped to the mark's own bounds (496:388), so height sets the size
    /// and width follows.
    static let markAspect: CGFloat = 496.0 / 388.0

    let mark: NSImage?

    init(mark: NSImage?) { self.mark = mark }

    /// The resting icon — unchanged from what the menu bar has always shown.
    func idle() -> NSImage? {
        guard let copy = mark?.copy() as? NSImage else { return nil }
        copy.size = NSSize(width: 20.5, height: 16)
        copy.isTemplate = true
        return copy
    }

    func busy(progress: Double, alpha: CGFloat) -> NSImage {
        let side = Self.side, stroke = Self.stroke
        let mark = self.mark
        let clamped = min(1, max(0, progress))

        let image = NSImage(size: NSSize(width: side, height: side), flipped: false) { _ in
            let centre = NSPoint(x: side / 2, y: side / 2)
            let radius = side / 2 - (stroke / 2 + 0.5)

            let track = NSBezierPath()
            track.appendArc(withCenter: centre, radius: radius, startAngle: 0, endAngle: 360)
            track.lineWidth = stroke
            NSColor.black.withAlphaComponent(Self.trackAlpha * alpha).setStroke()
            track.stroke()

            if clamped > 0.002 {
                // From 12 o'clock, clockwise. AppKit measures anticlockwise from 3 o'clock,
                // so the sweep is 90 degrees *minus* the travelled fraction.
                let arc = NSBezierPath()
                arc.appendArc(withCenter: centre, radius: radius,
                              startAngle: 90, endAngle: 90 - 360 * CGFloat(clamped),
                              clockwise: true)
                arc.lineWidth = stroke
                arc.lineCapStyle = .round
                NSColor.black.withAlphaComponent(alpha).setStroke()
                arc.stroke()
            }

            if let mark {
                let h = Self.markHeight, w = h * Self.markAspect
                mark.draw(in: NSRect(x: (side - w) / 2, y: (side - h) / 2, width: w, height: h),
                          from: .zero, operation: .sourceOver, fraction: alpha)
            }
            return true
        }
        // Template rendering uses only the alpha channel, which is why the 12% track
        // survives tinting and the whole composite still adapts to light and dark bars
        // without a line of appearance-handling code.
        image.isTemplate = true
        return image
    }
}
```

- [ ] **Step 4: Run the test to verify it passes**

```bash
cd app && xcodebuild -project Carabiner.xcodeproj -scheme Carabiner -destination 'platform=macOS' test
```

Expected: PASS.

- [ ] **Step 5: Prove the clockwise test can fail**

Change `clockwise: true` to `clockwise: false` and re-run. Expected: `testArcSweepsClockwise` FAILS while `testArcIsDrawnAtTwelveOClock` still passes — which is the point of having both. Revert.

- [ ] **Step 6: Commit**

```bash
git add app/Carabiner/StatusIconRenderer.swift app/CarabinerTests/StatusIconRendererTests.swift
git commit -m "feat(app): draw the progress ring around the status icon

Geometry came from a throwaway prototype on a real menu bar, not from
arithmetic: a true circle does not fit around the mark at its resting size,
so the mark shrinks to 10pt for the duration of a grab.

Stays a template image. Template rendering uses only alpha, so the 12% track
survives tinting and the icon still adapts to light and dark bars with no
appearance-handling code — which is what a coloured arc would have cost."
```

---

### Task 3: GrabRunner streams progress

**Files:**
- Modify: `app/Carabiner/GrabRunner.swift:24` (add property), `:66-72` (stderr draining), `:75-76` (line extraction)
- Test: `app/CarabinerTests/GrabRunnerTests.swift` (append)

**Interfaces:**
- Consumes: `ProgressEvent`, `ProgressParser`, `LineBuffer` from Task 1.
- Produces: `GrabRunner.onProgress: ((ProgressEvent) -> Void)?` — called on a background queue, once per marker line, in the order the script emitted them.

- [ ] **Step 1: Write the failing tests**

Append to `app/CarabinerTests/GrabRunnerTests.swift`, inside `final class GrabRunnerTests`:

```swift
    /// Thread-safe collector: onProgress fires on GrabRunner's own background queue.
    private final class EventBox {
        private let lock = NSLock()
        private var events: [ProgressEvent] = []
        func add(_ e: ProgressEvent) { lock.lock(); events.append(e); lock.unlock() }
        func all() -> [ProgressEvent] { lock.lock(); defer { lock.unlock() }; return events }
    }

    func testProgressEventsAreReportedInOrder() {
        let stub = writeStub("""
        echo '::progress:probe' 1>&2
        echo '::progress:download:  50.0%' 1>&2
        echo '::progress:save' 1>&2
        echo '  ✓ ABC_fixed.mp4'
        exit 0
        """)
        let box = EventBox()
        var runner = GrabRunner(executable: stub)
        runner.onProgress = { box.add($0) }
        let result = runner.run(url: "https://x/y")

        XCTAssertTrue(result.ok)
        XCTAssertEqual(box.all(), [.probe, .download(percent: 50), .save])
    }

    /// The failure reason is the last stderr line. Progress markers are stderr too, so
    /// without filtering a failed grab would banner "::progress:download:87.1" instead of
    /// what gallery-dl actually said — destroying the diagnostics that exist precisely
    /// because a notification is the one place you cannot go and read the terminal.
    func testProgressLineIsNeverTheFailureReason() {
        let stub = writeStub("""
        echo '✗ login required — cookies expired?' 1>&2
        echo '::progress:download:  87.1%' 1>&2
        exit 1
        """)
        let result = GrabRunner(executable: stub).run(url: "https://x/y")
        XCTAssertFalse(result.ok)
        XCTAssertEqual(result.message, "login required — cookies expired?")
    }

    /// Markers must not reach the success message either — stdout is the ✓ channel, but a
    /// marker mistakenly echoed there must not be counted as a saved file.
    func testProgressMarkersDoNotCountAsSaves() {
        let stub = writeStub("""
        echo '::progress:download:  10.0%' 1>&2
        echo '  ✓ ABC_fixed.mp4'
        exit 0
        """)
        let result = GrabRunner(executable: stub).run(url: "https://x/y")
        XCTAssertEqual(result.message, "ABC_fixed.mp4")
    }
```

- [ ] **Step 2: Run the tests to verify they fail**

```bash
cd app && xcodebuild -project Carabiner.xcodeproj -scheme Carabiner -destination 'platform=macOS' test
```

Expected: FAIL to compile — `value of type 'GrabRunner' has no member 'onProgress'`.

- [ ] **Step 3: Add the property**

In `app/Carabiner/GrabRunner.swift`, after the `binDirectory` property (line 24), add:

```swift
    /// Called once per `::progress:` line the script writes to stderr, in order, on a
    /// background queue. Hop to the main queue before touching any UI.
    var onProgress: ((ProgressEvent) -> Void)?
```

- [ ] **Step 4: Stream stderr instead of draining it**

Replace lines 66-72 of `app/Carabiner/GrabRunner.swift`:

```swift
        var outData = Data()
        var errData = Data()
        let group = DispatchGroup()
        let queue = DispatchQueue.global(qos: .userInitiated)
        queue.async(group: group) { outData = outPipe.fileHandleForReading.readDataToEndOfFile() }
        queue.async(group: group) { errData = errPipe.fileHandleForReading.readDataToEndOfFile() }
        group.wait()
```

with:

```swift
        var outData = Data()
        var errData = Data()
        let group = DispatchGroup()
        let queue = DispatchQueue.global(qos: .userInitiated)
        queue.async(group: group) { outData = outPipe.fileHandleForReading.readDataToEndOfFile() }
        // stderr is read incrementally rather than to EOF: progress is only useful while
        // the grab is still running, and readDataToEndOfFile would deliver every marker at
        // once, after the thing they describe had already finished.
        queue.async(group: group) {
            let handle = errPipe.fileHandleForReading
            var buffer = LineBuffer()
            while true {
                let chunk = handle.availableData
                if chunk.isEmpty { break }
                errData.append(chunk)
                for line in buffer.append(chunk) {
                    if let event = ProgressParser.parse(line) { self.onProgress?(event) }
                }
            }
            if let last = buffer.flush(), let event = ProgressParser.parse(last) {
                self.onProgress?(event)
            }
        }
        group.wait()
```

- [ ] **Step 5: Keep markers out of the failure reason**

Replace line 76 of `app/Carabiner/GrabRunner.swift`:

```swift
        let errLines = Self.lines(String(data: errData, encoding: .utf8) ?? "")
```

with:

```swift
        // Markers are stderr too. Left in, the last one would become the failure message —
        // and a grab that died on expired cookies would report a download percentage.
        let errLines = Self.lines(String(data: errData, encoding: .utf8) ?? "")
            .filter { !$0.hasPrefix(ProgressParser.marker) }
```

- [ ] **Step 6: Run the tests to verify they pass**

```bash
cd app && xcodebuild -project Carabiner.xcodeproj -scheme Carabiner -destination 'platform=macOS' test
```

Expected: PASS — including the pre-existing `testLargeInterleavedOutputDoesNotDeadlock`, which is the regression guard for the concurrent draining this step rewrites. If that test hangs, the incremental read is blocking stdout.

- [ ] **Step 7: Prove the filter test can fail**

Remove the `.filter { !$0.hasPrefix(...) }` and re-run. Expected: `testProgressLineIsNeverTheFailureReason` FAILS with the marker as the message. Restore it.

- [ ] **Step 8: Commit**

```bash
git add app/Carabiner/GrabRunner.swift app/CarabinerTests/GrabRunnerTests.swift
git commit -m "feat(app): stream progress markers off the script's stderr

stderr is now read incrementally rather than to EOF. Draining to EOF would
deliver every marker at once, after the thing each described had finished —
which is the failure this feature exists to remove, wearing a disguise.

Markers are filtered out of the failure-reason extraction. Left in, a grab
that died on expired cookies would banner a download percentage instead of
gallery-dl's own words."
```

---

### Task 4: RingAnimator and the menu-bar wiring

**Files:**
- Create: `app/Carabiner/RingAnimator.swift`
- Modify: `app/Carabiner/MenuBarController.swift:14-40` (init), `:42-79` (grab)

**Interfaces:**
- Consumes: `ProgressModel`, `ProgressEvent` (Task 1), `StatusIconRenderer` (Task 2), `GrabRunner.onProgress` (Task 3).
- Produces: `final class RingAnimator` — `init(button: NSStatusBarButton, renderer: StatusIconRenderer)`, `func begin()`, `func handle(_ event: ProgressEvent)`, `func finish(success: Bool)`. All main-thread only.

- [ ] **Step 1: Write the implementation**

There is no unit test for this task: it is a timer driving AppKit, and the two things worth testing (the value policy and the drawing) are already covered by Tasks 1 and 2 as pure functions. Verification here is Step 3, on a real menu bar.

Create `app/Carabiner/RingAnimator.swift`:

```swift
import AppKit

/// Drives the status item's image while a grab is in flight: a 30fps timer, a smoothed
/// display value, and the complete/hold/fade ending.
///
/// Main-thread only. `GrabRunner.onProgress` fires on a background queue, so callers hop
/// before calling `handle`.
final class RingAnimator {
    private weak var button: NSStatusBarButton?
    private let renderer: StatusIconRenderer
    private var model = ProgressModel(start: Date())
    private var timer: Timer?
    private var displayed: Double = 0
    private var lastTick = Date()
    private var fadeStart: Date?
    /// Set when the grab succeeded: the arc must reach a full circle and be *seen* to,
    /// which is why the fade waits rather than starting the moment the process exits.
    private var holdUntil: Date?

    private static let fps = 30.0
    private static let holdSeconds = 0.5
    private static let fadeSeconds = 0.4

    init(button: NSStatusBarButton?, renderer: StatusIconRenderer) {
        self.button = button
        self.renderer = renderer
        button?.image = renderer.idle()
    }

    func begin() {
        let now = Date()
        model = ProgressModel(start: now)
        displayed = 0
        lastTick = now
        fadeStart = nil
        holdUntil = nil
        button?.image = renderer.busy(progress: 0, alpha: 1)

        timer?.invalidate()
        let t = Timer(timeInterval: 1.0 / Self.fps, repeats: true) { [weak self] _ in self?.tick() }
        // .common, not .default: an open menu runs the run loop in event-tracking mode, and
        // a .default timer would freeze the ring for as long as the menu is down.
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func handle(_ event: ProgressEvent) {
        model.apply(event, at: Date())
    }

    func finish(success: Bool) {
        guard timer != nil else { return }
        if success {
            model.finish(at: Date())
        } else {
            // A failed grab stops where it is. Completing the circle would say "done".
            fadeStart = Date()
        }
    }

    private func tick() {
        let now = Date()
        let dt = now.timeIntervalSince(lastTick)
        lastTick = now

        if let fadeStart {
            let f = now.timeIntervalSince(fadeStart) / Self.fadeSeconds
            if f >= 1 { stop(); return }
            button?.image = renderer.busy(progress: displayed, alpha: CGFloat(1 - f))
            return
        }

        let target = model.target(at: now)
        // Exponential smoothing, and never backwards — the model already clamps, this keeps
        // the *displayed* value from overshooting a jump.
        displayed = max(displayed, displayed + (target - displayed) * min(1, dt * 12))

        if model.stage == .complete, displayed >= 0.995 {
            let hold = holdUntil ?? now.addingTimeInterval(Self.holdSeconds)
            holdUntil = hold
            if now >= hold { fadeStart = now }
        }

        button?.image = renderer.busy(progress: displayed, alpha: 1)
    }

    private func stop() {
        timer?.invalidate()
        timer = nil
        // Back to exactly what the menu bar showed before the grab.
        button?.image = renderer.idle()
    }
}
```

- [ ] **Step 2: Wire it into MenuBarController**

In `app/Carabiner/MenuBarController.swift`, replace the `statusItem.button` block in `init` (lines 15-29) with:

```swift
        let renderer = StatusIconRenderer(mark: NSImage(named: "StatusIcon"))
        // A missing asset would leave a blank, unexplained gap in the menu bar, so say so.
        if renderer.mark == nil { NSLog("Carabiner: StatusIcon asset missing — status item has no image") }
        ring = RingAnimator(button: statusItem.button, renderer: renderer)
```

Add the stored property alongside `busy` (line 12):

```swift
    private var ring: RingAnimator!
```

Change `runner` from `let` to `var` (line 11) so its `onProgress` can be set:

```swift
    private var runner = GrabRunner(browser: MenuBarController.browser)
```

In `grab()`, add `ring.begin()` immediately after the `guard !busy` block and before `notifier.showWorking()`:

```swift
        // Before the notification and before reading the tab: resolving the front tab is
        // AppleScript on this thread and is itself part of the wait. The ring covers it as
        // the `resolve` stage — the same reasoning that put showWorking() here.
        ring.begin()
```

In both early-return failure branches (`.notAuthorized` and `.nothing`), add `ring.finish(success: false)` immediately before `return`.

Replace the background dispatch block (lines 70-78) with:

```swift
        busy = true
        runner.onProgress = { [weak self] event in
            // onProgress arrives on GrabRunner's background queue; the ring is main-only.
            DispatchQueue.main.async { self?.ring.handle(event) }
        }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let result = self.runner.run(url: url)
            DispatchQueue.main.async {
                NSLog("Carabiner: grab %@ — %@", result.ok ? "succeeded" : "failed", result.message)
                self.ring.finish(success: result.ok)
                self.notifier.show(result)
                self.busy = false
            }
        }
```

- [ ] **Step 3: Build, install and watch it**

```bash
export CARABINER_TEAM_ID=$(security find-certificate -a -c "Apple Development" -p \
  | openssl x509 -noout -subject | tr ',/' '\n\n' \
  | sed -nE 's/.*OU=([A-Z0-9]{10}).*/\1/p' | head -1)
cd app && xcodegen generate
xcodebuild -project Carabiner.xcodeproj -scheme Carabiner -configuration Debug \
  -derivedDataPath build build
pkill -x Carabiner; rm -rf ~/Applications/Carabiner.app
cp -R build/Build/Products/Debug/Carabiner.app ~/Applications/ && open ~/Applications/Carabiner.app
```

The script does not emit markers yet, so this is the honest half-state: the ring appears, creeps through `resolve` toward 5%, sits there for the whole grab, then completes and fades. **That is the expected result of this task** — it proves the timer, the drawing, the fade and the lifecycle without the script. Confirm:
- the mark shrinks when the grab starts and returns afterwards
- the ring completes, holds, and fades on success
- the ring fades immediately without completing on a failure (fire the hotkey with no browser tab and nothing copyable in the clipboard)
- the ring keeps animating while the status-item menu is open (this is what `.common` mode buys)
- it looks right on a light **and** a dark menu bar

- [ ] **Step 4: Commit**

```bash
git add app/Carabiner/RingAnimator.swift app/Carabiner/MenuBarController.swift
git commit -m "feat(app): animate the status icon while a grab runs

30fps, and only while a grab is in flight — an idle menu-bar app has no
business scheduling wakeups. The timer runs in .common mode so an open menu
does not freeze the ring.

Success completes the circle and holds half a second before fading, so the
completion is actually seen; failure stops where it is, because completing
the circle would say 'done'."
```

---

### Task 5: The script's cheap markers

**Files:**
- Modify: `carabiner:78` (add helper), `:270-275` (`reencode`), `:328-373` (`ig_gallery`), `:443` and `:451` (probe and prompt), `:504` (save)
- Test: `test/test-progress.sh` (create)

**Interfaces:**
- Consumes: the wire format from Task 1's parser.
- Produces: `::progress:probe`, `::progress:prompt`, `::progress:convert:remux|encode`, `::progress:item:<i>:<n>`, `::progress:save` on stderr.

- [ ] **Step 1: Write the failing test**

Create `test/test-progress.sh`:

```bash
#!/usr/bin/env bash
# Tests for carabiner's progress markers. No network, no downloads: the three tools are
# stubbed and injected via CARABINER_BIN, which the script puts first on PATH (gotcha #17)
# — so the stubs also shadow `osascript`, which is how the carousel dialog is faked.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$HERE/../carabiner"
pass=0; fail=0

check() {  # $1 = label, $2 = expected, $3 = actual
  if [ "$2" = "$3" ]; then
    printf '  ok   %s\n' "$1"; pass=$((pass + 1))
  else
    printf '  FAIL %s\n       expected: %s\n       actual:   %s\n' "$1" "$2" "$3"; fail=$((fail + 1))
  fi
}

contains() {  # $1 = label, $2 = needle, $3 = haystack
  case "$3" in
    *"$2"*) printf '  ok   %s\n' "$1"; pass=$((pass + 1)) ;;
    *)      printf '  FAIL %s\n       wanted to find: %s\n       in: %s\n' "$1" "$2" "$3"; fail=$((fail + 1)) ;;
  esac
}

lacks() {  # $1 = label, $2 = needle, $3 = haystack
  case "$3" in
    *"$2"*) printf '  FAIL %s\n       should NOT contain: %s\n       in: %s\n' "$1" "$2" "$3"; fail=$((fail + 1)) ;;
    *)      printf '  ok   %s\n' "$1"; pass=$((pass + 1)) ;;
  esac
}

BIN="$(mktemp -d)"; OUT="$(mktemp -d)"
trap 'rm -rf "$BIN" "$OUT"' EXIT

# --- stubs -----------------------------------------------------------------
# gallery-dl: `-g` lists slides (the carousel probe); otherwise it "downloads" into -D.
cat > "$BIN/gallery-dl" <<'STUB'
#!/usr/bin/env bash
dest=""; prev=""; listing=0
for a in "$@"; do
  [ "$prev" = "-D" ] && dest="$a"
  [ "$a" = "-g" ] && listing=1
  prev="$a"
done
if [ "$listing" -eq 1 ]; then
  echo "ytdl:https://www.instagram.com/p/CODE/1.mp4"
  echo "| https://scontent.example/continuation"
  echo "https://scontent.example/2.jpg"
  exit 0
fi
: > "$dest/01.mp4"; : > "$dest/02.jpg"
exit 0
STUB

# yt-dlp: writes the file named by -o. Task 6 replaces this with a progress-emitting one.
cat > "$BIN/yt-dlp" <<'STUB'
#!/usr/bin/env bash
out=""; prev=""
for a in "$@"; do [ "$prev" = "-o" ] && out="$a"; prev="$a"; done
: > "${out/\%(ext)s/mp4}"
exit 0
STUB

# ffmpeg: the probe form prints a stream table on stderr and exits non-zero (which is how
# the real one behaves when given no output file); the encode form writes the output.
cat > "$BIN/ffmpeg" <<'STUB'
#!/usr/bin/env bash
case " $* " in
  *" -hide_banner "*)
    echo "    Stream #0:0: Video: h264 (High), ${CARABINER_TEST_PIXFMT:-yuv420p}, 1080x1920" >&2
    echo "    Stream #0:1: Audio: aac (LC), 44100 Hz" >&2
    exit 1 ;;
esac
out="${@: -1}"; : > "$out"
exit 0
STUB

# osascript: stands in for the carousel dialog. Answer comes from the environment.
cat > "$BIN/osascript" <<'STUB'
#!/usr/bin/env bash
echo "${CARABINER_TEST_DIALOG:-This slide}"
exit 0
STUB

chmod +x "$BIN"/*

run() {  # runs carabiner headless; stdout on fd1, stderr on fd2, both captured by caller
  CARABINER_BIN="$BIN" CARABINER_NO_NOTIFY=1 \
    "$SCRIPT" -o "$OUT" "$@" < /dev/null
}

echo "test-progress.sh"

# 1. The carousel probe announces itself, and the prompt does too.
err="$(run 'https://www.instagram.com/p/ABC123/' 2>&1 >/dev/null)"
contains "probe marker emitted"  "::progress:probe"  "$err"
contains "prompt marker emitted" "::progress:prompt" "$err"

# 2. Markers never appear on stdout — that is the ✓ channel GrabRunner and the Shortcut
#    parse, and anything added to it is a change in their input.
out="$(run 'https://www.instagram.com/p/ABC123/' 2>/dev/null)"
lacks "stdout carries no markers" "::progress:" "$out"
contains "stdout still announces the save" "✓ " "$out"

# 3. A QuickTime-safe file remuxes; an odd pixel format re-encodes. The ring creeps at a
#    different rate for each, so the distinction has to reach the app.
err="$(run 'https://www.instagram.com/reel/ABC123/' 2>&1 >/dev/null)"
contains "remux announced" "::progress:convert:remux" "$err"

err="$(CARABINER_TEST_PIXFMT=yuv420p10le run 'https://www.instagram.com/reel/ABC123/' 2>&1 >/dev/null)"
contains "encode announced" "::progress:convert:encode" "$err"

# 4. A whole-carousel grab counts its items, so the ring advances per slide instead of
#    snapping to the end on the first file.
err="$(CARABINER_TEST_DIALOG="All 2" run 'https://www.instagram.com/p/ABC123/' 2>&1 >/dev/null)"
contains "first item announced"  "::progress:item:1:2" "$err"
contains "second item announced" "::progress:item:2:2" "$err"

# 5. The save marker closes the run.
err="$(run 'https://www.instagram.com/reel/ABC123/' 2>&1 >/dev/null)"
contains "save marker emitted" "::progress:save" "$err"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
```

- [ ] **Step 2: Run it to verify it fails**

```bash
chmod +x test/test-progress.sh && ./test/test-progress.sh
```

Expected: FAIL — every `contains` check fails, since no markers exist yet. The `lacks` and "stdout still announces the save" checks should already pass, which confirms the harness itself drives the script correctly rather than failing for an unrelated reason. **If those two also fail, fix the harness before writing any script code** — otherwise the rest of this task is written against a test that never worked.

- [ ] **Step 3: Add the `progress` helper**

In `carabiner`, after `info()` (line 78), add:

```bash
# Progress markers for the app's menu-bar ring.
#
# Always stderr, never stdout: stdout is the "✓ <filename>" channel that both GrabRunner
# and the Shortcut parse, and adding to it changes their input. Always on rather than
# gated behind an env var, because a terminal run shows nothing during a download either —
# the tools' own output is swallowed into `log="$(…)"` — so this improves that for free.
progress() { printf '::progress:%s\n' "$1" >&2; }
```

- [ ] **Step 4: Announce the convert mode**

Replace `reencode()` (lines 270-275) with:

```bash
reencode() {
  local src="$1" out="$2" silent="$3"
  local -a REENC_ARGS
  plan_reencode "$src" "$silent"
  # The ring creeps through the convert stage at a rate set by which of these it is: a
  # remux is ~0.2s, a real encode can be ~12s (gotcha #21). Same stage, very different wait.
  case " ${REENC_ARGS[*]} " in
    *" -c:v copy "*) progress "convert:remux" ;;
    *)               progress "convert:encode" ;;
  esac
  ffmpeg -y -loglevel error -i "$src" "${REENC_ARGS[@]}" "$out"
}
```

- [ ] **Step 5: Announce the probe and the prompt**

In the dispatch block, replace line 443:

```bash
            COUNT="$(ig_item_count "$URL")"
```

with:

```bash
            progress probe
            COUNT="$(ig_item_count "$URL")"
```

and replace line 451:

```bash
        case "$(ask_slide_or_all "$COUNT")" in
```

with:

```bash
        # The ring freezes here rather than creeping: what this is waiting on is the user.
        progress prompt
        case "$(ask_slide_or_all "$COUNT")" in
```

- [ ] **Step 6: Count the carousel's items**

In `ig_gallery`, replace line 351:

```bash
  local n=0 i=0 f ext base out
```

with:

```bash
  local n=0 i=0 f ext base out total
  # Counted up front so each item can be announced as "i of n" — the ring divides its
  # download+convert range by n, so without the total a five-slide carousel would snap to
  # the end of the range on the first file.
  total="$(find "$tmp" -type f ! -name '*.json' | wc -l | tr -d ' ')"
```

and, immediately after `i=$((i+1))` (line 353), add:

```bash
    progress "item:$i:$total"
```

- [ ] **Step 7: Announce the save**

Replace line 504's comment block header — insert immediately before `# Headless success → one tidy notification…`:

```bash
progress save
```

- [ ] **Step 8: Run the test to verify it passes**

```bash
bash -n carabiner && ./test/test-progress.sh && ./test/test-path.sh
```

Expected: `test-progress.sh` all checks pass; `test-path.sh` still passes (the PATH prologue it slices out must not have moved).

- [ ] **Step 9: Prove the tests can fail**

Change `progress "item:$i:$total"` to `progress "item:$i"` and re-run. Expected: both item checks FAIL. Then change `progress() { printf … >&2; }` to write to stdout and re-run. Expected: "stdout carries no markers" FAILS. Revert both.

- [ ] **Step 10: Commit**

```bash
git add carabiner test/test-progress.sh
git commit -m "feat: report grab stages for the app's progress ring

Markers on stderr, never stdout: stdout is the ✓ channel GrabRunner and the
Shortcut parse. Always on rather than env-gated, because a terminal run shows
nothing during a download either — the tools' output is swallowed into log=.

The convert marker distinguishes remux from encode because the ring creeps at
a different rate for each: ~0.2s against ~12s (gotcha #21), same stage.

test-progress.sh stubs the three tools via CARABINER_BIN, which also shadows
osascript — so the carousel dialog is fakeable and the whole thing runs
offline."
```

---

### Task 6: Real download percentages

**Files:**
- Modify: `carabiner:284-302` (`ig_video`), `:328-339` (`ig_gallery`)
- Test: `test/test-progress.sh` (append)

**Interfaces:**
- Consumes: the `progress()` helper from Task 5.
- Produces: `::progress:download:<percent>` from yt-dlp, `::progress:download` from gallery-dl.

**This is the task that can break image posts silently.** Gotcha #4's `return 10` fallback — "no video formats" meaning *try gallery-dl* — is decided from `rc` and `log`, and both change shape here.

- [ ] **Step 1: Write the failing tests**

In `test/test-progress.sh`, replace the yt-dlp stub with one that behaves like the real thing — a Python process writing progress to a pipe:

```bash
# yt-dlp: a *Python* process writing progress to stdout, which is what the real one is.
# The language matters: CPython block-buffers stdout when it is a pipe, so this stub
# reproduces the buffering trap rather than papering over it.
cat > "$BIN/yt-dlp" <<'STUB'
#!/usr/bin/env bash
out=""; prev=""
for a in "$@"; do [ "$prev" = "-o" ] && out="$a"; prev="$a"; done
if [ -n "${CARABINER_TEST_NOVIDEO:-}" ]; then
  echo "ERROR: No video formats found!" >&2
  exit 1
fi
if [ -n "${CARABINER_TEST_FAIL:-}" ]; then
  echo "ERROR: login required" >&2
  exit 1
fi
python3 -c '
import sys, time
for p in ("  0.0%", " 50.0%", "100.0%"):
    sys.stdout.write("::progress:download:%s\n" % p)
    time.sleep(0.3)
'
: > "${out/\%(ext)s/mp4}"
exit 0
STUB
```

and append these checks before the summary:

```bash
# 6. Percentages reach stderr, and not stdout.
err="$(run 'https://www.instagram.com/reel/ABC123/' 2>&1 >/dev/null)"
contains "download percent emitted" "::progress:download: 50.0%" "$err"
out="$(run 'https://www.instagram.com/reel/ABC123/' 2>/dev/null)"
lacks "stdout still carries no markers" "::progress:" "$out"

# 7. Progress must arrive LIVE. Without PYTHONUNBUFFERED=1 a Python process writing to a
#    pipe block-buffers, so every marker lands in one burst when it exits — the ring would
#    freeze for the whole download and then snap to full, which is the exact symptom this
#    feature exists to remove. Measured 2026-07-31: 1.7s of output delivered at t=1.7s.
#    The stub sleeps 0.3s between three markers, so live delivery spans >= ~0.6s.
first=""; last=""
while IFS= read -r line; do
  case "$line" in
    ::progress:download:*)
      now="$(python3 -c 'import time; print(int(time.time()*1000))')"
      [ -z "$first" ] && first="$now"
      last="$now" ;;
  esac
done < <(run 'https://www.instagram.com/reel/ABC123/' 2>&1 >/dev/null)
if [ -n "$first" ] && [ -n "$last" ] && [ "$((last - first))" -ge 400 ]; then
  check "progress arrives live, not buffered to the end" "live" "live"
else
  check "progress arrives live, not buffered to the end" "spread >= 400ms" "spread $((last - first))ms"
fi

# 8. Gotcha #4's fallback still works: "No video formats found!" means this is an image
#    post, and the caller must fall through to gallery-dl. Breaking this breaks every
#    image post, with no error that points at the pipeline change that caused it.
out="$(CARABINER_TEST_NOVIDEO=1 run 'https://www.instagram.com/p/ABC123/' 2>/dev/null)"
contains "no-video falls back to gallery-dl" "✓ " "$out"

# 9. A genuine yt-dlp failure must still fail. pipefail is what carries the exit status
#    out of the tee pipeline; without it a failed download would look like a success.
out="$(CARABINER_TEST_FAIL=1 run 'https://www.instagram.com/reel/ABC123/' 2>/dev/null)"; rc=$?
check "a failing download exits non-zero" "nonzero" "$([ "$rc" -ne 0 ] && echo nonzero || echo "zero")"
```

- [ ] **Step 2: Run it to verify the new checks fail**

```bash
./test/test-progress.sh
```

Expected: checks 6 and 7 FAIL (no percentages emitted yet). Checks 8 and 9 should already PASS — they describe behaviour that exists today, and they are here to catch this task breaking it.

- [ ] **Step 3: Make yt-dlp report progress**

In `ig_video`, replace lines 287-292:

```bash
  local -a args=(--cookies-from-browser "$BROWSER" -o "${tmp}.%(ext)s")
  [ -n "$slide" ] && args+=(--playlist-items "$slide")
  [ "$silent" -eq 1 ] && args+=(-f "bv")

  local log rc
  log="$(yt-dlp "${args[@]}" "$url" 2>&1)"; rc=$?
```

with:

```bash
  local -a args=(--cookies-from-browser "$BROWSER" -o "${tmp}.%(ext)s")
  [ -n "$slide" ] && args+=(--playlist-items "$slide")
  [ "$silent" -eq 1 ] && args+=(-f "bv")
  # Ask yt-dlp for the marker format directly rather than screen-scraping its progress bar.
  # --newline turns the \r-overwritten bar into discrete lines; --progress forces it even
  # though stdout is a pipe; --progress-delta throttles it to something a 30fps ring can use.
  args+=(--newline --progress --progress-delta 0.2
         --progress-template "download:::progress:download:%(progress._percent_str)s")

  local log rc
  # Progress has to reach the app *live*, but the whole output is still needed afterwards:
  # the "no video formats" test below (gotcha #4) reads it to decide whether this was an
  # image slide. So tee it — everything into `log`, marker lines onward to stderr as they
  # happen.
  #
  # PYTHONUNBUFFERED=1 is load-bearing, not defensive. CPython block-buffers stdout when it
  # is a pipe, so without it every marker arrives in one burst when yt-dlp exits: measured
  # 2026-07-31, 1.7s of progress delivered at t=1.7s instead of at 0.0/0.4/0.8/1.2s. The
  # ring would sit frozen for the whole download and then snap to full — the exact symptom
  # the ring exists to remove, and it would read as "the creep is broken".
  #
  # `rc=$?` is correct here and PIPESTATUS is not needed: `set -uo pipefail` (top of file)
  # carries yt-dlp's non-zero status out of the pipeline, and `grep` sits in a process
  # substitution rather than in the pipeline, so its own exit status is not part of it.
  # That last point is what makes this safe — grep exits 1 when it matches nothing, which
  # is every image post, and as a pipeline stage that 1 would become yt-dlp's exit code
  # and take gotcha #4's fallback with it.
  log="$(PYTHONUNBUFFERED=1 yt-dlp "${args[@]}" "$url" 2>&1 \
         | tee >(grep --line-buffered '^::progress:' >&2))"; rc=$?
```

- [ ] **Step 4: Announce gallery-dl's download**

In `ig_gallery`, immediately before line 339 (`log="$(gallery-dl …`), add:

```bash
  # gallery-dl has no progress output of any kind, so this stage creeps rather than
  # tracking. Deliberately left as one marker: there is nothing to report until the files
  # land, and the per-item markers below cover the part that takes the time.
  progress download
```

- [ ] **Step 5: Run the tests to verify they pass**

```bash
bash -n carabiner && ./test/test-progress.sh && ./test/test-path.sh
```

Expected: all checks pass, including 8 and 9, which were passing before and must still be.

- [ ] **Step 6: Prove the buffering test can fail**

Remove `PYTHONUNBUFFERED=1` from the `ig_video` pipeline and re-run. Expected: check 7 FAILS with a spread near 0ms while checks 6, 8 and 9 still pass — which is exactly the point: nothing else in the suite can see this. Restore it.

- [ ] **Step 7: Prove the fallback test can fail**

Change `rc=$?` to `rc=0` and re-run. Expected: check 8 FAILS (the no-video fallback never fires) and check 9 FAILS (a failing download reports success). Revert.

- [ ] **Step 8: Commit**

```bash
git add carabiner test/test-progress.sh
git commit -m "feat: stream real download percentages from yt-dlp

yt-dlp is asked for the marker format via --progress-template rather than
having its progress bar screen-scraped, and the output is tee'd — all of it
into log= for gotcha #4's no-video test, marker lines onward to stderr live.

PYTHONUNBUFFERED=1 is load-bearing. CPython block-buffers stdout into a pipe,
so without it every marker arrives in one burst at exit: 1.7s of progress
delivered at t=1.7s. The ring would freeze for the whole download and snap to
full — the symptom this feature exists to remove, wearing a disguise. The
test measures the spread between markers, which is the only assertion in the
suite that can see it.

rc=\$? is correct and PIPESTATUS is not needed: pipefail carries yt-dlp's
status, and grep sits in a process substitution so its no-match exit 1 — every
image post — never becomes yt-dlp's exit code."
```

---

### Task 7: End-to-end verification and documentation

**Files:**
- Modify: `CLAUDE.md`

- [ ] **Step 1: Rebuild and reinstall with the script change**

The app runs the *bundled* snapshot of `carabiner`, not the repo copy, so the previous tasks' script work is invisible until this happens.

```bash
export CARABINER_TEAM_ID=$(security find-certificate -a -c "Apple Development" -p \
  | openssl x509 -noout -subject | tr ',/' '\n\n' \
  | sed -nE 's/.*OU=([A-Z0-9]{10}).*/\1/p' | head -1)
./scripts/fetch-deps.sh
cd app && xcodegen generate
xcodebuild -project Carabiner.xcodeproj -scheme Carabiner -destination 'platform=macOS' test
xcodebuild -project Carabiner.xcodeproj -scheme Carabiner -configuration Debug \
  -derivedDataPath build build
pkill -x Carabiner; rm -rf ~/Applications/Carabiner.app
cp -R build/Build/Products/Debug/Carabiner.app ~/Applications/ && open ~/Applications/Carabiner.app
```

Confirm the bundled script is the new one:

```bash
grep -c '::progress:' ~/Applications/Carabiner.app/Contents/Resources/carabiner
```

Expected: `> 0`. If it is `0`, the app is running a stale snapshot and every observation below is meaningless.

- [ ] **Step 2: Grab a single reel**

Snapshot `~/Downloads` first — gallery-dl preserves Instagram's original mtime, so `ls -lt` will not show a new image:

```bash
ls -1 ~/Downloads > /tmp/before.txt
```

Open a reel on the OFF-PISTE account, fire ⌃⌥⌘V, and watch the ring. Then:

```bash
ls -1 ~/Downloads | diff /tmp/before.txt - | grep '^>'
```

Expected: the arc visibly tracks the download rather than creeping — it should move unevenly, in steps, the way a real download does. A perfectly smooth sweep means the percentages are not arriving and it is creeping through the whole band.

- [ ] **Step 3: Grab a mixed video+image carousel**

Both posts on the OFF-PISTE account mix video and images, which is what gotcha #15 requires. Open one, fire the hotkey, choose **All**.

Expected: the carousel prompt appears; the ring is **frozen** while the dialog is up; after choosing All the arc advances in per-item steps rather than one sweep.

- [ ] **Step 4: Check both appearances**

System Settings → Appearance, switch between Light and Dark with a grab running. Expected: the ring and mark both flip with the bar. No code runs for this — if it fails, `isTemplate` has been lost somewhere.

- [ ] **Step 5: Confirm the app is idle when idle**

```bash
# With no grab running, the app should be at ~0% CPU.
top -l 2 -stats pid,cpu,command | grep -i carabiner | tail -2
```

Expected: ~0.0 CPU. A non-zero figure means the timer is not being invalidated at the end of a grab.

- [ ] **Step 6: Update CLAUDE.md**

Add to the "Where things are" paragraph, alongside `test-path.sh`:

```
`test/test-progress.sh` covers the progress markers offline (stubbed tools via
`CARABINER_BIN`, no network)
```

Add a new gotcha at the end of the "Known gotchas" list:

```markdown
23. **A Python tool writing to a pipe block-buffers, so "live" output is not live.**
    `yt-dlp` and `gallery-dl` are CPython (PyInstaller) builds. When their stdout is a
    pipe rather than a terminal, CPython block-buffers it — so the progress markers the
    menu-bar ring depends on all arrive in a single burst when the process *exits*.
    Measured 2026-07-31: three markers written 0.4s apart were delivered at 0.0/0.4/0.8s
    with `PYTHONUNBUFFERED=1` and all three at t=1.7s without it. The ring would sit
    frozen for a whole download and then snap to full, which is precisely the symptom the
    ring exists to remove — and it reads as "the creep is broken", not as buffering, so it
    sends you to the wrong file. `ig_video` sets `PYTHONUNBUFFERED=1` on the yt-dlp call
    for this reason and no other. `test/test-progress.sh` measures the *spread* between
    markers rather than their presence, because presence passes either way; it is the only
    assertion in the suite that can see this.

    A second, smaller tooth from the same change: `rc=$?` after
    `log="$(yt-dlp … | tee >(grep …))"` is correct, and `PIPESTATUS` is not needed.
    `set -uo pipefail` carries yt-dlp's status out of the pipeline, and `grep` lives in a
    *process substitution* rather than a pipeline stage — which is load-bearing, because
    `grep` exits 1 when it matches nothing (every image post), and as a real stage that 1
    would become yt-dlp's exit code and silently take gotcha #4's image fallback with it.
```

Add to the "Current state — BUILT" description of `app/`:

```
While a grab runs, the status item draws a progress ring around the mark (which shrinks
to 10pt for the duration) — driven by `::progress:` markers the script writes to stderr,
not by a guess. See `docs/superpowers/specs/2026-07-31-menu-bar-progress-ring-design.md`.
```

- [ ] **Step 7: Commit**

```bash
git add CLAUDE.md
git commit -m "docs: record the progress-ring protocol and the buffering gotcha

Gotcha #23: CPython block-buffers stdout into a pipe, so without
PYTHONUNBUFFERED=1 every progress marker arrives at once when the tool exits.
It reads as a broken animation rather than as buffering, which sends you to
the wrong file — and only a test that measures the spread between markers can
see it, since presence passes either way."
```

---

## Self-Review

**Spec coverage:**

| Spec requirement | Task |
|---|---|
| Wire protocol on stderr, always on | 5, 6 |
| `probe` / `prompt` / `save` markers | 5 |
| `convert:remux` / `convert:encode` | 5 |
| `item:i:n` | 5 |
| `download:<pct>` from yt-dlp | 6 |
| `download` (no pct) from gallery-dl | 6 |
| Arc bands, creep, monotonic clamp, prompt freeze | 1 |
| Item subdivision of the 12–96% range | 1 |
| Geometry: 22pt / 10pt / 1.5pt / 12% | 2 |
| Template rendering preserved | 2 |
| Clockwise from 12 o'clock, round cap | 2 |
| Complete → hold 0.5s → fade; failure fades immediately | 4 |
| 30fps, only while busy | 4 |
| Stream stderr; markers out of the failure reason | 3 |
| `test-progress.sh` assertions 1–6 | 5 (1,2), 6 (3,4,5,6) |
| Unit tests for parser/bands and GrabRunner | 1, 3 |
| Manual: mixed carousel, both appearances | 7 |
| ffmpeg real percentages **out of scope** | — correctly absent |

**Placeholder scan:** none — every code step carries the actual code, and every test step carries the actual assertions.

**Type consistency:** `ProgressEvent`, `ConvertMode`, `ProgressStage`, `ProgressParser.parse`, `ProgressParser.marker`, `LineBuffer.append`/`flush`, `ProgressModel.apply`/`finish`/`target`/`stage`, `StatusIconRenderer.idle`/`busy`/`mark`, `RingAnimator.begin`/`handle`/`finish`, `GrabRunner.onProgress` — each is defined in exactly one task and used with the same name and signature in every later one. Checked.

**One correction carried in from the spec:** the spec's original `rc=${PIPESTATUS[0]}` was replaced with `rc=$?` after testing both. `PIPESTATUS` happened to work through the command substitution on this bash, but relying on that is fragile, and `pipefail` plus grep-in-a-process-substitution is both simpler and provably correct. The spec has been updated to match.
