# First-run intro — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A three-card explainer over the brand canvas on first run that says what Carabiner is and how to ask it for a file, ending in the existing permissions panel.

**Architecture:** Four small units under `app/Carabiner/MainWindow/Intro/` — copy as data (`IntroCard`), paging state (`IntroModel`), a defaults gate (`IntroGate`), and presentation (`IntroView`). `MainViewModel` holds `intro` and owns the two exit transitions; `MainWindowController` owns everything that touches `UserDefaults` and the settings handoff. No new window: the intro is a layer inside the main window, so Dock-click and reopen behaviour are untouched.

**Tech Stack:** Swift 5, SwiftUI + AppKit, XCTest, XcodeGen. No new dependencies.

**Spec:** `docs/superpowers/specs/2026-08-26-first-run-intro-design.md`

## Global Constraints

- **Deployment target is macOS 13.0.** No macOS 26-only API in this feature — the intro must render identically on 13–15. (`.glassEffect` is 26-only and is NOT used here.)
- **Styling goes through `Brand` only.** `Brand.mono(_:)` for type, `Brand.yellow` for the accent, `Brand.backgroundImage` for the canvas. No literal hex, no font name, no resource path anywhere in this feature.
- **Copy is fixed by the spec.** The three cards' text is reproduced verbatim in Task 1 and must not be paraphrased during implementation.
- **Two defaults keys, both exact:** the new `"introShown"` and the existing `"onboardingShown"` (`MainWindowController.settingsShownDefaultsKey`). Never reuse one for the other.
- **Build outside iCloud.** Every `xcodebuild` in this plan uses `-derivedDataPath /tmp/carabiner-dd` (build) or `/tmp/carabiner-test-dd` (test). Building into the repo races the iCloud file provider and fails on "resource fork, Finder information, or similar detritus".
- **Every build signs**, so `CARABINER_TEAM_ID` must be exported first (command given in each task).
- **`app/Carabiner/Info.plist` and `Carabiner.xcodeproj` are generated.** Edit `app/project.yml`, never them. New source files are swept in by directory, so `xcodegen generate` must run once after Task 1 creates the new folder.

---

### Task 1: The three cards, as data

**Files:**
- Create: `app/Carabiner/MainWindow/Intro/IntroCard.swift`
- Test: `app/CarabinerTests/IntroCardTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces: `struct IntroCard: Equatable` with `let title: String`, `let lines: [IntroCard.Line]`, and `static let all: [IntroCard]`; `struct IntroCard.Line: Equatable` with `let lead: String?`, `let text: String`.

- [ ] **Step 1: Write the failing test**

Create `app/CarabinerTests/IntroCardTests.swift`:

```swift
import XCTest
@testable import Carabiner

final class IntroCardTests: XCTestCase {
    func testThereAreExactlyThreeCards() {
        XCTAssertEqual(IntroCard.all.count, 3)
    }

    func testEveryCardHasATitleAndAtLeastOneLine() {
        for card in IntroCard.all {
            XCTAssertFalse(card.title.isEmpty, "a card has no title")
            XCTAssertFalse(card.lines.isEmpty, "\(card.title) has no body")
            for line in card.lines {
                XCTAssertFalse(line.text.isEmpty, "\(card.title) has an empty line")
                // A lead-in is optional, but an empty one is a formatting bug: it would
                // render as a bold gap before the sentence.
                XCTAssertNotEqual(line.lead, "", "\(card.title) has an empty lead-in")
            }
        }
    }

