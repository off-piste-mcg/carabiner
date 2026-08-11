# Onboarding in system UI, and the permission-verification fix — design

**Date:** 2026-08-11
**Supersedes the presentation half of:** `docs/superpowers/specs/2026-08-02-onboarding-design.md`
(that spec's *behaviour* — which permissions, why each one, the hotkey test, reopen from
the status menu — still stands and is not revisited here)

## Two things, deliberately in one change

1. The Setup & Permissions window is rebuilt to look like a stock macOS pane.
2. The notification row stops reporting success it hasn't verified.

They ship together because the second is invisible without the first: the bug *is* a
presentation lie, and the row that told the lie is being rewritten anyway.

## What went wrong (the reason for #2)

Reported 2026-08-11 on the first notarized install. The user clicked Allow on the
notifications row, macOS showed its prompt, the user allowed it — and no banners
appeared. System Settings showed Carabiner's "Allow notifications" switch **off**. Turning
it on by hand fixed it.

The machine-specific trigger was gotcha #11: three notification identities existed for
one bundle id —

```
NOTIFICATION#:com.offpiste.carabiner            (team-less)
NOTIFICATION#SDC6T5U9G3:com.offpiste.carabiner  (old dev team)
NOTIFICATION#A7FDJVJ355:com.offpiste.carabiner  (Developer ID)
```

— across nine registered bundle paths, accumulated from the team-ID change plus a day of
mounting the DMG and copying the app to temp directories during release verification. A
teammate installing the DMG onto a clean Mac has one record and will very likely never
reproduce it.

**That does not make it a non-bug.** Whatever caused the grant to miss, the window
asserted success without checking, and the user had no signal beyond "notifications
silently don't work" — the failure mode the window exists to prevent. The environment
trigger is rare; the false green tick is not.

`PermissionChecker.swift` trusts the callback flag:

```swift
UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, error in
    completion(granted ? .granted : .denied)   // never confirmed against actual settings
}
```

## The fix

Report granted only when notifications will actually be **seen**. Two conditions, both
required:

- `authorizationStatus == .authorized` (or `.provisional`)
- `alertSetting == .enabled`

The second is not padding. Authorization can be on while the alert style is "None", in
which case notifications land silently in Notification Centre and never appear on screen.
For Carabiner the banner *is* the feature — a grab that finishes invisibly is
indistinguishable from a hotkey that never fired (gotcha #14, gotcha #22). Silent
delivery is a failure, so it reports `.denied` and the row offers "Open System Settings".

This applies to **both** paths, not just the request:

- `request(_:)` — re-query after the prompt resolves; ignore the `granted` flag entirely.
- `status(for:)` — the passive check on window open and on focus, so an already-broken
  install shows a warning immediately instead of a false tick.

`.provisional` counts as authorized for the status test but still requires
`alertSetting == .enabled`; provisional authorization delivers quietly by default, which
is exactly the invisible case being rejected.

### Where the logic lives

The decision is extracted into a pure function in `PermissionModels.swift`:

```swift
func notificationStatus(authorization: UNAuthorizationStatus,
                        alert: UNNotificationSetting) -> PermissionStatus
```

`LivePermissionChecker` shrinks to fetching the two values and calling it. The seam stays
a thin OS wrapper (untested by design, per the existing comment); the judgement moves in
front of the seam where it can be tested.

No new `PermissionStatus` case. "Authorized but invisible" maps onto `.denied`, because
the user's required action is identical: open System Settings and fix it. A fourth case
would add a state to every `switch` to express a distinction with no different remedy.

## The window

**Framework: SwiftUI, hosted in the existing `NSWindowController` via
`NSHostingController`.** The target look is a stock System Settings pane, and
`Form` + `.formStyle(.grouped)` is the Apple control that draws it — available on macOS
13, the deployment floor. The alternative, hand-tuning `NSBox` corner radii and insets to
imitate that control, is how the current window became subtly non-native; repeating it
would repeat the result.

The cost is one SwiftUI surface inside an otherwise-AppKit app. It is contained: the menu
bar, notifier, hotkey and grab pipeline are untouched.

**What is kept from the current window:**

- `OnboardingWindowController` remains the owner — window lifecycle, the hotkey-test
  timer and intercept, `windowDidBecomeKey` → refresh, `windowWillClose` → cancel, and
  the `onboardingShown` defaults key.
- `PermissionRow`, `PermissionStatus`, `RowPresentation`, `HotkeyTestModel` — unchanged
  except for the added pure function. These are the tested decision layer and they are
  already right.
- The copy: the pitch line, the three-step how-to, the per-row "why" strings, and the
  Chrome Safe Storage note.

**What changes:**

- `RowView` (the hand-built `NSStackView` row) is deleted, replaced by a SwiftUI row.
- Status glyphs `✓ / ✗ / ○` become SF Symbols: `checkmark.circle.fill` (green),
  `exclamationmark.triangle.fill` (red), `circle.dotted` (tertiary).
- The OFF-PISTE blue accent (`#2D5BFF`) is dropped; the window uses the system accent.
- The monospaced how-to block becomes system font.
- Layout becomes a centred header (app icon, "Carabiner", pitch) above one grouped
  `Form` section containing the three permission rows and the hotkey test, with the Safe
  Storage note as section footer text.
- The window stops being a fixed 460×480 and sizes to its content.

**Not changed:** which permissions exist, what they mean, the order they appear in, the
hotkey test's behaviour, or when the window auto-opens.

## Testing

`PermissionModelsTests` gains coverage of `notificationStatus(authorization:alert:)`
across the combinations that matter:

| authorization | alert | expected | why it is in the table |
|---|---|---|---|
| `.authorized` | `.enabled` | `.granted` | the working case |
| `.authorized` | `.disabled` | `.denied` | **allowed but invisible — the reported bug's sibling** |
| `.denied` | `.enabled` | `.denied` | plain refusal |
| `.notDetermined` | `.notSupported` | `.notDetermined` | never asked; row offers Allow |
| `.provisional` | `.enabled` | `.granted` | quiet auth, but alerts on |
| `.provisional` | `.disabled` | `.denied` | quiet auth delivering invisibly |

The SwiftUI view itself is not unit-tested — it holds no decisions, same rationale as the
current thin view. Verification that the window *looks* right is manual, on a real build.

**What cannot be verified locally:** the original failure needs a machine with a clean
notification record. This Mac now has three, and cleaning them is a separate operation.
The fix is therefore verified by unit test plus one manual check that a healthy install
still reports granted — not by reproducing the original symptom. Recorded here so nobody
later reads a green suite as proof the field bug is fixed.

## Out of scope

- **Cleaning the stale LaunchServices records.** A machine-maintenance operation on the
  developer's Mac, not a code change, and the app is working now.
- **Rebuilding the notification stack.** `Notifier` and `BannerPlanner` are correct
  (gotcha #22) and untouched.
- **The macOS Shortcut path.** It has no onboarding window and posts its own plain
  banner.
- **Re-theming anything outside this window.** The status item and the branded
  notification keep their current assets.
