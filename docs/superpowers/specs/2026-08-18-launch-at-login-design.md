# Launch at login — design

**Date:** 2026-08-18 · **Status:** designed, not built
**Branch:** `feat/browser-extension`

## Why this exists

Chrome's "Open Carabiner?" external-protocol dialog has **no "always allow" checkbox**.
Measured 2026-08-18 while fixing item 11: every cold launch prompts, forever. The
extension's cold-launch path now works (commit 0864b45) — a visible tab, a wait for the app
to answer, the tab closed afterwards — but it is a *fallback*, and it costs the user a tab
flash and a click every time Carabiner is not already running.

A login item removes the cause rather than smoothing the symptom: if Carabiner is already
running, the button POSTs straight to it and no dialog is ever involved.

This is deliberately **not** an argument for auto-enabling it. See "Default", below.

## Scope

One row in the Setup & Permissions window, plus the small amount of model behind it.

Explicitly out of scope: a menu-bar checkbox (a second view of the same state to keep in
sync, for a setting people touch approximately once), and any change to the cold-launch
fallback, which stays exactly as it is for users who decline.

## Mechanism

`SMAppService.mainApp` (`ServiceManagement`), available since macOS 13; the project targets
13.0, so no availability fencing is needed.

Rejected alternatives:

- **`SMLoginItemSetEnabled`** — deprecated, and requires shipping a separate helper bundle
  inside the app purely to be the thing that gets registered.
- **Hand-written LaunchAgent plist** — puts us in the business of managing a file macOS
  already manages, breaks when the app moves, and is exactly the kind of thing that looks
  fine on the dev machine and fails on a teammate's.

## The row

A sixth case on `PermissionRow` (`app/Carabiner/Onboarding/PermissionModels.swift`):

- **Title:** "Launch at login"
- **Why:** "So Carabiner is already running. Otherwise your browser asks 'Open Carabiner?'
  every time you use the button."
- `requiresRunningTarget` → `false`, `mayLaunchTargetForStatusCheck` → `false`,
  `targetLaunchNote` → `nil`. There is no target app to start; these three exist for the
  Automation rows.

The *why* copy carries the recommendation. The row does not nudge with styling, badges or a
pre-checked switch — it states the cost of leaving it off and lets the user decide.

## Status mapping

The only real logic, and the part worth unit-testing:

| `SMAppService.Status` | `PermissionStatus` | Rationale |
|---|---|---|
| `.enabled` | `.granted` | Registered and running at login. |
| `.notRegistered` | `.notDetermined` | The ordinary opt-in state; renders the "Allow" button. |
| `.requiresApproval` | `.denied` | The user switched it off in System Settings. Nothing in-app can re-enable it — only Settings can, so the row must send them there. |
| `.notFound` | `.denied` | Should not occur for `mainApp`. A visible cross beats a false tick; a state we do not understand must never render as success. |

`.notApplicable` is deliberately **not** used. Its branch in `presentation(for:)` hardcodes
Safari-specific copy ("Only needed if you use Safari"), which would be nonsense here. That
shared-switch-with-row-specific-copy is a real smell, but refactoring it is not this
change's job — avoiding the status is enough, and the alternative is touching a branch three
verified rows depend on.

## Deep link

`x-apple.systempreferences:com.apple.LoginItems-Settings.extension`

**Verified 2026-08-18** by opening it and reading the window title via System Events, which
returned literally `Login Items & Extensions` — the same instrument gotcha #37 established
for the Full Disk Access link, and the same reason: a deep link that silently opens the
wrong pane is indistinguishable from one that works until a human looks.

## Errors must be visible

`register()` and `unregister()` both `throw`. Both failures surface in the row — the row
reads its status back after the attempt, so a failed toggle presents as "still off" plus the
thrown reason, rather than as a switch that slides and does nothing.

This is not defensive padding. Gotcha #37 records a row whose Allow button silently did
nothing for exactly this reason: `SFSafariApplication.showPreferencesForExtension`'s
completion handler is optional, the error channel was discarded, and the failure looked like
a broken extension. A toggle that lies is the worst thing this window can do, because the
window exists to tell the truth about state.

Note also that `register()` succeeding does **not** mean the item survives: the user can
switch it off in System Settings afterwards, which is what `.requiresApproval` reports. The
row reflects the system's state on every refresh; it never caches its own optimism.

## Testing

`SMAppService` is wrapped behind a minimal protocol (status / register / unregister) so the
mapping and the toggle logic can be driven with a fake, the same split `BannerPlanner` uses
and for the same reason: the real API only works under conditions a unit test cannot create.

Covered:
- Every `SMAppService.Status` → `PermissionStatus` mapping, including `.notFound`.
- Toggling on and off calls register / unregister respectively.
- A throwing `register()` leaves the row off and surfaces the reason — mutation-checked by
  reverting the error handling and confirming the test goes red.

**Not covered, stated plainly rather than implied:** the real `SMAppService` call. Nothing
in the suite proves macOS actually registers the app — that needs a human toggling the row
and confirming Carabiner appears in System Settings → Login Items & Extensions, and that it
is running after a reboot or a log out/in. Until someone does that, this feature is
"implemented", not "working" — the same standard the extension checklist holds itself to.

## Known limitation

A login item registered while the app lives in `~/Applications` refers to that path. Moving
the bundle later leaves a stale registration, and the fix is to toggle the row off and on.
Not worth detecting: it is rare, self-inflicted, and the row's live status shows the truth
either way. Related: gotcha #27, where duplicate copies of this bundle id in two locations
have already caused a day of confusion once.

## Verification checklist (needs a human)

1. Toggle on → Carabiner appears in System Settings → Login Items & Extensions.
2. Toggle off → it disappears.
3. Switch it off in System Settings while the app runs → the row reads `.denied` on next
   refresh and offers "Open System Settings", not "Allow".
4. Log out and back in → Carabiner is running, and clicking an Instagram button downloads
   with **no** "Open Carabiner?" prompt. This is the whole point of the feature; it is the
   one step that actually proves it.