    /// The second card is the only reason a user learns the in-page button exists, and
    /// the third is the only place "nothing is uploaded" is ever said. Pin both so a
    /// copy edit that drops them fails loudly rather than quietly.
    func testTheLoadBearingCopyIsPresent() {
        let all = IntroCard.all.flatMap(\.lines).map(\.text).joined(separator: " ")
        XCTAssertTrue(all.contains("beside Save"), "card 2 no longer says where the button is")
        XCTAssertTrue(all.contains("⌃⌥⌘V"), "card 2 no longer names the hotkey")
        XCTAssertTrue(all.contains("nothing is uploaded"), "card 3 no longer says it stays local")
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

```bash
export CARABINER_TEAM_ID=$(security find-certificate -a -c "Apple Development" -p \
  | openssl x509 -noout -subject | tr ',/' '\n\n' \
  | sed -nE 's/.*OU=([A-Z0-9]{10}).*/\1/p' | head -1)
cd app && xcodegen generate && xcodebuild -project Carabiner.xcodeproj -scheme Carabiner \
  -destination 'platform=macOS' -derivedDataPath /tmp/carabiner-test-dd test 2>&1 | tail -20
```

Expected: FAIL to compile — "cannot find 'IntroCard' in scope".

- [ ] **Step 3: Write minimal implementation**

Create `app/Carabiner/MainWindow/Intro/IntroCard.swift`:

```swift
import Foundation

/// The first-run explainer's copy, as data. Deliberately not in the view: the words are
/// the feature, and keeping them here makes them testable and diffable on their own.
/// Wording is fixed by docs/superpowers/specs/2026-08-26-first-run-intro-design.md —
/// change it there first.
struct IntroCard: Equatable {
    /// One body line. `lead` is an optional bold opener ("On Instagram") followed by the
    /// sentence; cards 1 and 3 use plain lines with no lead.
    struct Line: Equatable {
        let lead: String?
        let text: String

        init(_ text: String) {
            self.lead = nil
            self.text = text
        }

        init(lead: String, _ text: String) {
            self.lead = lead
            self.text = text
        }
    }

    let title: String
    let lines: [Line]

    static let all: [IntroCard] = [
        IntroCard(
            title: "PASTE A LINK,\nGET THE FILE.",
            lines: [
                Line("An Instagram video or photo becomes a clean file in your Downloads "
                     + "— one that QuickTime actually opens."),
                Line("Carabiner does the awkward part: Instagram's videos aren't files, "
                     + "they're streams, and what you can save by hand usually won't play."),
            ]),
        IntroCard(
            title: "THREE WAYS TO ASK.",
            lines: [
                Line(lead: "On Instagram",
                     "a small Carabiner button sits beside Save on every post, in Chrome "
                     + "and Safari."),
                Line(lead: "From anywhere", "open a post and press ⌃⌥⌘V."),
                Line(lead: "Here", "paste a link into this window and hit GRAB."),
            ]),
        IntroCard(
            title: "WHAT TO EXPECT.",
            lines: [
                Line("Carousels ask first: this slide, or all of them. Files land in "
                     + "~/Downloads, named after the post. A banner tells you when it's done."),
                Line("It all runs on your Mac, using your own browser session — nothing "
                     + "is uploaded, and no account but yours is involved."),
            ]),
    ]
}
```

- [ ] **Step 4: Run test to verify it passes**

```bash
cd app && xcodebuild -project Carabiner.xcodeproj -scheme Carabiner \
  -destination 'platform=macOS' -derivedDataPath /tmp/carabiner-test-dd test 2>&1 \
  | grep -E "IntroCardTests|Executed [0-9]+ tests|\*\* TEST"
```

Expected: PASS, three `IntroCardTests` cases.

- [ ] **Step 5: Commit**

```bash
git add app/Carabiner/MainWindow/Intro/IntroCard.swift app/CarabinerTests/IntroCardTests.swift
git commit -m "feat(app): the first-run explainer's three cards, as data"
```

---

### Task 2: The defaults gate

**Files:**
- Create: `app/Carabiner/MainWindow/Intro/IntroGate.swift`
- Test: `app/CarabinerTests/IntroGateTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces: `enum IntroGate` with `static let shownDefaultsKey = "introShown"`, `static func shouldShow(_ defaults: UserDefaults) -> Bool`, `static func markSeen(_ defaults: UserDefaults)`.

- [ ] **Step 1: Write the failing test**

Create `app/CarabinerTests/IntroGateTests.swift`:

```swift
import XCTest
@testable import Carabiner

final class IntroGateTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        // A scratch suite, not .standard: these tests must not read or write the real
        // app's key, and must not leak state into each other.
        suiteName = "carabiner-intro-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    func testShowsWhenNeverSeen() {
        XCTAssertTrue(IntroGate.shouldShow(defaults))
    }

    func testDoesNotShowOnceSeen() {
        IntroGate.markSeen(defaults)
        XCTAssertFalse(IntroGate.shouldShow(defaults))
    }

    func testSeenSurvivesAFreshRead() {
        IntroGate.markSeen(defaults)
        let reread = UserDefaults(suiteName: suiteName)!
        XCTAssertFalse(IntroGate.shouldShow(reread), "markSeen did not persist")
    }

