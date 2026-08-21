# Carabiner as a regular Dock app — design

**Date:** 2026-08-21
**Status:** approved (Wisse, in conversation)

## What

Carabiner becomes an app "like all the others": a Dock tile with the running
indicator whenever it is running, pinnable via the Dock's own Options → Keep in
Dock, and clicking the Dock icon opens the Setup & Permissions window. The
menu-bar status item, hotkey, progress ring and loopback server are untouched —
this *adds* the Dock presence, it replaces nothing.

The alternative shapes considered and rejected with Wisse: a pinned-icon-only
scheme that keeps the app accessory (rejected — he wants the standard
running-app Dock tile), and dynamic policy switching that shows the tile only
while the settings window is open (rejected for the same reason).

## Changes

1. **Activation policy.** Remove `LSUIElement: true` from `app/project.yml`'s
   Info properties, and change `App.swift`'s
   `app.setActivationPolicy(.accessory)` to `.regular`.

2. **Dock click opens Setup & Permissions.** Implement
   `applicationShouldHandleReopen(_:hasVisibleWindows:)` in `AppDelegate`:
   when there are no visible windows, call the existing
   `MenuBarController.showOnboarding()`; when the window is already open, it
   is brought to front by the same call (`OnboardingWindowController` already
   activates and `makeKeyAndOrderFront`s). Return `false` — we handled it.
   - Clicking the pinned icon while the app is *not* running launches it.
     First launch auto-opens onboarding once (existing behavior); later
     Dock launches deliver a reopen event shortly after launch, which lands
     in the same handler and shows the window.
   - Launch at login sends no reopen event, so a login launch still starts
     quietly in the background with just the Dock tile. Desired.
   - The `carabiner://launch` cold-launch path (`application(_:open:)`) is
     unchanged and opens no window; a URL-scheme launch is not a reopen.

3. **A minimal main menu.** A regular app owns the top menu bar when
   frontmost; today Carabiner has none, so it would show an almost-empty bar.
   Build a minimal `NSApp.mainMenu` in code (no nib): the app menu (About
   Carabiner, Quit Carabiner ⌘Q) and an Edit menu with the standard
   Cut/Copy/Paste/Select All so text fields behave. No File/View/Window
   menus — nothing needs them.

4. **Closing the window keeps the app alive.**
   `applicationShouldTerminateAfterLastWindowClosed` stays false (the
   default). Closing Settings returns Carabiner to a background app with a
   Dock tile, like other menu-bar-plus-Dock apps.

## Trade-off accepted

The Dock tile appears during *every* run — including when the browser
extension cold-launches the app and when Launch at login starts it. That is
inherent to "an app like all the others" and was accepted explicitly.

## App icon (added same day, after the first Dock appearance)

The Dock tile exposed an icon problem the menu bar never could: the shipped
AppIcon was a pre-rounded Big-Sur-style tile (black rounded rect baked into
PNGs), and macOS 26 (Tahoe) puts legacy pre-rounded icons on a system glass
backplate, slightly scaled down — which rendered as a gray outline ring
around the tile. The ring was Tahoe's treatment, not the artwork.

Fix: a Tahoe-native Icon Composer document, `app/Carabiner/AppIcon.icon`
(hand-authored JSON — validated standalone with `xcrun actool` before wiring
it in). Solid black fill; one flat layer (`glass`, `specular`, `shadow`,
`translucency` all off) holding the full brand composition — mark plus rope,
corner to corner — extracted from `Carabiner_logo.jpg` as white-on-alpha via
CIMaskToAlpha. Layer `scale` is 0.5: the unit is native image pixels per
canvas point, and the source is 2048px on Tahoe's 1024pt canvas. The system
draws its own squircle and glass edge, so there is nothing for the backplate
to outline.

`AppIcon.appiconset` is deleted: actool generates the legacy `AppIcon.icns`
fallback for macOS ≤ 15 from the same `.icon` file.
`ASSETCATALOG_COMPILER_APPICON_NAME: AppIcon` is now set explicitly in
`project.yml` — xcodegen only infers it while an `.appiconset` exists.

## Testing

The reopen handler and menu are thin AppKit wiring: verified by hand (Dock
click with window closed / window open / app not running; Cmd+Q; pinning).
No pure logic worth unit-testing. The existing suite must stay green —
nothing it covers changes.
