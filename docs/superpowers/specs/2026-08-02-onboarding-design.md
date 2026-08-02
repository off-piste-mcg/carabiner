# Carabiner.app — first-run setup & permissions window

**Date:** 2026-08-02
**Status:** approved (design)

## Problem

A fresh install currently front-loads nothing and surprises the user four times:

1. The notifications prompt fires at launch with zero context (`App.swift` calls
   `requestAuthorization()` unconditionally).
2. *"Carabiner wants to control Google Chrome"* appears mid-grab, the first time the
   hotkey is pressed.
3. A second Automation prompt (System Events) appears the first time a carousel dialog
   shows.
4. The *"Chrome Safe Storage"* keychain prompt can appear from cookie extraction —
   the scariest one, with no explanation anywhere.

Nothing tells the user the hotkey exists, and a silently-dead hotkey (the old Shortcut
still bound to ⌃⌥⌘V — gotcha #14) is indistinguishable from a broken app.

## Decision

One **branded checklist window** (approach A; wizard and just-in-time-only were
considered and rejected — a wizard adds state for steps that don't depend on each
other, and just-in-time is the current confusing behaviour). Native AppKit with the
OFF-PISTE look: logo, mono type, blue `#2D5BFF` accent, standard controls.

macOS reality the whole design accepts: permissions cannot be pre-granted. The best an
app can do is (a) *trigger* each OS prompt at a chosen moment with an explanation next
to it, (b) *detect* the resulting state, and (c) deep-link to System Settings when
something was denied. That is exactly what each row does.

## When it appears

- **First launch:** shown automatically. Tracked by a `UserDefaults` flag
  (`onboardingShown`) set when the window is first shown — so it never auto-nags again,
  even if the app quits with the window still open.
- **Any time after:** a new **"Setup & Permissions…"** status-menu item (above Quit)
  reopens it. The live status ticks make it the diagnostics page when grabs stop
  working.
- The app stays `LSUIElement`; the window activates with
  `NSApp.activate(ignoringOtherApps:)` + `makeKeyAndOrderFront`.
- Row statuses refresh when the window becomes key and after every row action.

## Layout

Top to bottom:

1. **Logo + one-liner** — "Clip a post. Keep the file."-style pitch (final copy at
   implementation, kept to one line).
2. **How-to, three steps** — open a post in Chrome → press ⌃⌥⌘V → the file lands in
   `~/Downloads`. Mention: carousels ask "this slide or all".
3. **Four rows**, each: name, one-sentence why, live status (✓ / ✗ / ○), one button.
4. **Footnote** — *"Your first grab may ask for access to Chrome's 'Safe Storage' —
   click Always Allow. That's macOS guarding Chrome's cookies, which Carabiner reads
   to act as you."*

### Row 1 — Notifications

- **Why line:** "So you see when a grab finishes — or why it didn't."
- **Button "Allow"** → `UNUserNotificationCenter.requestAuthorization` (the real
  prompt). This call **moves out of launch**: `App.swift` stops requesting
  unconditionally; on fresh installs the window is the only requester. Existing
  installs already authorized just show ✓.
- Status via `getNotificationSettings`: `.authorized` → ✓; `.denied` → ✗ and the
  button becomes **"Open System Settings"**
  (`x-apple.systempreferences:com.apple.preference.notifications`); `.notDetermined`
  → ○ with "Allow".

### Row 2 — Browser access (Automation → Google Chrome)

- **Why line:** "To read the address of the post you're looking at."
- Mechanism: `AEDeterminePermissionToAutomateTarget` (blocks — run off the main
  thread) targeting Chrome's bundle id; `askUserIfNeeded: true` from the button,
  `false` for the passive status check.
- **Quirk designed around:** the OS only shows this prompt while the target app is
  *running* (`procNotFound` otherwise). The button launches Chrome via `NSWorkspace`
  first if needed, then requests.
- Denied → ✗, button becomes "Open System Settings" (Automation pane).
- Chrome stays hardcoded (as in `MenuBarController`), but the row takes a `Browser`
  value so the future browser picker slots in without touching the row.

### Row 3 — Carousel dialog (Automation → System Events)

- **Why line:** "So Carabiner can ask 'this slide or the whole set?'."
- Same mechanism as row 2, targeting `com.apple.systemevents`. System Events is an
  always-available agent, so no launch dance is needed.
- TCC attributes the script's `osascript` dialog to Carabiner (the responsible
  process), so granting here covers the carousel prompt. Verify this end-to-end
  during implementation on a machine/state without the grant.

### Row 4 — Hotkey test

- **Why line:** "One keystroke, from anywhere."
- **Button "Test"** → row enters a listening state (~10 s). The next hotkey fire is
  routed to the window (one-shot intercept in `MenuBarController` — no grab runs) and
  the row turns ✓.
- Timeout → hint: *"Nothing arrived. If you installed the Carabiner Shortcut before,
  remove its keyboard shortcut in the Shortcuts app — a hotkey has exactly one
  owner."* (gotcha #14 — registration failure is silent, so listening is the only
  honest check.)

## Components

```
app/Carabiner/Onboarding/
  PermissionChecker.swift   protocol + live impl (notification status, automation
                            status/request, browser running/launch)
  OnboardingRowModel.swift  PURE: (row, PermissionStatus) → label / button title /
                            button action kind / tick — unit-tested like BannerPlanner
  OnboardingWindow.swift    thin AppKit window + rows, no logic worth testing
```

Plus: `App.swift` (drop the unconditional `requestAuthorization`, show window on
first launch), `MenuBarController` (menu item, one-shot hotkey intercept for the
test row).

## Testing

- `OnboardingRowModelTests` — pure mapping: every `PermissionStatus` × row → expected
  button/status/tick, denied → settings-link action, hotkey timeout → hint state.
- `PermissionChecker` is the seam; the live impl is thin OS calls, not unit-tested.
- Manual end-to-end before shipping (fresh-user simulation):
  `tccutil reset AppleEvents com.offpiste.carabiner` + notification re-auth, then walk
  every row on a machine where Chrome is closed — the launch-Chrome path must be seen
  working, and the System Events grant must be confirmed to cover the script's dialog.

## Out of scope (deliberately)

- Open-at-login, browser picker, keychain warm-up (footnote instead), Sparkle
  auto-update, localization, and any change to the Shortcut path. Nothing here blocks
  them later.
