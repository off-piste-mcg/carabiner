# OFF-PISTE Brand Main Window Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Re-skin `Carabiner.app`'s main window to the OFF-PISTE brand (gradient canvas, ABC Diatype Mono, yellow pills) and move Settings into the main window as a slide-in panel, retiring the separate Setup & Permissions window.

**Architecture:** View-layer rewrite only. `MainViewModel` gains one published flag (`settingsShown`); `OnboardingViewModel` is reused **byte-for-byte untouched** — the settings panel is a new view over the existing model. `MainWindowController` absorbs the window-owning duties of `OnboardingWindowController` (settings model construction stays in `MenuBarController`, hotkey-test timer moves over verbatim), then `OnboardingWindowController` and `OnboardingView` are deleted.

**Tech Stack:** Swift/AppKit + SwiftUI (macOS 13 target), XcodeGen, XCTest.

**Spec:** `docs/superpowers/specs/2026-08-22-brand-main-window-design.md`

## Global Constraints

- Brand yellow is exactly `#FAFA78`, defined once as asset-catalog color `BrandYellow`; no other file hardcodes a hex.
- Font: PostScript name `ABCDiatypeMono-Regular` (family "ABC Diatype Mono"), file `app/Carabiner/BrandAssets/ABCDiatypeMono-Regular.otf`. **The .otf is NEVER committed — this is a public repo and the font is commercially licensed.** It is gitignored like `.deps/bin`; every use goes through `Brand.mono(_:)`, which falls back to system monospaced when the font is absent, so a checkout without the file builds and runs.
- `OnboardingViewModel.swift`, `PermissionChecker.swift`, `PermissionModels.swift`, `HotkeyTestModel.swift`, `LoginItem.swift` must not be edited. All permission behavior lives there (CLAUDE.md gotchas #28, #37, #40).
- The first-launch defaults key stays the string `"onboardingShown"` — existing installs must not re-onboard.
- The engine (`carabiner`), `GrabRunner`, `GrabServer`, `GrabGate`, `GrabHistoryStore`, `Notifier`/`BannerPlanner`, ring, hotkey, Dock drop: untouched.
- Edit `app/project.yml`, never `Carabiner.xcodeproj` or `app/Carabiner/Info.plist` (build products).
- Every build first: `export CARABINER_TEAM_ID=$(security find-certificate -a -c "Apple Development" -p | openssl x509 -noout -subject | tr ',/' '\n\n' | sed -nE 's/.*OU=([A-Z0-9]{10}).*/\1/p' | head -1)`. Prereqs `./scripts/fetch-deps.sh` and `./extension/build.sh` must have run once. Use `-derivedDataPath /tmp/carabiner-dd` for `test` and `/tmp/carabiner-build` for install builds — never the same path for both (gotchas #13, #27), never a path inside the repo.

---

### Task 1: Brand asset wiring (catalog + project.yml + gitignore)

**Files:**
- Create: `app/Carabiner/Assets.xcassets/BrandYellow.colorset/Contents.json`
- Create: `app/Carabiner/Assets.xcassets/Wordmark.imageset/Contents.json`
- Move: `app/Carabiner/BrandAssets/wordmark.svg` → `app/Carabiner/Assets.xcassets/Wordmark.imageset/wordmark.svg`
- Modify: `app/project.yml` (BrandAssets folder resource + `ATSApplicationFontsPath`)
- Modify: `.gitignore` (the font)

**Interfaces:**
- Consumes: nothing.
- Produces: asset-catalog color `BrandYellow`, image `Wordmark`; bundle folder `Contents/Resources/BrandAssets/` containing `bg.jpg` and (when present locally) the .otf; Info.plist key `ATSApplicationFontsPath = BrandAssets` so macOS registers the font at launch.

- [ ] **Step 1: gitignore the font**

Append to the repo-root `.gitignore`:

```gitignore
# Licensed font — never ships in the public repo. Drop the .otf into
# app/Carabiner/BrandAssets/ locally; Brand.mono() falls back to system
# monospaced when it is absent.
app/Carabiner/BrandAssets/*.otf
```

- [ ] **Step 2: create the color set**

`app/Carabiner/Assets.xcassets/BrandYellow.colorset/Contents.json`:

```json
{
  "colors" : [
    {
      "color" : {
        "color-space" : "srgb",
        "components" : {
          "alpha" : "1.000",
          "blue" : "0x78",
          "green" : "0xFA",
          "red" : "0xFA"
        }
      },
      "idiom" : "universal"
    }
  ],
  "info" : {
    "author" : "xcode",
    "version" : 1
  }
}
```

- [ ] **Step 3: create the wordmark imageset**

```bash
mkdir -p app/Carabiner/Assets.xcassets/Wordmark.imageset
git mv app/Carabiner/BrandAssets/wordmark.svg app/Carabiner/Assets.xcassets/Wordmark.imageset/wordmark.svg
```

(If `git mv` fails because the file was never tracked, plain `mv` and `git add` it.)

`app/Carabiner/Assets.xcassets/Wordmark.imageset/Contents.json`:

```json
{
  "images" : [
    {
      "filename" : "wordmark.svg",
      "idiom" : "universal"
    }
  ],
  "info" : {
    "author" : "xcode",
    "version" : 1
  },
  "properties" : {
    "preserves-vector-representation" : true,
    "template-rendering-intent" : "original"
  }
}
```

- [ ] **Step 4: wire BrandAssets and the font path in project.yml**

In `app/project.yml`, under the `Carabiner` target's `sources:`, after the `.deps/bin` entry, add:

```yaml
      # Brand canvas + (locally) the licensed font. `type: folder` copies the
      # directory itself, so these land at Resources/BrandAssets/ — same
      # mechanism as .deps/bin above. The .otf is gitignored (licensed, public
      # repo): a checkout without it still builds, and Brand.mono() falls back.
      - path: Carabiner/BrandAssets
        buildPhase: resources
        type: folder
```

In the same target's `info.properties`, alongside `NSAppleEventsUsageDescription`, add:

```yaml
        # Registers every font in Resources/BrandAssets at launch — this is
        # what makes Font.custom("ABCDiatypeMono-Regular") resolve.
        ATSApplicationFontsPath: BrandAssets
```

- [ ] **Step 5: generate and build**

```bash
cd app
export CARABINER_TEAM_ID=$(security find-certificate -a -c "Apple Development" -p | openssl x509 -noout -subject | tr ',/' '\n\n' | sed -nE 's/.*OU=([A-Z0-9]{10}).*/\1/p' | head -1)
xcodegen generate
xcodebuild -project Carabiner.xcodeproj -scheme Carabiner -configuration Debug -derivedDataPath /tmp/carabiner-build build
```

Expected: build succeeds.

- [ ] **Step 6: verify the bundle**

```bash
APP=/tmp/carabiner-build/Build/Products/Debug/Carabiner.app
ls "$APP/Contents/Resources/BrandAssets/"
plutil -extract ATSApplicationFontsPath raw "$APP/Contents/Info.plist"
```

Expected: `bg.jpg` and `ABCDiatypeMono-Regular.otf` listed; `BrandAssets` printed. (Asset catalog: `BrandYellow` and `Wordmark` compile into `Assets.car` — their absence would have failed the views in Task 2/3, nothing to check by hand here.)

- [ ] **Step 7: commit**

```bash
git add .gitignore app/project.yml app/Carabiner/Assets.xcassets
git commit -m "feat(app): wire brand assets — BrandYellow, Wordmark, BrandAssets folder + font registration"
```

(Deliberately NOT `git add app/Carabiner/BrandAssets` — the folder currently holds only gitignored/moved files; `bg.jpg` gets added here too:)

```bash
git add app/Carabiner/BrandAssets/bg.jpg
git commit --amend --no-edit
```

---

### Task 2: Brand.swift (colors, fonts, clock) — TDD on the pure part

**Files:**
- Create: `app/Carabiner/Brand.swift`
- Test: `app/CarabinerTests/BrandTests.swift`

**Interfaces:**
- Consumes: asset color `BrandYellow` (Task 1).
- Produces: `enum Brand` with `static let yellow: Color`, `static func mono(_ size: CGFloat) -> Font`, `static func clockText(_ date: Date, timeZone: TimeZone = .current) -> String`, `static var backgroundImage: NSImage?`, `static var shortVersion: String`.

- [ ] **Step 1: write the failing test**

`app/CarabinerTests/BrandTests.swift`:

```swift
import XCTest
@testable import Carabiner

final class BrandTests: XCTestCase {
    /// The footer clock renders mockup-style: zero-padded 12h, uppercase AM/PM,
    /// no space — "09:32AM". Locale-pinned so a machine's 24h preference can't
    /// change the brand furniture.
    func testClockTextFormatsMockupStyle() {
        var components = DateComponents()
        components.year = 2026; components.month = 8; components.day = 22
        components.hour = 9; components.minute = 32
        components.timeZone = TimeZone(identifier: "Europe/Amsterdam")
        let date = Calendar(identifier: .gregorian).date(from: components)!
        XCTAssertEqual(Brand.clockText(date, timeZone: TimeZone(identifier: "Europe/Amsterdam")!),
                       "09:32AM")
    }

    func testClockTextAfternoon() {
        var components = DateComponents()
        components.year = 2026; components.month = 8; components.day = 22
        components.hour = 14; components.minute = 5
        components.timeZone = TimeZone(identifier: "Europe/Amsterdam")
        let date = Calendar(identifier: .gregorian).date(from: components)!
        XCTAssertEqual(Brand.clockText(date, timeZone: TimeZone(identifier: "Europe/Amsterdam")!),
                       "02:05PM")
    }
}
```

- [ ] **Step 2: run to verify it fails**

```bash
cd app && xcodegen generate
xcodebuild -project Carabiner.xcodeproj -scheme Carabiner -destination 'platform=macOS' -derivedDataPath /tmp/carabiner-dd test 2>&1 | tail -20
```

Expected: FAIL — `cannot find 'Brand' in scope`.

- [ ] **Step 3: implement**

`app/Carabiner/Brand.swift`:

```swift
import SwiftUI
import AppKit

/// The OFF-PISTE brand, in one place. Every view asks Brand; nothing else names a
/// hex, a font name, or a resource path.
enum Brand {
    /// #FAFA78 — sampled from the approved mockup's GRAB pill. Lives in the asset
    /// catalog so this is the only mention.
    static let yellow = Color("BrandYellow")

    /// ABC Diatype Mono when the licensed .otf is present (registered at launch via
    /// ATSApplicationFontsPath), system monospaced otherwise. The fallback is what
    /// lets the public repo build without shipping the font.
    static func mono(_ size: CGFloat) -> Font {
        if NSFont(name: "ABCDiatypeMono-Regular", size: size) != nil {
            return .custom("ABCDiatypeMono-Regular", size: size)
        }
        return .system(size: size, design: .monospaced)
    }

    /// The gradient canvas. nil on a checkout without the asset — the view draws a
    /// plain gradient fallback rather than a white void.
    static let backgroundImage: NSImage? = {
        guard let url = Bundle.main.url(forResource: "bg", withExtension: "jpg",
                                        subdirectory: "BrandAssets") else { return nil }
        return NSImage(contentsOf: url)
    }()

    /// "0.1.2" — the right-edge furniture renders it as "V. 0.1.2".
    static var shortVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
    }

    /// Mockup-style footer clock: "09:32AM". Locale pinned to en_US_POSIX so a 24h
    /// system preference can't reshape brand furniture; timeZone injectable for tests.
    static func clockText(_ date: Date, timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "hh:mma"
        return formatter.string(from: date)
    }
}
```

- [ ] **Step 4: run tests to verify they pass**

Same command as Step 2. Expected: PASS (both new tests; full suite still green).

- [ ] **Step 5: commit**

```bash
git add app/Carabiner/Brand.swift app/CarabinerTests/BrandTests.swift
git commit -m "feat(app): Brand — yellow, Diatype Mono with fallback, canvas image, clock"
```

---

### Task 3: The canvas — MainView rewrite + window chrome

**Files:**
- Modify: `app/Carabiner/MainWindow/MainView.swift` (full rewrite of layout; `HistoryRow`/`ThumbnailView` restyled in place)
- Modify: `app/Carabiner/MainWindow/MainViewModel.swift` (add `settingsShown`)
- Modify: `app/Carabiner/MainWindow/MainWindowController.swift` (chrome only in this task)

**Interfaces:**
- Consumes: `Brand` (Task 2); existing `MainViewModel` API (`urlField`, `stage`, `feedback`, `grabbing`, `submit()`), `GrabHistoryStore.entries`.
- Produces: `MainViewModel.settingsShown: Bool` (`@Published`, read by Task 4's overlay); `MainView` renders the full canvas; the settings pill sets `model.settingsShown = true`.

- [ ] **Step 1: add the flag to MainViewModel**

In `MainViewModel`, after the `feedback` property:

```swift
    /// Whether the settings panel is shown over the canvas. Set by the yellow pill,
    /// by MenuBarController.showSettings(), and cleared by ✕ / Esc / the scrim.
    @Published var settingsShown = false
```

- [ ] **Step 2: window chrome in MainWindowController**

Replace the `init` body's window configuration with:

```swift
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 460),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable,
                                          .fullSizeContentView],
                              backing: .buffered, defer: false)
        // The brand canvas is the window: transparent titlebar, no title text, content
        // bleeding under the traffic lights (which stay — native close/minimize).
        window.title = "Carabiner"              // window menu / accessibility name only
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        // The artwork is light and has no dark variant; pin the appearance so native
        // sub-controls (context menus, text caret) never go dark-on-pale.
        window.appearance = NSAppearance(named: .aqua)
        window.isMovableByWindowBackground = true
        window.minSize = NSSize(width: 640, height: 420)
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.contentViewController = NSHostingController(rootView: MainView(model: model))
        window.setContentSize(NSSize(width: 720, height: 460))
```

- [ ] **Step 3: rewrite MainView**

Replace the whole of `MainView.swift` with:

```swift
import SwiftUI
import QuickLookThumbnailing

/// The brand canvas: gradient artwork edge to edge, the link bar center, RECENT below,
/// corner furniture around. Renders model state and forwards actions — every decision
/// stays in MainViewModel. Settings overlay arrives in SettingsPanel (own file).
struct MainView: View {
    @ObservedObject var model: MainViewModel
    @ObservedObject var history: GrabHistoryStore

    init(model: MainViewModel) {
        self.model = model
        self.history = model.history
    }

    var body: some View {
        ZStack {
            background
            content
            furniture
        }
        .frame(minWidth: 640, minHeight: 420)
        .ignoresSafeArea()   // under the transparent titlebar
        // A URL dragged anywhere onto the canvas submits — same path as typing it.
        .onDrop(of: [.url, .plainText], isTargeted: nil) { providers in
            loadDroppedURL(from: providers) { dropped in
                model.urlField = dropped
                model.submit()
            }
            return true
        }
    }

    // MARK: - canvas

    @ViewBuilder
    private var background: some View {
        GeometryReader { geo in
            if let image = Brand.backgroundImage {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: geo.size.width, height: geo.size.height)
                    .clipped()
            } else {
                // Checkout without the asset: approximate, never a white void.
                LinearGradient(colors: [Color(red: 0.64, green: 0.69, blue: 0.76),
                                        Color(red: 0.86, green: 0.87, blue: 0.88)],
                               startPoint: .top, endPoint: .bottom)
            }
        }
        .ignoresSafeArea()
    }

    private var content: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 60)
            linkBar
            statusLine
                .padding(.top, 12)
            Spacer(minLength: 24)
            if !history.entries.isEmpty {
                recentSection
                    .padding(.bottom, 44)   // clears the footer furniture
            }
        }
        .padding(.horizontal, 56)
    }

    private var linkBar: some View {
        HStack(spacing: 10) {
            TextField("", text: $model.urlField,
                      prompt: Text("PASTE YOUR LINK").font(Brand.mono(12)))
                .textFieldStyle(.plain)
                .font(Brand.mono(12))
                .padding(.horizontal, 18)
                .frame(height: 34)
                .background(Capsule().fill(.white.opacity(0.55)))
                .onSubmit { model.submit() }
            Button { model.submit() } label: {
                Text("GRAB")
                    .font(Brand.mono(12)).kerning(1)
                    .foregroundStyle(.black)
                    .padding(.horizontal, 24)
                    .frame(height: 34)
                    .background(Capsule().fill(Brand.yellow))
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.defaultAction)
            .disabled(model.grabbing)
        }
        .frame(maxWidth: 560)
    }

    @ViewBuilder
    private var statusLine: some View {
        if let stage = model.stage {
            HStack(spacing: 8) {
                PulsingDot()
                Text(stage.uppercased()).font(Brand.mono(10)).kerning(1)
                    .foregroundStyle(.black.opacity(0.6))
            }
        } else if let feedback = model.feedback {
            Text(feedback.uppercased()).font(Brand.mono(10)).kerning(1)
                .foregroundStyle(.black.opacity(0.6))
                .multilineTextAlignment(.center)
        }
    }

    private var recentSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("RECENT").font(Brand.mono(10)).kerning(2)
                .foregroundStyle(.black.opacity(0.45))
            ScrollView(showsIndicators: false) {
                LazyVStack(alignment: .leading, spacing: 6) {
                    ForEach(history.entries) { entry in
                        HistoryRow(entry: entry)
                    }
                }
            }
            .frame(maxHeight: 170)
        }
        .frame(maxWidth: 560)
    }

    // MARK: - corner furniture

    private var furniture: some View {
        ZStack {
            // Top-right: the settings pill.
            VStack { HStack { Spacer()
                Button { model.settingsShown = true } label: {
                    Capsule().fill(Brand.yellow).frame(width: 40, height: 12)
                }
                .buttonStyle(.plain)
                .help("Settings")
            }; Spacer() }
            .padding(14)

            // Right edge, rotated: the version.
            HStack { Spacer()
                Text("V. \(Brand.shortVersion)")
                    .font(Brand.mono(9)).kerning(2)
                    .foregroundStyle(.black.opacity(0.4))
                    .fixedSize()
                    .rotationEffect(.degrees(90))
                    .frame(width: 14)
            }
            .padding(.trailing, 10)

            // Bottom-left: the hotkey hint. Bottom-right: wordmark + clock.
            VStack { Spacer()
                HStack(alignment: .center) {
                    Text("⌃⌥⌘V").font(Brand.mono(10)).kerning(1)
                        .foregroundStyle(.black.opacity(0.4))
                    Spacer()
                    HStack(spacing: 8) {
                        Image("Wordmark")
                            .resizable().scaledToFit().frame(height: 11)
                        TimelineView(.everyMinute) { context in
                            Text(Brand.clockText(context.date))
                                .font(Brand.mono(10)).kerning(1)
                                .foregroundStyle(.black.opacity(0.55))
                        }
                    }
                }
            }
            .padding(16)
        }
        .allowsHitTesting(true)
    }

    /// First provider that yields a URL or a URL-shaped string wins. Completion is called
    /// on the main queue (the providers call back on arbitrary queues).
    private func loadDroppedURL(from providers: [NSItemProvider], _ done: @escaping (String) -> Void) {
        guard let provider = providers.first(where: {
            $0.canLoadObject(ofClass: URL.self) || $0.canLoadObject(ofClass: NSString.self)
        }) else { return }
        if provider.canLoadObject(ofClass: URL.self) {
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                if let url { DispatchQueue.main.async { done(url.absoluteString) } }
            }
        } else {
            _ = provider.loadObject(ofClass: NSString.self) { string, _ in
                if let string = string as? String { DispatchQueue.main.async { done(string) } }
            }
        }
    }
}

/// The yellow activity dot beside the stage text — a quiet pulse, not a spinner.
private struct PulsingDot: View {
    @State private var dim = false

    var body: some View {
        Circle()
            .fill(Brand.yellow)
            .frame(width: 6, height: 6)
            .opacity(dim ? 0.3 : 1)
            .animation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true), value: dim)
            .onAppear { dim = true }
    }
}

/// One grab, brand-styled: 24px thumbnail, mono caps name, @user · relative time.
/// Behavior identical to the pre-brand row: double-click opens, context menu Reveal/Open,
/// rows whose file is gone are dimmed with actions disabled.
private struct HistoryRow: View {
    let entry: GrabHistoryEntry

    var body: some View {
        HStack(spacing: 10) {
            ThumbnailView(path: firstExistingPath)
            Text(title.uppercased())
                .font(Brand.mono(11))
                .foregroundStyle(.black.opacity(0.75))
                .lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 12)
            HStack(spacing: 6) {
                if let user = entry.user { Text(user.uppercased()) }
                Text(entry.date, format: .relative(presentation: .named))
            }
            .font(Brand.mono(9))
            .foregroundStyle(.black.opacity(0.4))
            .lineLimit(1)
        }
        .opacity(anyFileExists ? 1 : 0.35)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { open() }
        .contextMenu {
            Button("Reveal in Finder") { reveal() }.disabled(!anyFileExists)
            Button("Open") { open() }.disabled(!anyFileExists)
        }
        .help(anyFileExists ? entry.url : "File no longer in Downloads")
    }

    private var title: String {
        entry.files.count == 1 ? (entry.files.first ?? "") : "\(entry.files.count) files"
    }

    /// The script saves to ~/Downloads with no `-o` from the app, so names resolve there.
    /// Entries like `saved to ~/Downloads` (YouTube/Pinterest paths) simply don't resolve.
    private var paths: [String] {
        let downloads = NSString(string: "~/Downloads").expandingTildeInPath
        return entry.files.map { downloads + "/" + $0 }
    }

    private var existingPaths: [String] { paths.filter { FileManager.default.fileExists(atPath: $0) } }
    private var anyFileExists: Bool { !existingPaths.isEmpty }
    private var firstExistingPath: String? { existingPaths.first }

    private func reveal() {
        NSWorkspace.shared.activateFileViewerSelecting(existingPaths.map { URL(fileURLWithPath: $0) })
    }

    private func open() {
        guard let first = existingPaths.first else { return }
        NSWorkspace.shared.open(URL(fileURLWithPath: first))
    }
}

/// QuickLook thumbnail with the file's icon as immediate fallback. Requested at 2x for
/// Retina; a missing file renders a plain document icon so the row keeps its shape.
private struct ThumbnailView: View {
    let path: String?
    @State private var thumbnail: NSImage?

    private static let side: CGFloat = 24

    var body: some View {
        Group {
            if let thumbnail {
                Image(nsImage: thumbnail).resizable().scaledToFill()
            } else if let path {
                Image(nsImage: NSWorkspace.shared.icon(forFile: path)).resizable().scaledToFit()
            } else {
                Image(systemName: "doc").foregroundStyle(.tertiary)
            }
        }
        .frame(width: Self.side, height: Self.side)
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .task(id: path) {
            thumbnail = nil
            guard let path else { return }
            let request = QLThumbnailGenerator.Request(
                fileAt: URL(fileURLWithPath: path),
                size: CGSize(width: Self.side, height: Self.side),
                scale: 2, representationTypes: .thumbnail)
            let generated = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request)
            thumbnail = generated?.nsImage
        }
    }
}
```

- [ ] **Step 4: build, run tests**

```bash
cd app && xcodegen generate
xcodebuild -project Carabiner.xcodeproj -scheme Carabiner -destination 'platform=macOS' -derivedDataPath /tmp/carabiner-dd test 2>&1 | tail -5
```

Expected: build succeeds, full suite green (nothing tested was edited).

- [ ] **Step 5: install and eyeball**

```bash
xcodebuild -project Carabiner.xcodeproj -scheme Carabiner -configuration Debug -derivedDataPath /tmp/carabiner-build build
pkill -x Carabiner; rm -rf ~/Applications/Carabiner.app
cp -R /tmp/carabiner-build/Build/Products/Debug/Carabiner.app ~/Applications/ && open ~/Applications/Carabiner.app
```

Click the Dock icon. Expected: full-bleed gradient canvas under the traffic lights, mono `PASTE YOUR LINK` bar + yellow GRAB pill centered, RECENT list if history exists, furniture in all four corners, Diatype Mono letterforms (distinctly wider than SF Mono — if it looks like SF Mono the font didn't register; check `ATSApplicationFontsPath` and the .otf in `Resources/BrandAssets/`). Minor padding/size tweaks to match the mockup's balance are allowed within this task.

- [ ] **Step 6: commit**

```bash
git add app/Carabiner/MainWindow
git commit -m "feat(app): brand canvas — full-bleed artwork, mono link bar, RECENT, corner furniture"
```

---

### Task 4: Settings panel — view + pure action mapping (TDD)

**Files:**
- Create: `app/Carabiner/MainWindow/SettingsPanel.swift`
- Modify: `app/Carabiner/MainWindow/MainView.swift` (overlay integration)
- Modify: `app/Carabiner/MainWindow/MainWindowController.swift` (hold the settings model — construction wired fully in Task 5)
- Test: `app/CarabinerTests/SettingsPanelTests.swift`

**Interfaces:**
- Consumes: `OnboardingViewModel` (untouched — `presentation(for:)`, `isOn(_:)`, `isNotApplicable(_:)`, `setEnabled(_:for:)`, `hotkey`, `onBeginHotkeyTest`, `refreshAll()`), `PermissionRow.allCases`/`.title`/`.why`, `Brand`, `MainViewModel.settingsShown` (Task 3).
- Produces: `SettingsPanel: View` with `init(model: OnboardingViewModel, onClose: @escaping () -> Void)`; pure `SettingsPanel.actionTitle(row:isOn:notApplicable:) -> String?`; `MainView.init(model:settings:)` now takes the settings model.

- [ ] **Step 1: write the failing test**

`app/CarabinerTests/SettingsPanelTests.swift`:

```swift
import XCTest
@testable import Carabiner

/// The panel's one decision of its own: which action a row offers. Everything else
/// (status, intent handling) is OnboardingViewModel's, already covered elsewhere.
final class SettingsPanelTests: XCTestCase {
    func testUngrantedRowOffersAllow() {
        for row in PermissionRow.allCases {
            XCTAssertEqual(SettingsPanel.actionTitle(row: row, isOn: false, notApplicable: false),
                           "ALLOW", "\(row) should offer ALLOW when off")
        }
    }

    /// macOS gives no way to revoke a TCC grant, so a granted row offers nothing —
    /// except Launch at login, the one row that genuinely can turn itself off
    /// (PermissionRow.canRevokeInProcess; CLAUDE.md gotcha #40's neighbor).
    func testGrantedRowsOfferNothingExceptLaunchAtLogin() {
        for row in PermissionRow.allCases {
            let title = SettingsPanel.actionTitle(row: row, isOn: true, notApplicable: false)
            if row == .launchAtLogin {
                XCTAssertEqual(title, "DISABLE")
            } else {
                XCTAssertNil(title, "\(row) has no honest off action")
            }
        }
    }

    func testNotApplicableRowOffersNothing() {
        XCTAssertNil(SettingsPanel.actionTitle(row: .fullDiskAccess, isOn: false, notApplicable: true))
    }
}
```

- [ ] **Step 2: run to verify it fails**

```bash
cd app && xcodegen generate
xcodebuild -project Carabiner.xcodeproj -scheme Carabiner -destination 'platform=macOS' -derivedDataPath /tmp/carabiner-dd test 2>&1 | tail -20
```

Expected: FAIL — `cannot find 'SettingsPanel' in scope`.

- [ ] **Step 3: implement the panel**

`app/Carabiner/MainWindow/SettingsPanel.swift`:

```swift
import SwiftUI

/// The in-window settings: the Setup & Permissions rows re-housed in brand style.
/// Renders OnboardingViewModel and forwards intents — every permission decision stays
/// in that model (untouched; gotchas #28/#37/#40 live there). This view's only own
/// decision is actionTitle(row:isOn:notApplicable:), which is pure and tested.
struct SettingsPanel: View {
    @ObservedObject var model: OnboardingViewModel
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("SETTINGS").font(Brand.mono(12)).kerning(2)
                Spacer()
                Button(action: onClose) {
                    Image(systemName: "xmark").font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.black.opacity(0.5))
                }
                .buttonStyle(.plain)
                .help("Close")
            }
            .padding(.top, 40)   // clears the transparent titlebar region
            .padding(.horizontal, 20)
            .padding(.bottom, 16)

            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 18) {
                    ForEach(PermissionRow.allCases, id: \.self) { row in
                        PanelRow(
                            title: row.title.uppercased(),
                            detail: model.presentation(for: row).detail ?? row.why,
                            state: model.isNotApplicable(row) ? .notApplicable
                                 : model.isOn(row) ? .on : .off,
                            actionTitle: Self.actionTitle(row: row,
                                                          isOn: model.isOn(row),
                                                          notApplicable: model.isNotApplicable(row)),
                            action: { desiredOn in model.setEnabled(desiredOn, for: row) })
                    }
                    hotkeyRow
                    Text("Your first grab may ask for access to Chrome's \"Safe Storage\" — "
                         + "click Always Allow. That's macOS guarding Chrome's cookies, which "
                         + "Carabiner reads to act as you.")
                        .font(Brand.mono(9))
                        .foregroundStyle(.black.opacity(0.4))
                        .padding(.top, 4)
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 20)
            }
        }
        .frame(width: 300)
        .frame(maxHeight: .infinity)
        .background(.regularMaterial)
    }

    /// Which action a row offers. ALLOW when ungranted; nothing when granted (macOS
    /// offers no revoke) — except Launch at login, the one row that can honestly turn
    /// itself off; nothing when not applicable (nothing to flip on this machine).
    static func actionTitle(row: PermissionRow, isOn: Bool, notApplicable: Bool) -> String? {
        if notApplicable { return nil }
        if !isOn { return "ALLOW" }
        return row == .launchAtLogin ? "DISABLE" : nil
    }

    @ViewBuilder
    private var hotkeyRow: some View {
        HStack(alignment: .top, spacing: 10) {
            StatusDot(state: model.hotkey.tick == .ok ? .on
                      : model.hotkey.tick.isFailure ? .failed : .off)
            VStack(alignment: .leading, spacing: 3) {
                Text("HOTKEY").font(Brand.mono(11)).kerning(1)
                Text(model.hotkey.detail ?? "One keystroke, from anywhere.")
                    .font(Brand.mono(9)).foregroundStyle(.black.opacity(0.45))
            }
            Spacer(minLength: 8)
            if let buttonTitle = model.hotkey.buttonTitle {
                Button(buttonTitle.uppercased()) { model.onBeginHotkeyTest() }
                    .buttonStyle(.plain)
                    .font(Brand.mono(10)).kerning(1)
                    .foregroundStyle(.black)
                    .padding(.horizontal, 10).padding(.vertical, 4)
                    .background(Capsule().fill(Brand.yellow))
            }
        }
    }
}

/// One permission row: dot, mono caps title, quiet detail, optional pill action.
private struct PanelRow: View {
    enum RowState { case on, off, notApplicable }

    let title: String
    let detail: String
    let state: RowState
    let actionTitle: String?
    /// Called with the desired on/off — ALLOW sends true, DISABLE sends false.
    let action: (Bool) -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            StatusDot(state: state == .on ? .on : state == .off ? .off : .dim)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(Brand.mono(11)).kerning(1)
                    .foregroundStyle(state == .notApplicable ? .black.opacity(0.35) : .black)
                Text(detail).font(Brand.mono(9)).foregroundStyle(.black.opacity(0.45))
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            if let actionTitle {
                Button(actionTitle) { action(actionTitle == "ALLOW") }
                    .buttonStyle(.plain)
                    .font(Brand.mono(10)).kerning(1)
                    .foregroundStyle(.black)
                    .padding(.horizontal, 10).padding(.vertical, 4)
                    .background(Capsule().fill(Brand.yellow))
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(title)
    }
}

/// Filled yellow = granted; hollow = not; dim = nothing to grant; red = test failed.
private struct StatusDot: View {
    enum DotState { case on, off, dim, failed }
    let state: DotState

    var body: some View {
        Group {
            switch state {
            case .on: Circle().fill(Brand.yellow)
            case .off: Circle().strokeBorder(.black.opacity(0.35), lineWidth: 1)
            case .dim: Circle().fill(.black.opacity(0.15))
            case .failed: Circle().fill(.red.opacity(0.8))
            }
        }
        .frame(width: 8, height: 8)
        .padding(.top, 3)
    }
}
```

- [ ] **Step 4: integrate the overlay into MainView**

In `MainView.swift`:

Add the settings model to the view (after `history`):

```swift
    @ObservedObject var settings: OnboardingViewModel

    init(model: MainViewModel, settings: OnboardingViewModel) {
        self.model = model
        self.history = model.history
        self.settings = settings
    }
```

Replace `body`'s `ZStack` with (the drop modifier and frame stay where they are):

```swift
        ZStack(alignment: .trailing) {
            background
            content
            furniture
            if model.settingsShown {
                // Scrim: click closes. Above the canvas, below the panel.
                Color.black.opacity(0.25)
                    .ignoresSafeArea()
                    .onTapGesture { model.settingsShown = false }
                    .transition(.opacity)
                SettingsPanel(model: settings) { model.settingsShown = false }
                    .transition(.move(edge: .trailing))
            }
        }
        .animation(.easeOut(duration: 0.2), value: model.settingsShown)
        .onExitCommand { if model.settingsShown { model.settingsShown = false } }
```

In `furniture`, make the settings pill refresh statuses as it opens:

```swift
                Button { settings.refreshAll(); model.settingsShown = true } label: {
```

- [ ] **Step 5: hold the model in MainWindowController (temporary construction)**

`MainWindowController.init` gains the parameter and passes it through — full ownership plumbing (checker closures, hotkey test) lands in Task 5; for this task, just:

```swift
    let model: MainViewModel
    let settingsModel: OnboardingViewModel

    init(model: MainViewModel, settingsModel: OnboardingViewModel) {
        self.model = model
        self.settingsModel = settingsModel
        ...
        window.contentViewController = NSHostingController(
            rootView: MainView(model: model, settings: settingsModel))
```

And in `MenuBarController.showMainWindow()`, construct it with the same checker the onboarding window uses (copy the `LivePermissionChecker(...)` construction from `showOnboarding()` verbatim, including its closure comments):

```swift
            let settingsModel = OnboardingViewModel(
                checker: LivePermissionChecker(browser: Self.browser,
                                               lastSeen: { [weak self] in self?.grabServer?.lastSeen ?? [:] },
                                               serverState: { [weak self] in self?.grabServer?.state ?? .stopped },
                                               loginItem: LiveLoginItemController()))
            mainWindow = MainWindowController(model: model, settingsModel: settingsModel)
```

(`OnboardingViewModel` is `@MainActor`; `showMainWindow` runs on main — fine.)

- [ ] **Step 6: run tests to verify they pass**

Same test command. Expected: PASS — the three new tests and the full suite.

- [ ] **Step 7: install and eyeball**

Same install commands as Task 3 Step 5. Expected: yellow pill slides the panel in over a dimmed canvas; rows show dots + ALLOW pills; ✕, Esc and the scrim each close it; the hotkey TEST button counts down (the intercept isn't wired until Task 5 — a real chord press won't tick yet; that's expected here).

- [ ] **Step 8: commit**

```bash
git add app/Carabiner/MainWindow app/CarabinerTests/SettingsPanelTests.swift
git commit -m "feat(app): settings panel — permission rows re-housed in-window, brand style"
```

---

### Task 5: Re-house ownership, retire the onboarding window

**Files:**
- Modify: `app/Carabiner/MainWindow/MainWindowController.swift` (hotkey test + delegate + `showSettings()` + defaults key)
- Modify: `app/Carabiner/MenuBarController.swift` (`showSettings()` replaces `showOnboarding()`; menu item retitle)
- Modify: `app/Carabiner/App.swift` (⌘, route + first-launch key)
- Modify: `app/Carabiner/Server/GrabServer.swift` (one comment reference, line ~124)
- Delete: `app/Carabiner/Onboarding/OnboardingWindowController.swift`, `app/Carabiner/Onboarding/OnboardingView.swift`

**Interfaces:**
- Consumes: `MainWindowController(model:settingsModel:)` (Task 4), `MainViewModel.settingsShown` (Task 3), `HotkeyTestModel` (untouched).
- Produces: `MainWindowController.showSettings()`, `MainWindowController.settingsShownDefaultsKey` (value `"onboardingShown"`), `MenuBarController.showSettings()` (replaces `showOnboarding()`); `MainWindowController.init(model:settingsModel:hotkeyIntercept:clearIntercept:)`.

- [ ] **Step 1: move the hotkey test and window-delegate duties into MainWindowController**

Replace `MainWindowController` with:

```swift
import AppKit
import SwiftUI

/// The main window: the brand canvas plus the in-window settings panel. Owns everything
/// AppKit-shaped — the window, the hotkey-test timer, the intercept lifecycle (moved
/// verbatim from the retired OnboardingWindowController). Decisions live in
/// MainViewModel, OnboardingViewModel and HotkeyTestModel.
final class MainWindowController: NSWindowController, NSWindowDelegate {
    let model: MainViewModel
    let settingsModel: OnboardingViewModel

    private let hotkeyIntercept: (@escaping () -> Void) -> Void
    private let clearIntercept: () -> Void
    private var hotkeyModel = HotkeyTestModel()
    private var hotkeyTimer: Timer?

    /// Same string as the retired onboarding window's shownDefaultsKey — existing
    /// installs must not re-run first-launch.
    static let settingsShownDefaultsKey = "onboardingShown"

    init(model: MainViewModel,
         settingsModel: OnboardingViewModel,
         hotkeyIntercept: @escaping (@escaping () -> Void) -> Void,
         clearIntercept: @escaping () -> Void) {
        self.model = model
        self.settingsModel = settingsModel
        self.hotkeyIntercept = hotkeyIntercept
        self.clearIntercept = clearIntercept
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 460),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable,
                                          .fullSizeContentView],
                              backing: .buffered, defer: false)
        // The brand canvas is the window: transparent titlebar, no title text, content
        // bleeding under the traffic lights (which stay — native close/minimize).
        window.title = "Carabiner"              // window menu / accessibility name only
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        // The artwork is light and has no dark variant; pin the appearance so native
        // sub-controls (context menus, text caret) never go dark-on-pale.
        window.appearance = NSAppearance(named: .aqua)
        window.isMovableByWindowBackground = true
        window.minSize = NSSize(width: 640, height: 420)
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        window.contentViewController = NSHostingController(
            rootView: MainView(model: model, settings: settingsModel))
        window.setContentSize(NSSize(width: 720, height: 460))
        settingsModel.onBeginHotkeyTest = { [weak self] in self?.beginHotkeyTest() }
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    func show() {
        NSApp.activate(ignoringOtherApps: true)
        // A Dock click on an already-open window brings it forward, and must not
        // re-center a window the user has positioned.
        if window?.isVisible != true { window?.center() }
        window?.makeKeyAndOrderFront(nil)
    }

    /// ⌘,, the status-menu item and first launch land here: the window with the
    /// settings panel already open.
    func showSettings() {
        UserDefaults.standard.set(true, forKey: Self.settingsShownDefaultsKey)
        settingsModel.refreshAll()
        model.settingsShown = true
        show()
    }

    // MARK: - hotkey test (moved verbatim from OnboardingWindowController)

    private func beginHotkeyTest() {
        hotkeyModel.beginTest()
        settingsModel.hotkey = hotkeyModel.presentation
        hotkeyIntercept { [weak self] in
            guard let self else { return }
            self.hotkeyTimer?.invalidate()
            self.hotkeyModel.hotkeyFired()
            self.settingsModel.hotkey = self.hotkeyModel.presentation
        }
        hotkeyTimer?.invalidate()
        hotkeyTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: false) { [weak self] _ in
            guard let self else { return }
            self.clearIntercept()
            self.hotkeyModel.timeout()
            self.settingsModel.hotkey = self.hotkeyModel.presentation
        }
    }

    // MARK: - NSWindowDelegate

    func windowDidBecomeKey(_ notification: Notification) { settingsModel.refreshAll() }

    func windowWillClose(_ notification: Notification) {
        hotkeyTimer?.invalidate()
        clearIntercept()
        hotkeyModel.cancel()
        settingsModel.hotkey = hotkeyModel.presentation
    }
}
```

- [ ] **Step 2: MenuBarController — showSettings() replaces showOnboarding()**

Delete the `private var onboarding: OnboardingWindowController?` property and the whole `showOnboarding()` method. In `showMainWindow()`, extend the construction with the intercept closures (the checker construction from Task 4 Step 5 stays):

```swift
            mainWindow = MainWindowController(
                model: model,
                settingsModel: settingsModel,
                hotkeyIntercept: { [weak self] handler in self?.hotkeyTestHandler = handler },
                clearIntercept: { [weak self] in self?.hotkeyTestHandler = nil })
```

Add below `showMainWindow()`:

```swift
    /// ⌘,, the status-menu item and first launch: the main window with the settings
    /// panel already open. Same lazy construction as showMainWindow().
    @objc func showSettings() {
        showMainWindow()
        mainWindow?.showSettings()
    }
```

(`showMainWindow()` already ends in `mainWindow?.show()`; `showSettings()` calling both `show()`s is harmless — second is idempotent.)

Retitle the menu item in `init`:

```swift
        let setupItem = NSMenuItem(title: "Settings…", action: #selector(showSettings), keyEquivalent: "")
```

- [ ] **Step 3: App.swift — route ⌘, and first launch**

```swift
    @objc func showSettings(_ sender: Any?) {
        menuBar?.showSettings()
    }
```

and in `applicationDidFinishLaunching`:

```swift
        if !UserDefaults.standard.bool(forKey: MainWindowController.settingsShownDefaultsKey) {
            controller.showSettings()
        }
```

- [ ] **Step 4: fix the comment in GrabServer.swift**

Line ~124 references `OnboardingWindowController.shownDefaultsKey`; update the name to `MainWindowController.settingsShownDefaultsKey` (comment-only edit).

- [ ] **Step 5: delete the retired files**

```bash
git rm app/Carabiner/Onboarding/OnboardingWindowController.swift app/Carabiner/Onboarding/OnboardingView.swift
```

(The rest of `Onboarding/` — the view model, checker, models, hotkey model, login item — stays, per Global Constraints.)

- [ ] **Step 6: build + full test suite**

```bash
cd app && xcodegen generate
xcodebuild -project Carabiner.xcodeproj -scheme Carabiner -destination 'platform=macOS' -derivedDataPath /tmp/carabiner-dd test 2>&1 | tail -5
```

Expected: green. (`HotkeyTestModelTests`, `PermissionModelsTests`, `LoginItemTests` all still pass — their subjects were not edited.)

- [ ] **Step 7: install and verify the routing**

Install per Task 3 Step 5. Expected: ⌘, opens the window with the panel open; status menu "Settings…" ditto; Dock click opens it on the plain canvas; the hotkey TEST row now ticks on a real ⌃⌥⌘V press (intercept is wired); closing the window mid-test cancels it.

- [ ] **Step 8: commit**

```bash
git add -A app/Carabiner
git commit -m "feat(app): settings re-housed in the main window; onboarding window retired"
```

---

### Task 6: Documentation

**Files:**
- Modify: `CLAUDE.md` (the `app/` bullet's main-window paragraph)

- [ ] **Step 1: update CLAUDE.md**

In the `app/` section of "Current state — BUILT", update the main-window paragraph: the main window is now the OFF-PISTE brand canvas (bg artwork full-bleed, ABC Diatype Mono via `ATSApplicationFontsPath`, `BrandYellow` #FAFA78, `Brand.swift` is the single source); Settings is an in-window slide-in panel reusing `OnboardingViewModel` untouched; `OnboardingWindowController`/`OnboardingView` are deleted; ⌘,, the status-menu "Settings…" item and first launch open the main window with the panel open (defaults key string unchanged: `"onboardingShown"`); the licensed .otf is gitignored (public repo) and `Brand.mono()` falls back to system monospaced without it. Reference the spec path `docs/superpowers/specs/2026-08-22-brand-main-window-design.md`.

- [ ] **Step 2: commit**

```bash
git add CLAUDE.md
git commit -m "docs: brand main window + in-window settings in CLAUDE.md"
```

---

### Task 7: Final verification (build from clean, manual pass)

**Files:** none (verification only).

- [ ] **Step 1: full clean build + tests**

```bash
cd app
export CARABINER_TEAM_ID=$(security find-certificate -a -c "Apple Development" -p | openssl x509 -noout -subject | tr ',/' '\n\n' | sed -nE 's/.*OU=([A-Z0-9]{10}).*/\1/p' | head -1)
../scripts/fetch-deps.sh && ../extension/build.sh
xcodegen generate
xcodebuild -project Carabiner.xcodeproj -scheme Carabiner -destination 'platform=macOS' -derivedDataPath /tmp/carabiner-dd test 2>&1 | tail -5
xcodebuild -project Carabiner.xcodeproj -scheme Carabiner -configuration Debug -derivedDataPath /tmp/carabiner-build build
pkill -x Carabiner; rm -rf ~/Applications/Carabiner.app
cp -R /tmp/carabiner-build/Build/Products/Debug/Carabiner.app ~/Applications/ && open ~/Applications/Carabiner.app
```

- [ ] **Step 2: manual checklist (from the spec §6 — tick each in the session log)**

1. Canvas renders: full-bleed artwork, Diatype Mono type (not SF Mono), all four corners' furniture, clock shows the current time.
2. Real grab through the bar: paste an Instagram URL, GRAB → stage line animates, file lands in `~/Downloads` (verify by filename diff, NOT timestamps — CLAUDE.md), banner fires, a RECENT row appears.
3. Drag-and-drop a URL onto the canvas → same flow.
4. History row: double-click opens the file; right-click Reveal in Finder works; a row whose file was deleted renders dimmed.
5. Settings: yellow pill, ⌘,, and status-menu "Settings…" each open the panel; Esc, ✕, scrim each close it.
6. Rows show true state (compare against System Settings); ALLOW on an ungranted row acts (spot-check: notifications); Launch at login ALLOW → DISABLE round-trip both directions; hotkey TEST catches a real ⌃⌥⌘V.
7. Hotkey grab and extension grab still work (the shared path was untouched — this is the wiring check, gotcha #34).
8. Resize to min size: composition holds, nothing clips.
9. First-launch: `defaults delete com.offpiste.carabiner onboardingShown`, relaunch → window opens with the panel; relaunch again → it doesn't.

- [ ] **Step 3: report**

Report each checklist outcome honestly (memory: a green check here is usually lying — make sure each was actually exercised). Anything unverifiable solo (e.g. needs a permission reset) gets said, not silently skipped.
