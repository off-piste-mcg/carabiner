# Settings card: MANAGE pill on granted rows — design

**Date:** 2026-08-24
**Status:** Approved (Wisse), pre-implementation
**Prior art:** `2026-08-22-brand-main-window-design.md` (in-window settings),
`2026-08-02-onboarding-design.md` (the permission rows themselves)

## Problem

On a fully-granted machine the SETTINGS card is read-only: every row is a yellow
dot with no control (only LAUNCH AT LOGIN shows DISABLE, the one permission an
app can revoke itself). Users have no way to "edit" a granted permission from
the tab.

## Constraint (settled, do not re-litigate)

macOS offers no API for an app to revoke its own TCC grants — notifications,
Automation, Full Disk Access. The only truthful "disallow" is opening the exact
System Settings pane where the real switch lives. The codebase already encodes
this: `toggleAction(desired: false, status: .granted)` resolves to
`.openSystemSettings` for every row, and
`PermissionChecker.openSystemSettings(for:)` carries the complete per-row deep
links (notifications pane, Privacy → Automation, `Privacy_AllFiles`).

## Decision (chosen over a yellow "DISALLOW" pill)

Granted rows get a **quiet hollow MANAGE pill** — visually secondary to the
yellow ALLOW/DISABLE pills, because it navigates rather than acts. Labeling it
DISALLOW was rejected: the button cannot actually disallow, and a button that
doesn't do what it says is this project's worst failure shape.

## Which rows

| Row | Granted-state control |
|---|---|
| NOTIFICATIONS | MANAGE → Notifications pane |
| BROWSER ACCESS | MANAGE → Privacy → Automation |
| CAROUSEL DIALOG | MANAGE → Privacy → Automation |
| FULL DISK ACCESS | MANAGE → Privacy → Full Disk Access |
| LAUNCH AT LOGIN | unchanged — real DISABLE (in-app `unregister()`) |
| INSTAGRAM BUTTON | none — its off-switch is the browser's own extension UI, and Chrome offers no way to open `chrome://extensions` externally; a silently-failing button is worse than no button (gotchas #37/#40) |

## Mechanism — entirely UI-side

**No `OnboardingViewModel` / `PermissionChecker` / `PermissionModels` changes.**
`model.setEnabled(false, for: row)` on a granted row already opens the right
pane (`OnboardingViewModel.swift` `.openSystemSettings` branch) and refreshes
the row. All changes in `app/Carabiner/MainWindow/SettingsPanel.swift`:

1. **Pure decision** (beside the existing tested `SettingsPanel.actionTitle`):
   ```swift
   /// MANAGE appears only on granted rows whose real switch lives in System
   /// Settings. Not launchAtLogin (has a real DISABLE), not browserButton
   /// (no pane to open), never when off or notApplicable.
   static func manageTitle(row: PermissionRow, isOn: Bool, notApplicable: Bool) -> String?
   ```
   Returns `"MANAGE"` iff `isOn && !notApplicable` and `row` is one of
   `.notifications, .browserAccess, .carouselDialog, .fullDiskAccess`; else nil.
2. **`PanelRow`** gains `let manageTitle: String?` and renders it as a hollow
   pill — mono 10 with kerning like the yellow pill, `.black.opacity(0.6)` text,
   `Capsule().strokeBorder(.black.opacity(0.3), lineWidth: 1)` background, same
   padding — tapping calls the existing `action(false)` callback. A row shows
   the yellow pill or the manage pill, never both (their conditions are
   mutually exclusive by construction: actionTitle needs `!isOn` or
   launchAtLogin, manageTitle needs `isOn` and excludes launchAtLogin).
3. **`SettingsContent`** passes
   `manageTitle: SettingsPanel.manageTitle(row:isOn:notApplicable:)` with the
   same arguments it already computes for `actionTitle`.

## Testing

Extend the existing `SettingsPanelTests` with `manageTitle` cases:
- each of the four rows: granted → `"MANAGE"`, ungranted → nil
- `.launchAtLogin` granted → nil (DISABLE owns that state)
- `.browserButton` granted → nil
- notApplicable (fullDiskAccess on a no-Safari machine) → nil

The pill's tap path reuses the verified `setEnabled(false)` plumbing; visual
verification on the built app: granted rows show the hollow MANAGE pill, and
clicking one opens the matching System Settings pane (readable back via the
window title, the instrument from gotcha #37).
