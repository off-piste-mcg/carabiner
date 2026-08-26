# First-run intro — design

**Date:** 2026-08-26
**Status:** Approved (Wisse), pre-implementation
**Prior art:** `2026-08-22-brand-main-window-design.md` (brand canvas, in-window
settings), `2026-08-02-onboarding-design.md` (the permission rows this hands off
to), `2026-08-12-browser-extension-design.md` (the front end card 2 announces)

## Problem

A teammate who downloads `Carabiner-0.2.0.dmg` and opens the app is shown a brand
canvas with a link field and — on a fresh install only — a panel of six permission
rows. That panel answers *what do I allow*. Nothing on screen answers *what is
this, and how do I use it*.

Three specific things go unsaid, and the third is the expensive one:

- **What it does.** "Paste a link, get a file" is obvious to us and to nobody else.
- **Why it exists.** Instagram's videos are streams, not files; what you save by
  hand usually will not play. That is the whole reason for the tool.
- **That the in-page Instagram button exists at all.** It is the biggest thing in
  0.2.0, it appears in a different application from this one, and today the only
  hint is a permission row titled "Instagram button". A user who never grants it
  never learns what they turned down.

## Decision (chosen from three options)

**A short explainer that hands off to the existing setup.** Three cards, a
full-canvas takeover of the main window on first run, ending in a button that
opens the settings panel already built.

Rejected:

- **One combined flow** (explain → grant notifications → grant browser access →
  … as steps). Every prompt would arrive with its reason attached, which is
  genuinely better, but it duplicates state `OnboardingViewModel` already renders
  and would leave two surfaces to keep in sync. The permission rows stay the
  single place setup lives.
- **Explain only, no handoff.** Simplest, and it recreates the failure the
  first-launch panel was built to prevent: real permission prompts arriving naked.

Also rejected, on shape rather than substance:

- **Its own `NSWindow`**, in the manner of the retired `OnboardingWindowController`.
  This branch deleted that pattern deliberately — two windows compete for focus and
  for `applicationShouldHandleReopen`, which already had to ignore
  `hasVisibleWindows` to work at all. An intro layer inside the one window keeps
  every Dock and reopen behaviour untouched.
- **Paging inside the 300pt rail card.** Smallest change, but 300pt is a sidebar
  note, not a welcome, and the headline does not fit.

## Content

The copy is part of the design, not a placeholder for implementation to invent.

**Card 1 — PASTE A LINK, GET THE FILE.**

> An Instagram video or photo becomes a clean file in your Downloads — one that
> QuickTime actually opens. Carabiner does the awkward part: Instagram's videos
> aren't files, they're streams, and what you can save by hand usually won't play.

**Card 2 — THREE WAYS TO ASK.**

> **On Instagram** — a small Carabiner button sits beside Save on every post, in
> Chrome and Safari.
> **From anywhere** — open a post and press ⌃⌥⌘V.
> **Here** — paste a link into this window and hit GRAB.

**Card 3 — WHAT TO EXPECT.**

> Carousels ask first: this slide, or all of them. Files land in ~/Downloads,
> named after the post. A banner tells you when it's done.
> It all runs on your Mac, using your own browser session — nothing is uploaded,
> and no account but yours is involved.

Card 3's primary button reads **SET UP PERMISSIONS →**.

Card 2 states the Chrome button as fact. At the time of writing the Chrome Web
Store listing does not exist, so a Chrome user cannot install it from the
Settings row (`chromeWebStoreURL` is still `PLACEHOLDER_ID`). This is a known
inconsistency, accepted here rather than hidden: the sentence is true of Safari
today and of Chrome the day the listing publishes, and softening it would make
the explainer stale in the other direction within a release. If the listing slips
far enough to matter, card 2's first line is one string to change.

## Mechanism

### Trigger and persistence

A **new** defaults key, `introShown`, independent of the existing
`onboardingShown` (`MainWindowController.settingsShownDefaultsKey`).

- Unseen → the window opens on launch with the intro over the canvas.
- Seen → launch behaves exactly as 0.2.0 does today.

