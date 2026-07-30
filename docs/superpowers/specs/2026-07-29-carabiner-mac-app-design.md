# Carabiner.app — native macOS menu-bar app (design)

**Date:** 2026-07-29
**Status:** Approved design, pre-implementation
**Owner:** OFF-PISTE (off-piste-mcg)

## Why

The shell-script + Shortcut version works, but onboarding is too heavy for 100+
non-technical colleagues: Terminal, Homebrew, `git clone`, `setup.sh`, the Shortcuts
"Allow Running Scripts" toggle, and a per-user hotkey. We want a **double-click install,
then it just lives in the menu bar** — zero Terminal, no Homebrew, no toggles.

Bonus wins a real signed app unlocks: the **branded logo notification** we abandoned
(see the shell tool's gotcha #10), and no more per-machine "Allow Running Scripts".

## Goal

A signed + notarized macOS menu-bar app that grabs Instagram / YouTube / Pinterest media
from the user's current browser tab to `~/Downloads`, running entirely locally on the
user's own browser cookies.

## Non-goals (YAGNI)

- **Cross-platform.** Colleagues are all on Mac. No Windows/Linux, no Tauri/Electron.
- **Mac App Store.** Sandboxing would block reading browser cookies. Ship a Developer-ID
  signed, notarized app directly (DMG + auto-update).
- **Rewriting the grab logic.** The proven `carabiner` bash pipeline is reused as-is.
- **New platforms/sources** beyond what the script already handles.

## Architecture

A thin **native Swift/AppKit menu-bar app** wrapping the **existing `carabiner` shell
script**, with the CLI tools **bundled inside the app**.

```
Carabiner.app/
  Contents/
    MacOS/Carabiner            ← Swift menu-bar app (the wrapper)
    Resources/
      bin/
        carabiner              ← the existing shell script (lightly adapted)
        yt-dlp                 ← bundled universal static binary
        ffmpeg                 ← bundled universal static binary
        gallery-dl             ← bundled universal static binary
      carabiner.icns           ← app + notification icon (OFF-PISTE logo)
```

**Division of labour:**
- **Swift owns the experience:** menu-bar item + menu, global hotkey, reading the front
  browser tab, the carousel "this slide / all?" popover (native, branded), branded
  notifications, permission prompts, settings, and auto-update.
- **Bash owns the grabbing:** the app invokes `Resources/bin/carabiner` with
  `PATH=Resources/bin` prepended, so its `yt-dlp`/`ffmpeg`/`gallery-dl` calls resolve to
  the bundled binaries — no Homebrew. All routing (video→yt-dlp+re-encode,
  image/carousel→gallery-dl, `img_index`, re-encode to QuickTime-safe yuv420p,
  deterministic names) is unchanged and already tested.

### Components

1. **MenuBarController** — `NSStatusItem` with the logo. Menu: *Grab current tab*,
   *Grab (all carousel slides)*, a browser picker (Chrome default), open-Downloads, and
   Quit. Also shows a brief "working…" state.
2. **Hotkey** — global shortcut (default ⌃⌥⌘V) via `RegisterEventHotKey` (Carbon) or the
   `KeyboardShortcuts` package. No Accessibility/Input-Monitoring permission required.
   User-rebindable in settings.
3. **TabReader** — gets the front browser tab URL via AppleScript (Chrome/Safari/Brave/
   Edge/Arc), clipboard fallback. Same logic as the script's `resolve_url`, moved to
   Swift so the app can decide when to prompt.
4. **GrabRunner** — runs `carabiner` via `Process`, streaming its result. The script is
   adapted to emit a machine-readable final line (or `--json`) so the app knows: success
   + filenames, failure + reason, or "carousel with N items, need a choice".
5. **CarouselPrompt** — native SwiftUI popover asking *this slide vs. all N* — fully
   branded (logo, blue accent, mono type). Replaces the shell's `osascript` dialog.
6. **Notifier** — `UNUserNotificationCenter`. Branded (app name + logo icon) because the
   app itself posts it. Success (filenames) / failure (reason).
7. **Updater** — Sparkle 2 (see Updates).

### Grab flow

1. Trigger (hotkey or menu) → **TabReader** resolves the URL.
2. **GrabRunner** asks the script whether it's a multi-item carousel (`gallery-dl -g`
   count, as today).
3. If carousel → **CarouselPrompt** (native) → run with the chosen mode; else grab
   straight away.
4. On finish → **Notifier** shows the branded result.

## Permissions (all one-time "Allow", no Terminal, no toggles)

- **Automation** — control the browser to read the active tab. First use → *"Carabiner
  wants to control Google Chrome"* → Allow.
