# Settings MANAGE Pill Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Granted permission rows in the SETTINGS card get a quiet hollow MANAGE pill that opens the exact System Settings pane where the real switch lives.

**Architecture:** Entirely UI-side in `app/Carabiner/MainWindow/SettingsPanel.swift`: a pure `SettingsPanel.manageTitle` decision (TDD, beside the tested `actionTitle`), an optional hollow pill in `PanelRow` wired to the existing `action(false)` callback, which already reaches `OnboardingViewModel.setEnabled(false, for:)` → `.openSystemSettings`. No model/checker changes.

**Tech Stack:** Swift/AppKit + SwiftUI, XCTest, XcodeGen, xcodebuild. Spec: `docs/superpowers/specs/2026-08-24-settings-manage-pill-design.md`.

## Global Constraints

- MANAGE rows: exactly `.notifications, .browserAccess, .carouselDialog, .fullDiskAccess`, and only when `isOn && !notApplicable`. Never `.launchAtLogin` (real DISABLE) or `.browserButton` (no pane to open).
- Pill copy is exactly `"MANAGE"`; style: mono 10 kerning 1, `.black.opacity(0.6)` text, `Capsule().strokeBorder(.black.opacity(0.3), lineWidth: 1)`, same padding as the yellow pill.
- Build rules per CLAUDE.md: `CARABINER_TEAM_ID` exported, `xcodegen generate` from `app/`, derived data at `/tmp/carabiner-dd` (gotcha #13), install via `cp -R` to `~/Applications`, launch the bundle with `open` (gotcha #11). Tests must use a separate derived-data path from the install build (gotcha #27's test-host trap) — use `/tmp/carabiner-test-manage` for the test action and delete it afterwards (gotcha #42: stale `/tmp` bundles poison LaunchServices).

---

### Task 1: `manageTitle` + the hollow pill

**Files:**
- Modify: `app/Carabiner/MainWindow/SettingsPanel.swift` (enum `SettingsPanel`, `PanelRow`, `SettingsContent`)
- Test: `app/CarabinerTests/SettingsPanelTests.swift`

**Interfaces:**
- Consumes: `PermissionRow` cases, `SettingsPanel.actionTitle(row:isOn:notApplicable:)` (unchanged), `PanelRow.action: (Bool) -> Void` (unchanged).
- Produces: `SettingsPanel.manageTitle(row:isOn:notApplicable:) -> String?`.

- [ ] **Step 1: Write the failing tests**

Append inside the existing test class in `app/CarabinerTests/SettingsPanelTests.swift`:

```swift
    func testManageTitleOnGrantedSystemSettingsRows() {
        for row: PermissionRow in [.notifications, .browserAccess, .carouselDialog, .fullDiskAccess] {
            XCTAssertEqual(SettingsPanel.manageTitle(row: row, isOn: true, notApplicable: false),
                           "MANAGE", "\(row) granted should offer MANAGE")
        }
    }

    func testManageTitleAbsentWhenUngranted() {
        for row: PermissionRow in [.notifications, .browserAccess, .carouselDialog, .fullDiskAccess] {
            XCTAssertNil(SettingsPanel.manageTitle(row: row, isOn: false, notApplicable: false),
                         "\(row) ungranted shows ALLOW, not MANAGE")
        }
    }

    func testManageTitleAbsentWhereItWouldLie() {
        // launchAtLogin has a real DISABLE; browserButton has no pane to open.
        XCTAssertNil(SettingsPanel.manageTitle(row: .launchAtLogin, isOn: true, notApplicable: false))
        XCTAssertNil(SettingsPanel.manageTitle(row: .browserButton, isOn: true, notApplicable: false))
        // Nothing granted → nothing to manage (no-Safari machine's FDA row).
        XCTAssertNil(SettingsPanel.manageTitle(row: .fullDiskAccess, isOn: true, notApplicable: true))
    }
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
cd /Users/wissevellinga/Documents/OFF-PISTE/Carabiner/app
export CARABINER_TEAM_ID=$(security find-certificate -a -c "Apple Development" -p \
  | openssl x509 -noout -subject | tr ',/' '\n\n' \
  | sed -nE 's/.*OU=([A-Z0-9]{10}).*/\1/p' | head -1)
xcodegen generate
xcodebuild -project Carabiner.xcodeproj -scheme Carabiner -destination 'platform=macOS' \
  -derivedDataPath /tmp/carabiner-test-manage test 2>&1 | tail -5
```

Expected: build FAILS with "type 'SettingsPanel' has no member 'manageTitle'".

- [ ] **Step 3: Implement `manageTitle`**

In `app/Carabiner/MainWindow/SettingsPanel.swift`, inside `enum SettingsPanel`, below `actionTitle`:

```swift
    /// The quiet secondary action on a granted row: MANAGE opens the System Settings
    /// pane where the real switch lives (macOS gives the app no revoke of its own).
    /// Only rows whose switch IS in System Settings — not launchAtLogin (real DISABLE),
    /// not browserButton (its off-switch is the browser's extension UI, unreachable
    /// from here); never when off or notApplicable.
    static func manageTitle(row: PermissionRow, isOn: Bool, notApplicable: Bool) -> String? {
        guard isOn, !notApplicable else { return nil }
        switch row {
        case .notifications, .browserAccess, .carouselDialog, .fullDiskAccess: return "MANAGE"
        case .launchAtLogin, .browserButton: return nil
        }
    }
```

- [ ] **Step 4: Run tests to verify they pass**

Same command as Step 2. Expected: `** TEST SUCCEEDED **` (all suites — no other test may regress). Then `rm -rf /tmp/carabiner-test-manage` (gotcha #42).

- [ ] **Step 5: Render the pill and wire it**

In the same file, `PanelRow` gains the property and renders it (the yellow pill and MANAGE are mutually exclusive by construction, so both `if let`s can stand side by side). Replace `PanelRow`'s property block and button section:

```swift
    let title: String
    let detail: String
    let state: RowState
    let actionTitle: String?
    /// MANAGE — quiet, hollow: navigates to System Settings rather than acting.
    let manageTitle: String?
    /// Called with the desired on/off — ALLOW sends true, DISABLE and MANAGE send false
    /// (a granted row's "off" resolves to .openSystemSettings in the model).
    let action: (Bool) -> Void
```

and after the existing `if let actionTitle { … }` block:

```swift
            if let manageTitle {
                Button(manageTitle) { action(false) }
                    .buttonStyle(.plain)
                    .font(Brand.mono(10)).kerning(1)
                    .foregroundStyle(.black.opacity(0.6))
                    .padding(.horizontal, 10).padding(.vertical, 4)
                    .background(Capsule().strokeBorder(.black.opacity(0.3), lineWidth: 1))
            }
```

In `SettingsContent`, pass the new argument (between `actionTitle:` and `action:`):

```swift
                    manageTitle: SettingsPanel.manageTitle(row: row,
                                                  isOn: model.isOn(row),
                                                  notApplicable: model.isNotApplicable(row)),
```

- [ ] **Step 6: Build, install, verify visually**

```bash
cd /Users/wissevellinga/Documents/OFF-PISTE/Carabiner/app
xcodebuild -project Carabiner.xcodeproj -scheme Carabiner -configuration Debug \
  -derivedDataPath /tmp/carabiner-dd build 2>&1 | tail -1
pkill -x Carabiner; rm -rf ~/Applications/Carabiner.app
cp -R /tmp/carabiner-dd/Build/Products/Debug/Carabiner.app ~/Applications/ && open ~/Applications/Carabiner.app
```

Open the SETTINGS card: every granted row (yellow dot) except LAUNCH AT LOGIN and INSTAGRAM BUTTON shows a hollow MANAGE pill; LAUNCH AT LOGIN still shows yellow DISABLE. Click NOTIFICATIONS' MANAGE → System Settings opens on the Notifications pane (window title readable via System Events, gotcha #37's instrument). Screenshot the card.

- [ ] **Step 7: Commit**

```bash
cd /Users/wissevellinga/Documents/OFF-PISTE/Carabiner
git add app/Carabiner/MainWindow/SettingsPanel.swift app/CarabinerTests/SettingsPanelTests.swift
git commit -m "feat(app): quiet MANAGE pill on granted settings rows — opens the real switch in System Settings"
```
