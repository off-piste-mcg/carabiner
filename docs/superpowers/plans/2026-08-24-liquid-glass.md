# Liquid Glass Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Rail, expanded card, and link-bar field render Liquid Glass on macOS 26 and keep today's exact look on 13–15.

**Architecture:** Three inline gates, one per surface, all the same shape: the existing `.background(...)` modifier becomes `.background { if #available(macOS 26.0, *) { Color.clear.glassEffect(.regular, in: <shape>) } else { <today's fill, unchanged> } }`. Two sites in `SideRail.swift`, one in `MainView.swift`. No shared helper, no new files, no tests. Spec: `docs/superpowers/specs/2026-08-24-liquid-glass-design.md`.

**Tech Stack:** SwiftUI `.glassEffect(_:in:)` (macOS 26 SDK), XcodeGen, xcodebuild.

## Global Constraints

- Deployment target stays `macOS: "13.0"` — do not touch `project.yml`.
- Every `else` branch is byte-identical to the current fill.
- Yellow pills, MANAGE pill, corner furniture, transitions: untouched.
- Build rules per CLAUDE.md: `CARABINER_TEAM_ID` exported, `-derivedDataPath /tmp/carabiner-dd` (gotcha #13), install via `cp -R` to `~/Applications` + `open` the bundle (gotcha #11).
- If the build fails because the SDK lacks `glassEffect`: STOP and report (the spec's flagged risk) — no polyfill, no workaround.

---

### Task 1: Gate the three surfaces

**Files:**
- Modify: `app/Carabiner/MainWindow/SideRail.swift` (`rail` and `expandedCard` backgrounds)
- Modify: `app/Carabiner/MainWindow/MainView.swift` (`linkBar` field background)

**Interfaces:** none — rendering only.

- [ ] **Step 1: Rail.** In `SideRail.swift` replace

```swift
        .background(RoundedRectangle(cornerRadius: 22).fill(.regularMaterial))
```

(the `rail` occurrence) with

```swift
        .background {
            // Liquid Glass on Tahoe; the same frost as always on 13–15.
            if #available(macOS 26.0, *) {
                Color.clear.glassEffect(.regular, in: RoundedRectangle(cornerRadius: 22))
            } else {
                RoundedRectangle(cornerRadius: 22).fill(.regularMaterial)
            }
        }
```

- [ ] **Step 2: Expanded card.** Apply the identical replacement to `expandedCard`'s `.background(RoundedRectangle(cornerRadius: 22).fill(.regularMaterial))` (comment on the first site only).

- [ ] **Step 3: Link field.** In `MainView.swift` replace

```swift
                .background(Capsule().fill(.white.opacity(0.55)))
```

with

```swift
                .background {
                    if #available(macOS 26.0, *) {
                        Color.clear.glassEffect(.regular, in: Capsule())
                    } else {
                        Capsule().fill(.white.opacity(0.55))
                    }
                }
```

- [ ] **Step 4: Build.**

```bash
cd /Users/wissevellinga/Documents/OFF-PISTE/Carabiner/app
export CARABINER_TEAM_ID=$(security find-certificate -a -c "Apple Development" -p \
  | openssl x509 -noout -subject | tr ',/' '\n\n' \
  | sed -nE 's/.*OU=([A-Z0-9]{10}).*/\1/p' | head -1)
xcodebuild -project Carabiner.xcodeproj -scheme Carabiner -configuration Debug \
  -derivedDataPath /tmp/carabiner-dd build 2>&1 | grep -E "^\*\* BUILD| error:"
```

Expected: `** BUILD SUCCEEDED **`. A `glassEffect`-unknown error is the STOP condition.

- [ ] **Step 5: Install, launch, verify visually (macOS 26 path).**

```bash
pkill -x Carabiner; rm -rf ~/Applications/Carabiner.app
cp -R /tmp/carabiner-dd/Build/Products/Debug/Carabiner.app ~/Applications/ && open ~/Applications/Carabiner.app
```

Rail, expanded card, and link field show refractive glass over the gradient canvas; open/close animation still clean; prompt/typed text in the field stays legible. Screenshot the closed and open states.

- [ ] **Step 6: Commit.**

```bash
cd /Users/wissevellinga/Documents/OFF-PISTE/Carabiner
git add app/Carabiner/MainWindow/SideRail.swift app/Carabiner/MainWindow/MainView.swift
git commit -m "feat(app): Liquid Glass on rail, card and link field (macOS 26, gated)"
```