- **Notifications** — first launch → *"Carabiner would like to send notifications"* →
  Allow. (Enables the branded banner.)
- **Keychain** — reading Chrome cookies can prompt for the *Chrome Safe Storage* key →
  *Always Allow* once. Inherent to `--cookies-from-browser`; unchanged from today.
- **Global hotkey** — no permission needed (`RegisterEventHotKey`).

Net: ~2–3 one-time Allow clicks on first run, then nothing.

## Bundled binaries

Ship universal static builds inside `Resources/bin/`:
- **yt-dlp** — official standalone `yt-dlp_macos` universal binary (~30 MB).
- **ffmpeg** — static universal build (~50 MB).
- **gallery-dl** — standalone executable build (~15 MB).

App size ~150 MB — normal for a Mac app. All three get code-signed as part of the app
bundle (needed for notarization: every Mach-O must be signed with Hardened Runtime).

## Updates (the #1 operational risk)

**yt-dlp breaks ~monthly** when Instagram changes. A frozen copy = the app silently dies
for everyone. Two layers:

1. **App auto-update via Sparkle 2** — signed appcast; colleagues get new versions
   automatically. Primary channel for any fix (app, script, or bundled tools).
2. **yt-dlp self-refresh (stretch)** — the app can download a newer `yt-dlp` to
   Application Support and prefer it over the bundled one, healing most breakages without
   a full app release. (Hardened Runtime can't modify the signed bundle in place, so the
   updated copy lives outside it.)

Appcast + DMGs hosted on **GitHub Releases** (the existing public repo).

## Distribution

- **Developer ID Application** signing + **notarytool** notarization + stapling.
- Ship a **DMG** ("drag Carabiner to Applications"), attached to a GitHub Release.
- README updated: for non-technical users, *"Download, drag to Applications, open."*
- The current clone-and-go script path stays in the repo for power users / fallback.

## Tech choices

- **Swift + AppKit** (`NSStatusItem`; or SwiftUI `MenuBarExtra`, macOS 13+). Native =
  small, fast, no runtime bloat.
- **KeyboardShortcuts** (Sindre Sorhus, MIT) for the rebindable global hotkey.
- **Sparkle 2** for auto-update.
- **Minimum macOS: 13 (Ventura).** Covers essentially all current studio machines.
- Build with Xcode; CI/signing can come later.

## Relationship to the current repo

**Decided:** same repo (`github.com/off-piste-mcg/carabiner`). The Swift app lives in an
`/app` subfolder and wraps the repo's existing `carabiner` script, so the two stay in
lockstep and updates ship together. The current clone-and-go script path stays for power
users / fallback.

## Suggested phasing (for the implementation plan)

> **Corrected 2026-07-29 after building Phase 1.** The original ordering below put signing
> at step 4 and treated the branded notification as a step-1 win. That is impossible:
> macOS will not register an ad-hoc-signed bundle for notifications at all, so the banner
> — the entire reason for building the app — cannot work before signing. **Development
> signing is a Phase 1 dependency** and now lives in `app/project.yml`. What stays in the
> distribution phase is *Developer ID* signing + notarization + stapling, which is a
> different certificate and a different problem. See gotchas #11–#13.

1. **Core app** ✅ *done*: menu-bar item + hotkey + TabReader + run the
   (Homebrew-installed) script → branded notification, **+ development code signing**
   (required for the notification to work at all). Proves the UX end-to-end on the dev
   machine.
2. **Bundle binaries**: ship yt-dlp/ffmpeg/gallery-dl inside; app no longer needs
   Homebrew. Adapt the script's result output for the app.
   > **Blocker to fix first:** `carabiner` line 37 does
   > `export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"`, re-prepending Homebrew *ahead
   > of* whatever the app sets. Bundled binaries will be silently shadowed on any machine
   > that also has Homebrew's yt-dlp — i.e. every machine this gets tested on, so it will
   > look like it works. Make that line conditional (e.g. skip when `CARABINER_BUNDLED` is
   > set) and decide deliberately whether the script stays shared with the Shortcut path.
3. **Native carousel popover** (replace the osascript dialog).
4. **Distribution**: Developer ID signing + notarization + stapling + DMG — a
   warning-free install for people outside the dev machine.
5. **Sparkle auto-update** + appcast on GitHub Releases.
6. (Stretch) **yt-dlp self-refresh.**

## Success criteria

- A non-technical colleague installs by: download DMG → drag to Applications → open →
  click Allow 2–3 times. No Terminal, no Homebrew, no Scripts toggle.
- Hotkey on an Instagram post → file in `~/Downloads` → branded notification.
- When Instagram breaks yt-dlp, we push an update and it heals automatically.