    /// The intro key must be its own. onboardingShown is already true on every 0.1.x and
    /// 0.2.0 install; reusing it would silently exclude exactly the upgraders this
    /// explainer is for.
    func testDoesNotReadTheOnboardingKey() {
        defaults.set(true, forKey: MainWindowController.settingsShownDefaultsKey)
        XCTAssertTrue(IntroGate.shouldShow(defaults),
                      "the intro gate is reading onboardingShown")
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

```bash
cd app && xcodebuild -project Carabiner.xcodeproj -scheme Carabiner \
  -destination 'platform=macOS' -derivedDataPath /tmp/carabiner-test-dd test 2>&1 | tail -20
```

Expected: FAIL to compile — "cannot find 'IntroGate' in scope".

- [ ] **Step 3: Write minimal implementation**

Create `app/Carabiner/MainWindow/Intro/IntroGate.swift`:

```swift
import Foundation

/// Whether this person has seen the first-run explainer.
///
/// Takes a `UserDefaults` instance rather than reaching for `.standard`, so the real
/// functions are testable against a scratch suite instead of being tested around.
///
/// The key is deliberately NOT `onboardingShown`: that one means "has been offered
/// setup" and is already true on every 0.1.x and 0.2.0 install, so reusing it would hide
/// the intro from every upgrading teammate — the people the in-page Instagram button is
/// newest to.
enum IntroGate {
    static let shownDefaultsKey = "introShown"

    static func shouldShow(_ defaults: UserDefaults) -> Bool {
        !defaults.bool(forKey: shownDefaultsKey)
    }

    static func markSeen(_ defaults: UserDefaults) {
        defaults.set(true, forKey: shownDefaultsKey)
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

```bash
cd app && xcodebuild -project Carabiner.xcodeproj -scheme Carabiner \
  -destination 'platform=macOS' -derivedDataPath /tmp/carabiner-test-dd test 2>&1 \
  | grep -E "IntroGateTests|Executed [0-9]+ tests|\*\* TEST"
```

Expected: PASS, four `IntroGateTests` cases.

- [ ] **Step 5: Mutation check — prove the tests have teeth**

Temporarily change `shouldShow` to read the wrong key:

```swift
    static func shouldShow(_ defaults: UserDefaults) -> Bool {
        !defaults.bool(forKey: MainWindowController.settingsShownDefaultsKey)
    }
```

Re-run the tests. Expected: `testDoesNotReadTheOnboardingKey` FAILS. Then revert to the real implementation and confirm green again. A gate whose tests pass with the gate broken is theatre — this repo has shipped that before.

- [ ] **Step 6: Commit**

```bash
git add app/Carabiner/MainWindow/Intro/IntroGate.swift app/CarabinerTests/IntroGateTests.swift
git commit -m "feat(app): introShown gate, on its own key and its own tests"
```

---

### Task 3: Paging state

**Files:**
- Create: `app/Carabiner/MainWindow/Intro/IntroModel.swift`
- Test: `app/CarabinerTests/IntroModelTests.swift`

**Interfaces:**
- Consumes: `IntroCard.all` from Task 1.
- Produces: `final class IntroModel: ObservableObject` with `@Published private(set) var index: Int`, `let cards: [IntroCard]`, `init(cards: [IntroCard] = IntroCard.all)`, `var card: IntroCard`, `var isLast: Bool`, `func next()`, `func back()`, `func go(to: Int)`.

- [ ] **Step 1: Write the failing test**

Create `app/CarabinerTests/IntroModelTests.swift`:

```swift
import XCTest
@testable import Carabiner

final class IntroModelTests: XCTestCase {
    func testStartsOnTheFirstCard() {
        let model = IntroModel()
        XCTAssertEqual(model.index, 0)
        XCTAssertEqual(model.card, IntroCard.all[0])
        XCTAssertFalse(model.isLast)
    }

    func testNextPagesForwardAndStopsAtTheEnd() {
        let model = IntroModel()
        model.next()
        XCTAssertEqual(model.index, 1)
        model.next()
        XCTAssertEqual(model.index, 2)
        XCTAssertTrue(model.isLast)
        model.next()
        XCTAssertEqual(model.index, 2, "next() past the last card must be a no-op")
    }

    func testBackPagesAndStopsAtZero() {
        let model = IntroModel()
        model.next()
        model.back()
        XCTAssertEqual(model.index, 0)
        model.back()
        XCTAssertEqual(model.index, 0, "back() before the first card must be a no-op")
    }

    func testGoToJumpsAndIgnoresOutOfRange() {
        let model = IntroModel()
        model.go(to: 2)
        XCTAssertEqual(model.index, 2)
        model.go(to: 7)
        XCTAssertEqual(model.index, 2, "an out-of-range dot must not move the intro")
        model.go(to: -1)
        XCTAssertEqual(model.index, 2)
    }

    func testIsLastTracksTheInjectedCardCount() {
        let model = IntroModel(cards: [IntroCard.all[0]])
        XCTAssertTrue(model.isLast, "a one-card intro is on its last card immediately")
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

```bash
cd app && xcodebuild -project Carabiner.xcodeproj -scheme Carabiner \
  -destination 'platform=macOS' -derivedDataPath /tmp/carabiner-test-dd test 2>&1 | tail -20
```

Expected: FAIL to compile — "cannot find 'IntroModel' in scope".

- [ ] **Step 3: Write minimal implementation**

Create `app/Carabiner/MainWindow/Intro/IntroModel.swift`:

```swift
import Foundation

/// Which explainer card is showing. Paging only — it knows nothing about UserDefaults,
/// the window, or what happens when the intro ends. Main thread only, like every model
/// in this app.
final class IntroModel: ObservableObject {
    @Published private(set) var index = 0
    let cards: [IntroCard]

    /// Cards are injectable so the bounds tests don't depend on the shipped copy count.
    init(cards: [IntroCard] = IntroCard.all) {
        self.cards = cards
    }

    var card: IntroCard { cards[index] }
    var isLast: Bool { index >= cards.count - 1 }

    func next() { if !isLast { index += 1 } }
    func back() { if index > 0 { index -= 1 } }

    /// A step dot. Out-of-range is ignored rather than clamped: a dot that cannot exist
    /// was not clicked, and silently landing somewhere else would be worse than nothing.
    func go(to target: Int) {
        guard cards.indices.contains(target) else { return }
        index = target
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

```bash
cd app && xcodebuild -project Carabiner.xcodeproj -scheme Carabiner \
  -destination 'platform=macOS' -derivedDataPath /tmp/carabiner-test-dd test 2>&1 \
  | grep -E "IntroModelTests|Executed [0-9]+ tests|\*\* TEST"
```

Expected: PASS, five `IntroModelTests` cases.

- [ ] **Step 5: Commit**

```bash
git add app/Carabiner/MainWindow/Intro/IntroModel.swift app/CarabinerTests/IntroModelTests.swift
git commit -m "feat(app): intro paging state with bounded next/back/go"
```

---

### Task 4: The two exits, in MainViewModel

**Files:**
- Modify: `app/Carabiner/MainWindow/MainViewModel.swift` (add published state, hooks and two methods near `collapsePanel()`, around line 46)
- Test: `app/CarabinerTests/MainViewModelIntroTests.swift`

**Interfaces:**
- Consumes: `IntroModel` from Task 3.
- Produces: on `MainViewModel` — `@Published var intro: IntroModel?`, `var markIntroSeen: () -> Void`, `var onIntroSkipped: (() -> Void)?`, `var onIntroFinished: (() -> Void)?`, `func showIntro()`, `func skipIntro()`, `func finishIntro()`.

Why the hooks: the view must not touch `UserDefaults`, and the model must not know about windows. `MainWindowController` (Task 6) supplies both closures.

- [ ] **Step 1: Write the failing test**

Create `app/CarabinerTests/MainViewModelIntroTests.swift`:

```swift
import XCTest
@testable import Carabiner

final class MainViewModelIntroTests: XCTestCase {
    private func makeModel() -> MainViewModel {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("carabiner-intro-vm-\(UUID().uuidString)")
        return MainViewModel(history: GrabHistoryStore(directory: directory))
    }

    func testShowIntroStartsOnTheFirstCard() {
        let model = makeModel()
        model.showIntro()
        XCTAssertNotNil(model.intro)
        XCTAssertEqual(model.intro?.index, 0)
    }

    func testShowIntroAlwaysRestartsAtTheFirstCard() {
        let model = makeModel()
        model.showIntro()
        model.intro?.next()
        model.showIntro()
        XCTAssertEqual(model.intro?.index, 0, "reopening must not resume mid-explainer")
    }

    func testSkipMarksSeenClearsTheIntroAndFiresTheSkipHook() {
        let model = makeModel()
        var seen = 0, skipped = 0, finished = 0
        model.markIntroSeen = { seen += 1 }
        model.onIntroSkipped = { skipped += 1 }
        model.onIntroFinished = { finished += 1 }
        model.showIntro()
        model.skipIntro()
        XCTAssertNil(model.intro)
        XCTAssertEqual(seen, 1)
        XCTAssertEqual(skipped, 1)
        XCTAssertEqual(finished, 0, "skip must not run the settings handoff")
    }

    func testFinishMarksSeenClearsTheIntroAndFiresTheFinishHook() {
        let model = makeModel()
        var seen = 0, skipped = 0, finished = 0
        model.markIntroSeen = { seen += 1 }
        model.onIntroSkipped = { skipped += 1 }
        model.onIntroFinished = { finished += 1 }
        model.showIntro()
        model.finishIntro()
        XCTAssertNil(model.intro)
        XCTAssertEqual(seen, 1)
        XCTAssertEqual(finished, 1)
        XCTAssertEqual(skipped, 0, "finish must not also run the skip fallthrough")
    }

    /// Closing the window while the intro is up is a third exit. It must mark seen too,
    /// or the explainer reappears every launch for anyone who leaves by that door.
    func testSkipIsSafeToCallWithNoIntroShowing() {
        let model = makeModel()
        var seen = 0
        model.markIntroSeen = { seen += 1 }
        model.skipIntro()
        XCTAssertNil(model.intro)
        XCTAssertEqual(seen, 0, "nothing to mark seen when no intro was showing")
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

```bash
cd app && xcodebuild -project Carabiner.xcodeproj -scheme Carabiner \
  -destination 'platform=macOS' -derivedDataPath /tmp/carabiner-test-dd test 2>&1 | tail -20
```

Expected: FAIL to compile — "value of type 'MainViewModel' has no member 'showIntro'".

- [ ] **Step 3: Write minimal implementation**

In `app/Carabiner/MainWindow/MainViewModel.swift`, add to the published state next to `panel` (after the `panel` declaration, around line 19):

```swift
    /// The first-run explainer, nil when it is not showing. A fresh IntroModel per
    /// showing, so reopening from the menu always starts at card 1.
    @Published var intro: IntroModel?
```

Add the hooks beside the existing `onGrab` / `isBusyElsewhere` declarations (around line 33):

```swift
    /// Records that the explainer has been seen. Wired by MainWindowController to
    /// IntroGate; defaulted here so a model built in a test writes nothing.
    var markIntroSeen: () -> Void = {}
    /// SKIP. MainWindowController uses it to fall through to the first-launch settings
    /// panel when this install has never been offered setup.
    var onIntroSkipped: (() -> Void)?
    /// SET UP PERMISSIONS. MainWindowController opens the settings panel.
    var onIntroFinished: (() -> Void)?
```

Add the three methods after `collapsePanel()` (around line 49):

```swift
    /// First launch and the "How Carabiner works" menu item.
    func showIntro() {
        intro = IntroModel()
    }

    /// SKIP, and closing the window while the explainer is up. Marks it seen — an exit
    /// by an unexpected door must not make the intro reappear next launch.
    func skipIntro() {
        guard intro != nil else { return }
        intro = nil
        markIntroSeen()
        onIntroSkipped?()
    }

    /// SET UP PERMISSIONS on the last card.
    func finishIntro() {
        guard intro != nil else { return }
        intro = nil
        markIntroSeen()
        onIntroFinished?()
    }
```

- [ ] **Step 4: Run test to verify it passes**

```bash
cd app && xcodebuild -project Carabiner.xcodeproj -scheme Carabiner \
  -destination 'platform=macOS' -derivedDataPath /tmp/carabiner-test-dd test 2>&1 \
  | grep -E "MainViewModelIntroTests|Executed [0-9]+ tests|\*\* TEST"
```

Expected: PASS, five `MainViewModelIntroTests` cases.

- [ ] **Step 5: Commit**

```bash
git add app/Carabiner/MainWindow/MainViewModel.swift app/CarabinerTests/MainViewModelIntroTests.swift
git commit -m "feat(app): intro state and its two exits in MainViewModel"
```

---

### Task 5: The explainer view

**Files:**
- Create: `app/Carabiner/MainWindow/Intro/IntroView.swift`
- Modify: `app/Carabiner/MainWindow/MainView.swift` (the `body` ZStack, around line 22)

**Interfaces:**
- Consumes: `IntroModel`, `IntroCard`, `MainViewModel.intro/skipIntro()/finishIntro()`, `Brand`.
- Produces: `struct IntroView: View` with `init(intro: IntroModel, onSkip: @escaping () -> Void, onFinish: @escaping () -> Void)`.

No unit test: this is presentation with no decisions of its own (the one decision, paging, is Task 3's and already tested). It is verified by screenshot in Step 4 — including at the 640×420 minimum, where clipped copy is the real risk.

- [ ] **Step 1: Write the view**

Create `app/Carabiner/MainWindow/Intro/IntroView.swift`:

```swift
import SwiftUI

/// The first-run explainer: one card at a time over the brand canvas. Presentation only
/// — the copy is IntroCard, the paging is IntroModel, "have they seen it" is IntroGate,
/// and what happens on exit is MainViewModel's.
///
/// It draws no background of its own: MainView keeps the canvas behind it, so the
/// artwork is the same one the app opens on afterwards.
struct IntroView: View {
    @ObservedObject var intro: IntroModel
    let onSkip: () -> Void
    let onFinish: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            topRow
            Spacer(minLength: 20)
            Text(intro.card.title)
                .font(Brand.mono(24)).kerning(1)
                .foregroundStyle(.black.opacity(0.85))
                .fixedSize(horizontal: false, vertical: true)
                .padding(.bottom, 20)
            VStack(alignment: .leading, spacing: 12) {
                ForEach(Array(intro.card.lines.enumerated()), id: \.offset) { _, line in
                    lineView(line)
                }
            }
            Spacer(minLength: 20)
            bottomRow
        }
        .frame(maxWidth: 540, alignment: .leading)
        .padding(.horizontal, 44)
        // Clear of the traffic lights the transparent titlebar draws over the canvas —
        // the same 48pt SideRail uses.
        .padding(.top, 48)
        .padding(.bottom, 28)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .focusable()
        .onMoveCommand { direction in
            switch direction {
            case .right: intro.next()
            case .left:  intro.back()
            default:     break
            }
        }
        .onExitCommand { onSkip() }
    }

    /// Dots left, SKIP right.
    private var topRow: some View {
        HStack {
            HStack(spacing: 7) {
                ForEach(intro.cards.indices, id: \.self) { i in
                    Button { intro.go(to: i) } label: {
                        Circle()
                            .fill(i == intro.index ? Color.black.opacity(0.55)
                                                   : Color.black.opacity(0.18))
                            .frame(width: 6, height: 6)
                    }
                    .buttonStyle(.plain)
                    .help("Step \(i + 1)")
                }
            }
            Spacer()
            Button(action: onSkip) {
                Text("SKIP").font(Brand.mono(10)).kerning(1)
                    .foregroundStyle(.black.opacity(0.4))
            }
            .buttonStyle(.plain)
            .help("Skip the introduction")
        }
    }

    /// The primary button: NEXT until the last card, then the handoff to setup.
    private var bottomRow: some View {
        HStack {
            Spacer()
            Button(action: { intro.isLast ? onFinish() : intro.next() }) {
                Text(intro.isLast ? "SET UP PERMISSIONS →" : "NEXT")
                    .font(Brand.mono(12)).kerning(1)
                    .foregroundStyle(.black)
                    .padding(.horizontal, 24)
                    .frame(height: 34)
                    .background(Capsule().fill(Brand.yellow))
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.defaultAction)
        }
    }

    @ViewBuilder
    private func lineView(_ line: IntroCard.Line) -> some View {
        if let lead = line.lead {
            // `foregroundColor` is deprecated but REQUIRED here: Text.foregroundStyle is
            // macOS 14+, and this app's floor is 13. "Modernising" this line breaks the
            // build outright. The concatenation itself is load-bearing too — a bold lead
            // and a wrapping sentence must share one text run, which an HStack cannot do.
            (Text(lead + " — ").font(Brand.mono(12)).foregroundColor(.black.opacity(0.75))
             + Text(line.text).font(Brand.mono(12)).foregroundColor(.black.opacity(0.55)))
                .fixedSize(horizontal: false, vertical: true)
        } else {
            Text(line.text)
                .font(Brand.mono(12))
                .foregroundStyle(.black.opacity(0.6))
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
```

- [ ] **Step 2: Branch MainView to it**

In `app/Carabiner/MainWindow/MainView.swift`, replace the three lines inside the root `ZStack` that render the canvas furniture — currently:

```swift
            content
            furniture
            SideRail(model: model, history: history, settings: settings)
```

with:

```swift
            // The intro is a full-canvas takeover: while it is up there is exactly one
            // thing to do, so the grab box, the corner furniture and the rail are not
            // merely covered — they are not built.
            if let intro = model.intro {
                // No settings.refreshAll() here: finishIntro fires onIntroFinished, which
                // MainWindowController wires to showSettings() — and that already
                // refreshes. Refreshing in both places would re-run every live
                // permission check twice on the handoff.
                IntroView(intro: intro,
                          onSkip: { model.skipIntro() },
                          onFinish: { model.finishIntro() })
            } else {
                content
                furniture
                SideRail(model: model, history: history, settings: settings)
            }
```

- [ ] **Step 3: Build**

```bash
export CARABINER_TEAM_ID=$(security find-certificate -a -c "Apple Development" -p \
  | openssl x509 -noout -subject | tr ',/' '\n\n' \
  | sed -nE 's/.*OU=([A-Z0-9]{10}).*/\1/p' | head -1)
cd app && xcodegen generate && xcodebuild -project Carabiner.xcodeproj -scheme Carabiner \
  -configuration Debug -derivedDataPath /tmp/carabiner-dd build 2>&1 \
  | grep -E "^/Users.*error:|\*\* BUILD"
```

Expected: `** BUILD SUCCEEDED **` with no errors from our files.

- [ ] **Step 4: Verify visually at both window sizes**

The intro has no call site yet (Task 6 adds them), so drive it from the one that exists — the Dock-click window — by temporarily calling `model.showIntro()` at the end of `MainWindowController.init`. Install and look:

```bash
pkill -x Carabiner; rm -rf ~/Applications/Carabiner.app
cp -R /tmp/carabiner-dd/Build/Products/Debug/Carabiner.app ~/Applications/
open ~/Applications/Carabiner.app && sleep 2 && open -a ~/Applications/Carabiner.app
osascript -e 'tell application "Carabiner" to activate'
osascript -e 'tell application "System Events" to tell process "Carabiner" to get {size, position} of window 1'
# screencapture -o -x -R<x>,<y>,<w>,<h> /tmp/intro-720.png   using the frame printed above
```

Check on each of the three cards, then resize the window to its 640×420 minimum and check again:
1. No clipped or truncated copy at 640×420 — card 1's body is the longest and is the one that will break first.
2. The dots and SKIP clear the traffic lights.
3. NEXT reads `SET UP PERMISSIONS →` on card 3 only.
4. Return pages forward; ← / → page both ways; Esc skips.

Then **remove the temporary `showIntro()` call** before committing.

- [ ] **Step 5: Commit**

```bash
git add app/Carabiner/MainWindow/Intro/IntroView.swift app/Carabiner/MainWindow/MainView.swift
git commit -m "feat(app): the first-run explainer view, over the brand canvas"
```

---

### Task 6: Call sites — launch, menu, window

**Files:**
- Modify: `app/Carabiner/MainWindow/MainWindowController.swift` (init wiring around line 55; a new `showIntro()` beside `showSettings()` around line 74; `windowWillClose`)
- Modify: `app/Carabiner/MenuBarController.swift` (menu construction around line 42; a new `@objc func showIntro()` beside `showSettings()` around line 79)
- Modify: `app/Carabiner/App.swift` (the first-launch branch, line 89)

**Interfaces:**
- Consumes: `IntroGate` (Task 2), `MainViewModel.showIntro/skipIntro/finishIntro` (Task 4).
- Produces: `MainWindowController.showIntro()`, `MenuBarController.showIntro()`.

- [ ] **Step 1: Wire the hooks in MainWindowController**

In `init`, immediately after the existing `settingsModel.onBeginHotkeyTest = …` line:

```swift
        // Everything that touches UserDefaults lives here, not in the view: the model
        // gets closures, so a model built in a test writes nothing.
        model.markIntroSeen = { IntroGate.markSeen(.standard) }
        model.onIntroFinished = { [weak self] in self?.showSettings() }
        // SKIP still lands a fresh install on the permissions panel — the 0.2.0
        // first-launch rule, unchanged. Skipping the explainer must not be a way to end
        // up with a silently non-working app.
        model.onIntroSkipped = { [weak self] in
            guard let self else { return }
            if !UserDefaults.standard.bool(forKey: Self.settingsShownDefaultsKey) {
                self.showSettings()
            }
        }
```

- [ ] **Step 2: Add showIntro() and close the third exit**

Add beside `showSettings()`:

```swift
    /// First launch and the "How Carabiner works" menu item: the window with the
    /// explainer over the canvas. Always starts at card 1 (showIntro builds a fresh
    /// IntroModel), and does not touch introShown — dismissing it does that.
    func showIntro() {
        model.showIntro()
        show()
    }
```

Then find `windowWillClose` in the same file and add, as its first statement:

```swift
        // Closing the window is the third way out of the explainer. Mark it seen, or it
        // reappears next launch for anyone who leaves by that door.
        model.skipIntro()
```

- [ ] **Step 3: Add the menu item**

In `MenuBarController.init`, between `grabItem` and `setupItem`:

```swift
        let introItem = NSMenuItem(title: "How Carabiner works", action: #selector(showIntro), keyEquivalent: "")
        introItem.target = self
        menu.addItem(introItem)
```

And beside `showSettings()`:

```swift
    /// The status menu's "How Carabiner works". Same lazy construction as
    /// showMainWindow(); reopening always starts at card 1.
    @objc func showIntro() {
        showMainWindow()
        mainWindow?.showIntro()
    }
```

- [ ] **Step 4: Branch the launch check**

In `App.swift`, replace the existing first-launch block (line 89):

```swift
        if !UserDefaults.standard.bool(forKey: MainWindowController.settingsShownDefaultsKey) {
            controller.showSettings()
        }
```

with:

```swift
        // The explainer comes first on a machine that has never seen it — including an
        // upgrade from 0.1.x/0.2.0, where the in-page Instagram button is the newest
        // thing and the least discoverable. Its own exits then decide whether the
        // permissions panel opens (SET UP PERMISSIONS always; SKIP only on an install
        // that has never been offered setup).
        if IntroGate.shouldShow(.standard) {
            controller.showIntro()
        } else if !UserDefaults.standard.bool(forKey: MainWindowController.settingsShownDefaultsKey) {
            controller.showSettings()
        }
```

- [ ] **Step 5: Build and run the whole suite**

```bash
export CARABINER_TEAM_ID=$(security find-certificate -a -c "Apple Development" -p \
  | openssl x509 -noout -subject | tr ',/' '\n\n' \
  | sed -nE 's/.*OU=([A-Z0-9]{10}).*/\1/p' | head -1)
cd app && xcodegen generate \
  && xcodebuild -project Carabiner.xcodeproj -scheme Carabiner -destination 'platform=macOS' \
     -derivedDataPath /tmp/carabiner-test-dd test 2>&1 | grep -E "Executed [0-9]+ tests|\*\* TEST" \
  && xcodebuild -project Carabiner.xcodeproj -scheme Carabiner -configuration Debug \
     -derivedDataPath /tmp/carabiner-dd build 2>&1 | grep -E "^/Users.*error:|\*\* BUILD"
```

Expected: `** TEST SUCCEEDED **` (274 existing + 17 new = 291) and `** BUILD SUCCEEDED **`.

- [ ] **Step 6: Verify the real first-run, end to end**

```bash
pkill -x Carabiner
defaults delete com.offpiste.carabiner introShown 2>/dev/null
rm -rf ~/Applications/Carabiner.app
cp -R /tmp/carabiner-dd/Build/Products/Debug/Carabiner.app ~/Applications/
open ~/Applications/Carabiner.app
```

Confirm, in order:
1. The window opens on card 1 with no rail and no grab box.
2. NEXT reaches card 3; `SET UP PERMISSIONS →` opens the settings panel over the canvas.
3. Quit and reopen — no intro, straight to the canvas (`defaults read com.offpiste.carabiner introShown` prints `1`).
4. The menu-bar item "How Carabiner works" reopens it at card 1.
5. Repeat 1 with `defaults delete … introShown` and press SKIP instead: on this machine `onboardingShown` is already true, so it must land on the plain canvas with **no** settings panel.

- [ ] **Step 7: Commit**

```bash
git add app/Carabiner/MainWindow/MainWindowController.swift app/Carabiner/MenuBarController.swift app/Carabiner/App.swift
git commit -m "feat(app): show the explainer on first run, and from the status menu"
```

---

### Task 7: Documentation

**Files:**
- Modify: `CLAUDE.md` (the `app/` bullet under "Current state — BUILT")
- Modify: `README.md` (the app section, wherever first launch is described)

**Interfaces:** none.

- [ ] **Step 1: Record it in CLAUDE.md**

Add to the `app/` bullet, after the sentence describing first launch opening the settings panel:

```markdown
  **First run now opens a three-card explainer instead** (`app/Carabiner/MainWindow/Intro/`,
  spec `docs/superpowers/specs/2026-08-26-first-run-intro-design.md`): what Carabiner does,
  the three ways to ask (in-page button / ⌃⌥⌘V / paste here), and what to expect. It is
  gated on its own `introShown` key — deliberately NOT `onboardingShown`, which is already
  true on every 0.1.x and 0.2.0 install and would have hidden the explainer from exactly
  the upgraders the extension is newest to. SET UP PERMISSIONS hands off to the settings
  panel; SKIP still opens that panel on an install that has never been offered setup, so
  skipping cannot leave someone with a silently non-working app. Reopen it from the status
  menu ("How Carabiner works"); there is no rail icon for it on purpose.
```

- [ ] **Step 2: Record it in README.md**

In the section describing what happens after installing the app, add:

```markdown
The first time you open Carabiner it explains itself in three cards — what it does, the
three ways to ask for a file, and what to expect — then offers to set up permissions. You
can bring it back any time from the menu-bar icon: **How Carabiner works**.
```

- [ ] **Step 3: Commit**

```bash
git add CLAUDE.md README.md
git commit -m "docs: the first-run explainer, in CLAUDE.md and the README"
```

---

## Notes for the executor

- **The running app executes a bundled snapshot.** `Carabiner.app/Contents/Resources/carabiner` is copied at build time, and the app you installed is not your working copy. Rebuild and reinstall before trusting any app-driven check.
- **Do not leave two copies of `com.offpiste.carabiner` on disk.** A stale bundle in `/tmp`, DerivedData or `/Applications` poisons LaunchServices for the signed one — it surfaces as "the application can't be opened" or as notifications silently failing.
- **If a step's expectation does not match reality, stop and report it** rather than adapting the plan silently. The two most likely places: `.onMoveCommand` may need the window's focus before arrow keys page (Task 5 Step 4), and `windowWillClose` may already contain panel-clearing code that Task 6 Step 2's line must sit alongside rather than replace.
