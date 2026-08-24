# Responsive Hero Beside Rail Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** The main window's hero content (link bar + status line) re-centers itself in the space beside the left rail, so neither the collapsed rail nor the expanded 300pt card ever covers it.

**Architecture:** Pure SwiftUI layout change in `MainView.swift`: the `content` VStack gains a leading inset matching what the rail occupies (62pt collapsed, 314pt expanded), keyed on `model.panel` so the existing `.animation(.easeOut(duration: 0.2), value: model.panel)` on the root ZStack animates it. Interior horizontal padding drops 56 → 24 while a panel is open. Nothing changes in `SideRail.swift` or the view model.

**Tech Stack:** Swift/AppKit + SwiftUI, XcodeGen, xcodebuild. Spec: `docs/superpowers/specs/2026-08-24-responsive-hero-beside-rail-design.md`.

## Global Constraints

- Layout constants come from `SideRail.swift` as built today: rail 48pt wide, card 300pt wide, both with 14pt leading margin. Insets are therefore exactly **62** (collapsed) and **314** (expanded).
- No unit test for the inset — it is a two-case constant and a test would survive the wiring being deleted (CLAUDE.md gotcha #34 family). Verification is visual on a built, signed, bundle-launched app.
- Build must follow CLAUDE.md app rules: `CARABINER_TEAM_ID` exported, `xcodegen generate` from `app/`, derived data outside iCloud (`-derivedDataPath /tmp/carabiner-dd`, gotcha #13), install by `cp -R` to `~/Applications` and launch the bundle with `open` (gotcha #11).
- Corner furniture (rotated version string, bottom-right hotkey/wordmark/clock cluster), Esc, tap-outside-to-collapse, and drag-and-drop are untouched.

---

### Task 1: Inset the hero content beside the rail

**Files:**
- Modify: `app/Carabiner/MainWindow/MainView.swift:62-72` (the `content` computed property)

**Interfaces:**
- Consumes: `model.panel: MainViewModel.SidePanel?` (already observed by `MainView`; non-nil means a card is expanded).
- Produces: nothing new — layout-only change.

- [ ] **Step 1: Replace the `content` property's padding with rail-aware insets**

In `app/Carabiner/MainWindow/MainView.swift`, replace:

```swift
    private var content: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 60)
            linkBar
            statusLine
                .padding(.top, 12)
            Spacer(minLength: 24)
        }
        .padding(.horizontal, 56)
        .frame(maxWidth: .infinity)
    }
```

with:

```swift
    private var content: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 60)
            linkBar
            statusLine
                .padding(.top, 12)
            Spacer(minLength: 24)
        }
        // Center in the canvas the rail leaves free, not the full window: the
        // collapsed rail (48 + 14 margin) clips the bar at the 640pt minimum,
        // and the expanded card (300 + 14) covers its whole left edge.
        .padding(.leading, model.panel == nil ? 62 : 314)
        .padding(.horizontal, model.panel == nil ? 56 : 24)
        .frame(maxWidth: .infinity)
    }
```

Note the order matters for readability only — SwiftUI sums the two leading paddings (62+56 = 118 closed, 314+24 = 338 open). At the 640pt minimum with the card open that leaves 640 − 338 − 24 = 278pt for the link bar, per the spec's budget. When closed, the content is inset 118 leading / 56 trailing — visually centered enough at real sizes given the bar's 560pt `maxWidth` keeps it off the edges at default size; if the built app shows a noticeable off-center bias at default size, balance it by using `.padding(.leading, …)` + `.padding(.trailing, model.panel == nil ? 56 : 24)` with a leading of `model.panel == nil ? 62 + 56 : 314 + 24` and judge again visually — the spec's requirement is "centered in the remaining space", judged by eye.

- [ ] **Step 2: Build the app (signed, outside iCloud)**

```bash
cd /Users/wissevellinga/Documents/OFF-PISTE/Carabiner
export CARABINER_TEAM_ID=$(security find-certificate -a -c "Apple Development" -p \
  | openssl x509 -noout -subject | tr ',/' '\n\n' \
  | sed -nE 's/.*OU=([A-Z0-9]{10}).*/\1/p' | head -1)
./scripts/fetch-deps.sh && ./extension/build.sh
cd app && xcodegen generate && xcodebuild -project Carabiner.xcodeproj -scheme Carabiner \
  -configuration Debug -derivedDataPath /tmp/carabiner-dd build
```

Expected: `BUILD SUCCEEDED`.

- [ ] **Step 3: Install and launch the bundle**

```bash
pkill -x Carabiner; rm -rf ~/Applications/Carabiner.app
cp -R /tmp/carabiner-dd/Build/Products/Debug/Carabiner.app ~/Applications/ \
  && open ~/Applications/Carabiner.app
```

- [ ] **Step 4: Visual verification (the spec's three checks)**

1. Default size (720×460): open RECENT GRABS, then SETTINGS — the link bar slides right and re-centers beside the card, animation clean; close — it slides back.
2. Resize to minimum (640×420), card open: the full "PASTE YOUR LINK" prompt is visible, the field and GRAB button are usable, nothing sits under the card.
3. Card closed at minimum size: the bar clears the collapsed rail.

Screenshot or describe what was actually seen; if the closed-state bar looks noticeably off-center at default size, apply the balancing variant from Step 1 and rebuild.

- [ ] **Step 5: Commit**

```bash
cd /Users/wissevellinga/Documents/OFF-PISTE/Carabiner
git add app/Carabiner/MainWindow/MainView.swift
git commit -m "fix(app): hero re-centers beside the left rail — card no longer covers the link bar"
```
