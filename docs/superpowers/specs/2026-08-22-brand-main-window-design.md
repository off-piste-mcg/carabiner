# Brand main window — OFF-PISTE skin + in-window Settings panel

**Date:** 2026-08-22
**Status:** Approved by Wisse (design conversation, this date)

## What this is

A visual redesign of `Carabiner.app`'s main window to the OFF-PISTE brand look —
the grainy gradient canvas, ABC Diatype Mono uppercase type, yellow pill accents —
plus a structural change: **Settings moves into the main window** as a slide-in
panel, and the separate Setup & Permissions window goes away.

This is a re-skin and a re-housing. **Zero behavior changes**: the engine, the
menu bar, notifications, Dock drop, hotkey, `GrabHistoryStore`, `GrabGate`, and
the carousel dialog (gotcha #9 — stays native) are untouched.

## Brand assets (in `app/Carabiner/BrandAssets/`, supplied by Wisse 2026-08-22)

| File | What | Wiring |
|---|---|---|
| `bg.jpg` | The gradient canvas, 2880×1607 | Bundle resource, drawn `scaledToFill` behind everything |
| `ABCDiatypeMono-Regular.otf` | Brand mono font (licensed) | Bundled via `ATSApplicationFontsPath` in `project.yml`'s Info properties |
| `wordmark.svg` | OFF-PISTE™ wordmark | Asset catalog, vector preserved |

**Brand yellow: `#FAFA78`** — sampled from the approved mockup's GRAB pill
(`#F7FA7A`) and top-right pill (`#FCFA76`), which agree. One named color
(`BrandYellow`) in the asset catalog; nothing hardcodes a hex elsewhere.

## 1 · Window & chrome

- Same `NSWindow` in `MainWindowController`, restyled: `titlebarAppearsTransparent`,
  `.fullSizeContentView` added to the style mask, empty title. Traffic lights stay —
  native close/minimize, no custom chrome.
- `bg.jpg` bleeds edge-to-edge under the titlebar.
- Default ~720×460, resizable, min 640×420. Background scales to fill; content is
  laid out against the window, not the image.
- The window commits to the artwork: no light/dark variants. `NSAppearance` is
  irrelevant to the canvas; any remaining native controls get `.light` so they
  never go dark-on-dark over the pale background. (The menu-bar status item and
  notifications are unaffected.)

## 2 · The grabs canvas (default state)

Replaces `MainView`'s stacked grab-box + list. Same `MainViewModel`, same
`GrabHistoryStore` — the view is the only rewrite.

- **Center, optically slightly above middle:** the link bar — a custom-drawn
  translucent white pill (`PASTE YOUR LINK` placeholder, Diatype Mono, uppercase)
  and the yellow `GRAB` pill beside it. Same behavior as today: submit on Return
  or click, disabled while grabbing, whole canvas is a drag-and-drop target for
  URLs (the existing `loadDroppedURL` logic moves over unchanged).
- **Under the bar:** stage/feedback line in small mono caps (`SAVING TO
  DOWNLOADS…`; errors likewise), with a small yellow pulsing dot while a grab is
  running. Renders `model.stage` / `model.feedback` exactly as the old view did —
  uppercased for style only.
- **RECENT:** only when history is non-empty. A `RECENT` mono caps header, then
  ghosted rows: 24px QuickLook thumbnail (rounded 4), `FILENAME` truncated
  middle, `@USER · 2M` in secondary. Behavior identical to today's `HistoryRow`:
  double-click opens, context menu Reveal in Finder / Open, missing-file rows
  dimmed further with actions disabled. The area holds ~5 rows and scrolls
  (hidden indicators) for the rest of the 50.
- **Empty state:** nothing. The canvas stays clean — no "No grabs yet" copy.
- **Corner furniture** (all Diatype Mono, small):
  - Top-right: the yellow pill — the Settings trigger (hover slightly enlarges;
    `.help("Settings")`).
  - Right edge, rotated 90°: `V. <short version>` from the bundle (the mockup's
    `Y. 2026` slot, made useful).
  - Bottom-left: `⌃⌥⌘V` hotkey hint.
  - Bottom-right: wordmark (vector, small) + live clock `09:32AM` style,
    updating on the minute.

## 3 · Settings panel

- Slides in from the right, ~300pt wide, over the hero, which dims (black ~25%).
  ✕ button, Esc, or clicking the dimmed area closes it. Plain quick ease
  animation; no springs.
- Content = the **existing Setup & Permissions rows restyled**: notifications,
  browser Automation, System Events, Full Disk Access, browser-extension rows,
  Launch at login, hotkey test. Mono caps labels, yellow filled dot = granted,
  hollow = not, `ALLOW` as small yellow text buttons.
- **`OnboardingViewModel` is reused untouched.** Every permission behavior that
  was earned the hard way — the FDA open()-probe and forced relaunch (#28, #37),
  the Safari `showPreferencesForExtension` completion handler (#37), the
  Launch-at-login `.notFound` mapping (#40), `browserButtonStatus` consulting
  `GrabServer.state` — lives in the view model and is not touched. Only the view
  layer (`OnboardingView`) is replaced by the panel's brand-styled equivalent.
- **The separate window goes away.** `OnboardingWindowController` is retired.
  ⌘, (Settings…), the status-menu item, and first-launch auto-open all open the
  main window **with the panel open**. The Dock click keeps opening the main
  window on the grabs canvas, as it does today.
  `MainViewModel` gains a `settingsShown: Bool` published flag and a
  `showSettings()` entry point that `MenuBarController` calls where it previously
  showed the onboarding window.

## 4 · What explicitly does not change

- `carabiner` (the engine), `GrabRunner`, `GrabServer`, `GrabGate`,
  `GrabHistoryStore`, `MenuBarController`'s grab funnel, `Notifier`/`BannerPlanner`,
  the status item + progress ring, Dock drop routing, the hotkey.
- The carousel dialog stays the stock native `osascript` dialog (gotcha #9).
- The Shortcut path, the browser extension, everything server-side.

## 5 · Risks & mitigations

- **Re-housing the verified permission rows.** The old window's rows were
  human-verified 2026-08-17. Keeping the view model byte-identical protects the
  logic, but the *view* wiring is new — so the manual pass below re-checks each
  row's Allow inside the panel. (Gotcha #34: the bug class lives in the wiring.)
- **Font licensing** is Wisse's call; the file was supplied deliberately.
- **`bg.jpg` is 4.2 MB** in the bundle — acceptable; no recompression step.
- **First-launch flow**: previously the onboarding window auto-opened on first
  launch. Now the main window opens with the panel shown — same trigger point in
  `App.swift`/`MenuBarController`, same "only thing that prompts on fresh
  installs" property.

## Revision 2026-08-24 — the left rail (supersedes §2's RECENT section and §3's panel presentation)

After the first build, Wisse iterated with two mockups. The navigation is now a
**persistent collapsed rail on the left that expands in place**:

- **At rest:** a slim frosted rounded rail floating inset on the left edge (icons
  only, top-aligned: grabs, settings). The canvas is otherwise a pure poster —
  the RECENT list under the bar and the yellow settings pill top-right are GONE.
- **On click:** the rail expands into a ~300pt frosted rounded card (same inset
  float, no dark scrim — the hero stays visible beside it). Yellow ✕ pill at the
  card's top-left closes it; Esc and clicking the canvas also collapse. One panel
  at a time.
- **RECENT GRABS card:** header + rows — thumbnail, a content summary derived
  from the saved files' extensions (`2 IMAGES, 1 VIDEO`), and `FROM @USER` +
  relative time. Unparsable entries (the YouTube/Pinterest `saved to ~/Downloads`
  rows) render as `SAVED TO DOWNLOADS`, dimmed. Row behaviors carry over:
  double-click opens, context menu Reveal/Open, missing-file dimming.
- **SETTINGS card:** the same permission-row content as before, re-housed in the
  card chrome. `OnboardingViewModel` still untouched.
- **Auto-peek:** when a window-initiated grab finishes successfully and no panel
  is open, the grabs card slides out to show the new row, then collapses after a
  few seconds. A manual open is never auto-collapsed.
- Model state: `settingsShown: Bool` becomes `panel: SidePanel?` (`.grabs` /
  `.settings`); ⌘,/status-menu/first-launch set `.settings`; window close resets
  to nil; the hotkey-test cancel now fires when the panel leaves `.settings`.

## 6 · Verification

- Existing unit tests (view models, planners, gates) must pass unchanged —
  nothing they cover is edited.
- New pure logic is minimal (clock formatting, settings-shown routing); test
  where a pure function exists, don't force theatre (gotcha #34's neighbor).
- Manual pass after build: real grab through the new bar (file lands, banner,
  history row appears); drag-and-drop still submits; each settings row renders
  its true state and its Allow still acts (spot-check at minimum: notifications,
  Launch at login toggle both directions, hotkey test); ⌘, and status-menu
  Settings open the panel; Esc/✕/scrim close it; window resize keeps the
  composition sane at min size.
- Build prerequisites unchanged (`fetch-deps.sh`, `extension/build.sh`,
  `CARABINER_TEAM_ID`, xcodegen — per CLAUDE.md).