Two keys rather than one, on purpose: `onboardingShown` means *this person has
been offered setup*, and it is already true on every 0.1.x and 0.2.0 install. An
upgrading teammate has never seen the intro, and the extension is new to them, so
they should get it. Reusing the old key would silently exclude exactly the people
the explainer is for.

### Flow

- NEXT pages 1 → 2 → 3. ← / → also page. The step dots are clickable to go back.
- **SKIP** sits top-right on every card, the last one included.
- **Both exits mark it seen**, as does closing the window while it is up. The
  intro must never be able to reappear because the user left by an unexpected door.
- **Finish** (SET UP PERMISSIONS) clears the intro and opens the settings panel —
  `settings.refreshAll()` then `model.panel = .settings`, the same pair the rail's
  gear already uses.
- **SKIP** clears the intro and leaves the canvas. The existing first-launch rule
  in `App.swift` still applies underneath, so a genuinely fresh install still gets
  the permissions panel exactly as in 0.2.0. Skipping the explainer must not be a
  way to end up with a silently non-working app.

### Reopening

A **"How Carabiner works"** item in the menu-bar menu, above "Settings…". It shows
the window with card 1 and does not touch `introShown` (already true by then).

No new rail icon. The rail was just reduced to two well-spaced destinations
(2026-08-24); a third icon would undo that for something wanted once.

### Structure

A new `app/Carabiner/MainWindow/Intro/`, split the way the settings panel already
is — content, state, persistence and presentation each addressable alone:

| File | Owns | Depends on |
|---|---|---|
| `IntroCard.swift` | The three cards as data (title + lines) | nothing |
| `IntroModel.swift` | `index`, `next()`, `back()`, `isLast` — paging state | `IntroCard` |
| `IntroGate.swift` | `shouldShow(defaults:)`, `markSeen(defaults:)` | `UserDefaults` |
| `IntroView.swift` | Presentation over `Brand.backgroundImage` | all three |

`IntroGate`'s functions take a `UserDefaults` **instance** rather than reaching for
`.standard`, which is what makes them testable for real instead of around — the
same correction applied to the history store's persistence tests.

Call sites, one line each: `MainView` branches to `IntroView` when the intro is
active (canvas content and rail hidden beneath it); `MainWindowController` gains
`showIntro()`; `App.swift`'s launch branch consults `IntroGate` before the existing
`onboardingShown` check; `MenuBarController` gains the menu item.

### Layout constraints

The window's minimum is 640×420 and the titlebar is transparent, so the intro's
top row must clear the traffic lights the way `SideRail` does (48pt). Copy must
wrap and fit at the minimum size, not merely at the 720×460 default — card 1's
body is the longest and is the one to check.

## Testing

**Unit** (`app/CarabinerTests`):

- `IntroGate` both directions, against a scratch `UserDefaults` suite: unseen →
  shows; seen → does not; `markSeen` persists across a fresh read.
- `IntroModel` paging bounds: `back()` at 0 and `next()` at the last card are
  no-ops, `isLast` is true only on card 3.
- `IntroCard`: exactly three cards, none with empty text.

**Mutation check, not a green count.** Revert the gate to the naive version
(always show, or read the wrong key) and confirm the tests go red. A test suite
that passes with the fix removed is theatre; this project has shipped that mistake
before (gotcha #34) and the guard is to actually perform the revert and look.

**Visual, on this machine.** Clear `introShown`, launch, and screenshot all three
cards at 720×460 **and** at the 640×420 minimum, checking for clipped copy. Then
confirm SET UP PERMISSIONS really opens the panel, SKIP really leaves the canvas,
and a second launch shows no intro.

**Not testable here:** how the intro reads to someone who has never used the tool.
That is the entire point of the feature and no test in this repo can speak to it —
it needs a teammate opening 0.3.0 cold.

## Out of scope

- Any change to the permission rows or `OnboardingViewModel`.
- Teaching the intro to detect what is already granted (e.g. skipping card 3 if
  everything is on). Setup state belongs to the panel.
- Video, animation between cards beyond a plain transition, or localisation.
