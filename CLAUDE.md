# CLAUDE.md — Carabiner

**Carabiner** — a small, trustworthy piece of kit that clips onto media and holds it.
A **local** macOS tool: paste/share a URL → clean, QuickTime-openable file in `~/Downloads`.

Read this first. It captures the built tool plus the non-obvious gotchas discovered the
hard way — treat "Known gotchas" as settled fact, not theory to re-test.

## What this project is

A local macOS tool that takes a pasted URL (Instagram first; YouTube / Pinterest
secondary), auto-detects image vs video, handles carousels (all slides OR one specific
slide via `img_index`), and saves clean files.

**Two front ends, one engine.** The bash `carabiner` script does all the grabbing; both
front ends just call it.

1. **`Carabiner.app`** (`app/`) — the native menu-bar app. **This is the primary UX going
   forward.** Open a post → ⌃⌥⌘V → file in `~/Downloads` + a branded notification.
   Currently dev-machine only: distribution needs Developer ID signing (spec phase 4).
2. **The macOS Shortcut** — the zero-install fallback for anyone who doesn't want the app,
   and how the tool shipped originally. Stays supported.

They **cannot share a hotkey** — a global chord has exactly one owner (gotcha #14). If a
teammate installs the app, they unbind the Shortcut's hotkey, or vice versa.

## The single most important architectural fact

**Everything works because it runs locally as the logged-in user, using their own browser
cookies.** Do NOT turn this into a hosted website that accepts links from strangers.
Without a per-user browser session, Instagram refuses anonymous requests ("empty media
response"), and a public backend would need its own IG login → rate-limited/banned, and
against IG ToS. Keep it local. It's still shareable — each person runs it on their own Mac.

## Current state — BUILT

- **`carabiner`** — the unified tool. Parses the URL, detects platform, and routes:
  - **video → `yt-dlp`** then re-encode to 8-bit `yuv420p` H.264 (QuickTime-safe).
  - **image / full carousel → `gallery-dl`** (yt-dlp refuses carousel images).
  - Honours `?img_index=N`; flags: `-a` (all slides), `-s N` (one slide), `--silent`,
    `-o DIR`, `-b BROWSER`. Deterministic names from the shortcode
    (`_fixed`, `_sN`, `_silent`). Under `-a`, gallery-dl videos are re-encoded too.
  - **No-URL invocation** (for the hotkey): `resolve_url` reads the frontmost browser
    tab via AppleScript (Chrome/Safari/Brave/Edge/Arc), falling back to the clipboard —
    so you just open a post and fire the hotkey, no copying. See gotcha #8.
  - **Self-heals PATH**: exports `/opt/homebrew/bin:/usr/local/bin` so it finds its deps
    under the stripped-down environment Shortcuts/hotkeys provide. See gotcha #8.
  - **Notifications**: when headless (`[ -t 1 ]` is false, i.e. launched from the
    hotkey), fires a plain native macOS notification on success (filename summary) and on
    failure (the error) via `osascript display notification`. Silent in a terminal.
    Generic (Script Editor) icon — see gotcha #10 for why it isn't the logo.
    **Suppressed entirely when `CARABINER_NO_NOTIFY` is set**, which is how the app takes
    over notifications with its own branded banner. If you ever see *two* banners, or an
    unbranded one while using the app, the app is calling a copy of this script that
    predates that gate.
- **`setup.sh`** — installs the three deps via Homebrew, links `carabiner`/`clip`/`crab`.
- **`README.md`** — team setup + the macOS Shortcut wiring.
- **Shipped:** public repo at `github.com/off-piste-mcg/carabiner` (clone + `./setup.sh`).
  The macOS Shortcut is shared as an **iCloud link** in the README
  (`icloud.com/shortcuts/1633ebc20bf04369a20ccab25b38dc8b`) — one-click add, then each
  user sets their own hotkey (keyboard shortcuts aren't stored in a shared shortcut).
  The shortcut's Run Shell Script uses a portable one-liner so it finds `carabiner` on
  both Apple Silicon (`/opt/homebrew`) and Intel (`/usr/local`).
- **`app/`** — **`Carabiner.app`, the native Swift/AppKit menu-bar app (Phase 1 done).**
  Menu-bar only (`LSUIElement`), OFF-PISTE logo status item, global ⌃⌥⌘V hotkey. Reads the
  front browser tab via AppleScript, shells out to this repo's `carabiner` script, and
  posts a **branded** notification with the filename (or "N files"). Swift owns the
  experience; bash still owns the grabbing — the app never re-implements the pipeline.
  Built with XcodeGen (`xcodegen generate` from `app/`; the `.xcodeproj` and the generated
  `Info.plist` are gitignored — `project.yml` is the single source of truth). **Requires a
  development code signature to work at all — see gotcha #11.** Build with:
  ```bash
  export CARABINER_TEAM_ID=$(security find-certificate -a -c "Apple Development" -p \
    | openssl x509 -noout -subject | tr ',/' '\n\n' \
    | sed -nE 's/.*OU=([A-Z0-9]{10}).*/\1/p' | head -1)
  cd app && xcodegen generate && xcodebuild -scheme Carabiner -configuration Debug build
  ```
  The app and the Shortcut cannot share a hotkey (gotcha #14) — pick one.
- **`files/`** — original seed: proven `igdl`/`igdls` functions + the `ig-grab.js`
  bookmarklet. Reference only.

**Decision that was made:** images fold into the paste-a-link flow via gallery-dl (the
click-to-pick bookmarklet is retired to `files/` as reference, not part of the tool).

**Decision that was made:** the app is the primary UX going forward; the Shortcut stays as
the zero-install fallback for anyone who doesn't want the app. Both drive the same script.

## Working on this project

**Where things are:** `carabiner` (the engine, bash, repo root) · `app/` (the Swift app)
· `docs/superpowers/specs/` (design) · `docs/superpowers/plans/` (implementation plans)
· `files/` (historical reference only, not part of the tool).

**The script** needs no build. Test it directly — it is the fastest way to isolate whether
a bug is in the app or the engine:
```bash
CARABINER_NO_NOTIFY=1 ./carabiner -s 1 'https://www.instagram.com/p/SHORTCODE/'
bash -n carabiner   # syntax check
```

**The app** is generated by XcodeGen, so `Carabiner.xcodeproj` and `app/Carabiner/Info.plist`
are gitignored build products — edit `app/project.yml`, never them. Every build signs
(gotcha #11), so the team ID must be in the environment first:
```bash
export CARABINER_TEAM_ID=$(security find-certificate -a -c "Apple Development" -p \
  | openssl x509 -noout -subject | tr ',/' '\n\n' \
  | sed -nE 's/.*OU=([A-Z0-9]{10}).*/\1/p' | head -1)
cd app && xcodegen generate
xcodebuild -project Carabiner.xcodeproj -scheme Carabiner -destination 'platform=macOS' test
xcodebuild -project Carabiner.xcodeproj -scheme Carabiner -configuration Debug \
  -derivedDataPath build build
```
Install and run it — **always launch the bundle, never the inner binary**, or notifications
break (gotcha #11):
```bash
pkill -x Carabiner; rm -rf ~/Applications/Carabiner.app
cp -R build/Build/Products/Debug/Carabiner.app ~/Applications/ && open ~/Applications/Carabiner.app
```
Leave no unsigned copy of the same bundle id anywhere on disk — a stale `build/` or
DerivedData copy silently poisons notifications for the signed one.

**Debugging the app.** It logs every meaningful step (`grab hotkey registered as …`,
`grab hotkey fired`, `grabbing <url>`, `grab succeeded — <file>`). Those are `NSLog`, so
they go to the unified log — but `log show` is often unreadable from a sandboxed shell. The
reliable way to read them is to run the inner binary with output redirected, accepting that
notifications won't work in that mode:
```bash
~/Applications/Carabiner.app/Contents/MacOS/Carabiner > /tmp/carabiner.log 2>&1 &
```

**Verifying a grab worked — do NOT trust timestamps.** gallery-dl preserves Instagram's
original mtime *and* birth time, so a freshly downloaded image can be dated weeks ago and
`ls -lt` / `find -newermt` will not show it. Videos differ (ffmpeg re-encodes, so they get
a real time), which makes the trap worse. Snapshot filenames and diff:
```bash
ls -1 ~/Downloads > /tmp/before.txt   # …grab…   then:
ls -1 ~/Downloads | diff /tmp/before.txt - | grep '^>'
```

## Where we are / what's next

Phase 1 of the app is **done and merged** (see the spec's phasing section, corrected after
the fact). Next is **Phase 2, bundling the binaries** — and it has a known blocker to fix
*first*: `carabiner` line 37 re-prepends Homebrew to `PATH` ahead of anything the app sets,
so bundled binaries get silently shadowed on any machine that also has Homebrew's yt-dlp.
It will look like bundling works. Details in the spec.

## Working logic (proven — reuse, don't reinvent)

**Video (with sound):**
```bash
yt-dlp --cookies-from-browser chrome -o "src.%(ext)s" "URL"
ffmpeg -y -i "src.mp4" -c:v libx264 -c:a aac -pix_fmt yuv420p "OUT.mp4"
```
**Video (silent):** add `-f "bv"` to yt-dlp and `-an` to ffmpeg (drop `-c:a aac`).

**Shortcode parse** (`/p/`, `/reel/`, `/reels/`, `/tv/`):
```bash
sed -nE 's#.*/(p|reel|reels|tv)/([^/?]+).*#\2#p'
```

**Carousel:** yt-dlp `--playlist-items N`; gallery-dl `--range N`. Parse `img_index=N`
from the URL for "just this slide".

## Known gotchas (settled — do not re-litigate by trial and error)

1. **Cookies are mandatory.** Anonymous IG returns "empty media response".
   `--cookies-from-browser chrome` (or safari/firefox/brave/edge) is required. Both
   yt-dlp and gallery-dl read them.
2. **IG videos are streaming blobs.** A browser/bookmarklet cannot save them (`<video>`
   src is a `blob:` MediaSource, assembled from separate audio+video streams). yt-dlp is
   required — this is why the tool can't be pure-browser.
3. **QuickTime rejects IG's pixel formats.** Files download but won't open (esp.
   AI-generated 10-bit / yuv444p). Fix = re-encode to 8-bit `-pix_fmt yuv420p`. The full
   libx264 re-encode is the guaranteed fix and the safe default.
4. **yt-dlp will NOT serve carousel images** ("No video formats found!"). Use
   **gallery-dl** for images and full-carousel grabs (reads the same browser cookies).
   The tool detects this: it tries yt-dlp, and on "no video" falls back to gallery-dl.
5. **Cross-origin `download` attribute fails** (image on cdninstagram.com, page on
   instagram.com) — historical note explaining the old bookmarklet's open-a-tab fallback.
   Not relevant to the shell tool.
6. **Home-vs-Downloads confusion.** The tool writes to `~/Downloads` (or `-o DIR`), never
   the invocation directory.
7. **Filename guessing bites.** yt-dlp's `%(uploader_id)s` is a numeric ID, not the
   handle. Names come deterministically from the shortcode.
8. **macOS Shortcuts hand you a minimal environment.** A Shortcut/Quick-Action/hotkey
   runs the script with a bare `PATH` (`/usr/bin:/bin:/usr/sbin:/sbin`) that excludes
   `/opt/homebrew/bin` — so bare `yt-dlp`/`gallery-dl`/`ffmpeg` calls fail even though a
   terminal run works. Carabiner fixes its own `PATH` at the top. Also: a global hotkey
   has no notion of "the post you're looking at", so Carabiner reads the front browser
   tab via `osascript` (both `osascript` and `pbpaste` live in `/usr/bin`, so they
   survive the minimal PATH). Firefox exposes no active-tab AppleScript → clipboard.
9. **The carousel prompt is intentionally a plain native dialog — don't re-brand it.**
   We explored swiftDialog (branded, needs a password'd cask install) and a custom
   Swift + WKWebView dialog (pixel-perfect, but needs Xcode to build per-machine and a
   downloaded binary trips Gatekeeper). Both were rejected: Carabiner is shared as a
   repo each teammate runs on their own Mac, and a branded dialog would look different
   (or break) depending on what they have installed. The native `osascript` dialog is
   the only option that's zero-dependency and identical on every Mac. Consistency won
   over polish — a deliberate decision, not a missing feature.
10. **Notifications are a plain native banner — a custom logo icon isn't worth it.**
    `osascript display notification` reliably banners but is attributed to Script Editor
    (generic icon), and that icon can't be changed. We built the obvious fix — a
    `Carabiner.app` AppleScript applet with the logo baked into an Apple rounded-rect
    `.icns` — and it only half-worked: the name showed but the icon stayed generic (the
    notification-icon cache is keyed by bundle id), and the moment we gave it a real
    bundle id macOS treated it as a new, UN-authorised app and dropped its notifications
    entirely. Custom-icon notifications require per-app notification authorisation granted
    **per machine** (and unsigned applets are flaky about even appearing in System
    Settings to grant) — the same portability problem as the branded dialog (gotcha #9).
    So notifications stay plain. Don't re-attempt the applet route for this shared tool.
    (`LOGO.jpg` is kept in the repo as the brand asset, but nothing consumes it.)

    **Superseded for `Carabiner.app` (2026-07-29).** The applet route was the wrong
    vehicle, not the wrong goal. A *signed* app bundle posting via
    `UNUserNotificationCenter` gets the logo, the app name, and a real authorisation
    prompt — verified working. The shell tool keeps its plain banner; the app is branded.
    See gotcha #11 for the condition that makes it work.

11. **The app's branded notification REQUIRES a real code signature — this is not
    deferrable to a distribution phase.** macOS refuses to register an ad-hoc /
    linker-signed bundle for user notifications: `requestAuthorization` fails instantly
    with `UNErrorDomain error 1` (`notificationsNotAllowed`), **no prompt is ever shown**,
    and every `add(request)` fails. Worse, an unsigned copy of the same bundle id anywhere
    on disk registers a team-less `NOTIFICATION#:com.offpiste.carabiner` record with
    LaunchServices that poisons the signed one — so a stray `xcodebuild` output in
    DerivedData silently breaks notifications for the properly signed app. Two consequences:
    every build signs (`CODE_SIGN_STYLE: Automatic` in `app/project.yml`), and unsigned
    build products must not be left lying around. Launch matters too: launch the bundle
    (`open`), never the inner binary — direct exec skips LaunchServices, so the bundle
    identity `UNUserNotificationCenter` needs is missing and authorisation fails.

12. **The Team ID is in the certificate's OU field, NOT the parenthetical in the identity
    name.** `security find-identity` prints `Apple Development: you@example.com (3KQ6AH5M2C)`
    — that parenthetical is the *agent* ID, and signing with it fails with "No signing
    certificate ... matching team ID". The real Team ID:
    ```bash
    security find-certificate -a -c "Apple Development" -p \
      | openssl x509 -noout -subject | tr ',/' '\n\n' \
      | sed -nE 's/.*OU=([A-Z0-9]{10}).*/\1/p' | head -1
    ```

13. **iCloud-synced folders break `codesign`.** This repo lives under `~/Documents`, which
    is iCloud-synced, and the file provider stamps `com.apple.FinderInfo` (plus
    `com.apple.fileprovider.fpfs#P`) onto the built `.app`. `codesign` rejects those:
    *"resource fork, Finder information, or similar detritus not allowed"*. `app/project.yml`
    carries a `postBuildScripts` phase that runs `xattr -cr` on the bundle — post-build
    scripts run *before* Xcode's CodeSign step, which is why that is the right hook.

14. **A global hotkey is exclusive, and losing it is silent.** `RegisterEventHotKey` fails
    outright if another app already owns the chord — and neither it nor the
    `KeyboardShortcuts` package reports that. While the macOS Shortcut was still bound to
    ⌃⌥⌘V, every press went to the Shortcut and the app never heard about it, which looked
    exactly like a broken app. The app now logs the chord it registered and every fire.
    Only one thing can own a chord: if the app has the hotkey, unbind the Shortcut's.

## Dependencies

- `yt-dlp` — video (IG/YouTube/etc.)
- `ffmpeg` — the re-encode/remux step
- `gallery-dl` — images + full carousels (fixes gotcha #4)

The carousel prompt ("just this slide or the whole set?") is a plain native macOS
dialog (`osascript display dialog`) — deliberately unbranded and dependency-free. See
gotcha #9 before "improving" it.

## Conventions

- Bash, macOS/zsh target. Keep it dependency-light beyond the three tools above.
- Deterministic filenames from shortcode; `_fixed` for re-encoded video; `_sN` for a
  specific slide; `_silent` for audio-stripped.
- `-y` on ffmpeg to overwrite cleanly; clean up temp files after.
