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
    under the stripped-down environment Shortcuts/hotkeys provide (gotcha #8) — and, when
    the app supplies bundled binaries via `CARABINER_BIN`, prepends that ahead of
    Homebrew so the bundled copies win instead of being silently shadowed (gotcha #17).
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
  Menu-bar only (`LSUIElement`), OFF-PISTE logo status item, global ⌃⌥⌘V hotkey. The status
  item and the notification use *different* assets: the menu bar draws the `StatusIcon`
  vector asset (the SVG, template-rendered so macOS tints it to the bar), while the branded
  notification keeps the full-colour `AppIcon` — `UNUserNotificationCenter` always takes its
  icon from the bundle icon, so the two never need to match. Reads the
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
- **`Carabiner_svg.svg`** (repo root) — the original brand-source SVG the status-bar icon
  was derived from. Not a stray duplicate of `app/Carabiner/Assets.xcassets/StatusIcon.imageset/carabiner-status.svg`:
  that asset-catalog copy is cropped to the mark's own bounds for the menu bar, while the
  root file is the uncropped source. Keep both.

**Decision that was made:** images fold into the paste-a-link flow via gallery-dl (the
click-to-pick bookmarklet is retired to `files/` as reference, not part of the tool).

**Decision that was made:** the app is the primary UX going forward; the Shortcut stays as
the zero-install fallback for anyone who doesn't want the app. Both drive the same script.

## Working on this project

**Where things are:** `carabiner` (the engine, bash, repo root) · `app/` (the Swift app)
· `test/` (offline shell tests, no network — `test-path.sh` covers the `CARABINER_BIN`
resolution order) · `.github/workflows/build-deps.yml` (manual-dispatch CI that builds
the bundled ffmpeg/gallery-dl — see "Where we are / what's next") · `docs/superpowers/specs/`
(design) · `docs/superpowers/plans/` (implementation plans) · `files/` (historical
reference only, not part of the tool).

**The `CARABINER_BIN` contract** is the interface between the two front ends and the
engine: the app sets it to its `Contents/Resources/bin` directory when a build has
bundled binaries, and the script prepends it ahead of Homebrew (gotcha #17). Unset
(the Shortcut, a terminal run, or an unbundled dev build of the app), the script's PATH
is unchanged from before Phase 2 existed. Never read `CARABINER_BIN` for anything other
than PATH order — it is not a feature flag, just where to look first.

**The script** needs no build. Test it directly — it is the fastest way to isolate whether
a bug is in the app or the engine:
```bash
CARABINER_NO_NOTIFY=1 ./carabiner -s 1 'https://www.instagram.com/p/SHORTCODE/'
bash -n carabiner   # syntax check
./test/test-path.sh # CARABINER_BIN / PATH resolution order, offline (no network, no grabs)
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

**Foot-gun: the running app executes a bundled snapshot, not your working copy.**
`GrabRunner.swift` runs `Bundle.main`'s copy of the script at
`Contents/Resources/carabiner` (see `bundledExecutable()`) — a file XcodeGen copies in at
build time from `app/project.yml`'s `../carabiner` resource entry, not a symlink back into
the repo. Editing the repo's `carabiner` and re-running the *already-installed* app tests
nothing: you're still exercising whatever was in `Resources/` at the last build. This is
new since Phase 2 bundling started — before it, debugging via the app and debugging via
`./carabiner` directly were the same file. Rebuild and reinstall (`xcodegen generate` →
`xcodebuild` → the `cp -R`/`open` steps above) before trusting an app-driven test of a
script change; `CARABINER_NO_NOTIFY=1 ./carabiner …` directly is still the fast path for
iterating on the script itself.

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
the fact). Phase 2, bundling the binaries, is **partially done**:

- **Done (tasks 1-4):** the `CARABINER_BIN` PATH contract (gotcha #17) so bundled binaries
  win over Homebrew instead of being silently shadowed by it; the app-side wiring in
  `GrabRunner.swift` that points `CARABINER_BIN` at `Contents/Resources/bin` when a build
  has one; and `.github/workflows/build-deps.yml`, a manual-dispatch CI workflow that
  builds a static universal (arm64 + x86_64) ffmpeg and a universal2 gallery-dl from
  source. Building them ourselves is the only option: upstream ships no official macOS
  binary for gallery-dl at all, and no official static ffmpeg build — both projects
  expect you to compile or use a packager (Homebrew, in this repo's own case).
- **Outstanding (tasks 5-7):** pinning the built artifacts as a checksum-verified fetch
  (so `fetch-deps.sh`, once it exists, downloads a known-good `deps.lock` entry rather
  than trusting whatever a workflow run happened to produce), actually copying and
  signing every bundled Mach-O into the app bundle (so `CARABINER_BIN` points at
  something real instead of an empty/missing directory), and the no-Homebrew
  verification pass (task 5's fetch and task 6's signing can each look like they worked
  on a dev machine that has Homebrew installed as a fallback — gotcha #17 is exactly
  this trap one layer up, and it applies again here). Details in the spec.

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

   **Partly superseded (2026-07-30).** The objection was to branded dialog *engines*, not
   to branding as such. `display dialog … with icon` takes a plain `.icns`, so the prompt
   now carries the OFF-PISTE logo from `assets/Carabiner.icns` — no cask, no per-machine
   Xcode build, identical on every Mac, and it brands the Shortcut's prompt too. The
   dialog itself is still the stock native one and should stay that way. Because the icon
   is a repo file, `carabiner` resolves its own real directory (following the symlinks
   `setup.sh` drops in Homebrew's bin) rather than trusting `$PWD`; if the file is
   missing the prompt falls back to `with icon note` instead of failing.
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

15. **`img_index` is absent on slide 1 — never use it to detect a carousel.** Instagram
    adds `?img_index=N` to the URL only once you navigate *off* the first slide, so a
    carousel you have just opened is indistinguishable from a single post by URL alone.
    The carousel prompt used to be gated on `img_index` being present, which meant
    opening a carousel and firing the hotkey straight away skipped the question entirely
    and silently grabbed all twelve slides — and it looked like the prompt was broken,
    because on any post you *had* scrolled it worked fine. Detection is now
    `ig_item_count` (a `gallery-dl -g` probe) on `/p/` URLs, with no `img_index` simply
    meaning slide 1. The probe is skipped for `/reel/`, `/reels/` and `/tv/`, which are
    always a single video, so reels don't pay for a network round-trip they can't use.

16. **Hardened Runtime silently kills the app's Apple Events — turn it on early, not at
    release time.** Notarization requires the Hardened Runtime, and under it an app may
    not *send* Apple Events without `com.apple.security.automation.apple-events`. That is
    Carabiner's entire input path (reading the front browser tab, and the System Events
    carousel dialog), so enabling it for the first time in a release build would mean the
    first notarized DMG is the first run of the real thing. It is on in every build now,
    with the entitlement declared in `app/project.yml`. `NSAppleEventsUsageDescription` is
    only the *text* of the permission prompt — the entitlement is permission to ask.
    Verify a build with:
    ```bash
    codesign -dv Carabiner.app 2>&1 | grep flags          # want flags=0x10000(runtime)
    codesign -d --entitlements - --xml Carabiner.app | plutil -p -
    ```
    Note `com.apple.security.get-task-allow` in that output: Xcode adds it to **Debug**
    builds only, and notarization **rejects** any binary carrying it. Notarize Release
    builds, never a Debug one.

17. **`carabiner`'s PATH order is the entire point of bundling — get it backwards and
    bundling silently does nothing.** Gotcha #8 explains why the script prepends
    `/opt/homebrew/bin:/usr/local/bin` at all: a global hotkey hands it a stripped-down
    PATH that can't find Homebrew's yt-dlp/ffmpeg/gallery-dl. That prepend used to run
    *unconditionally* — so once the app started bundling its own copies of those three
    tools, Homebrew still won the PATH race on any machine that also had them installed
    via `brew`. That's every dev machine this gets tested on, so bundling would have
    *looked* like it worked (the app runs fine) while silently grabbing the Homebrew
    binaries instead of the bundled ones — a regression nobody would see until a machine
    without Homebrew tried it and failed differently, or a Homebrew upgrade changed
    behaviour the bundled binaries were pinned against. The fix: `CARABINER_BIN`, set by
    the app (`GrabRunner.swift`) to its `Contents/Resources/bin` directory, is now
    prepended *ahead of* Homebrew — `$CARABINER_BIN:/opt/homebrew/bin:/usr/local/bin:$PATH`
    — so app-supplied binaries win, Homebrew is still the fallback for the Shortcut and
    terminal, and an unset `CARABINER_BIN` (an unbundled dev build) leaves the old
    behaviour byte-for-byte unchanged. The only honest way to test this is to move
    Homebrew's copies aside (`brew unlink yt-dlp ffmpeg gallery-dl` or rename them) and
    grab something for real — a PATH bug that Homebrew can silently absorb will pass
    every test run on a machine that has Homebrew installed. `test/test-path.sh` covers
    the resolution order offline (no network, stubbed binaries) so this doesn't require a
    real grab every time, but it does not substitute for the no-Homebrew check before
    trusting a bundled build.

## Dependencies

- `yt-dlp` — video (IG/YouTube/etc.)
- `ffmpeg` — the re-encode/remux step
- `gallery-dl` — images + full carousels (fixes gotcha #4)

The carousel prompt ("just this slide or the whole set?") is a plain native macOS
dialog (`osascript display dialog`) — the *dialog itself* stays the stock native one
deliberately (see gotcha #9), but it is no longer unbranded: it carries the OFF-PISTE
logo from `assets/Carabiner.icns`. See gotcha #9 before "improving" the dialog engine.

## Conventions

- Bash, macOS/zsh target. Keep it dependency-light beyond the three tools above.
- Deterministic filenames from shortcode; `_fixed` for re-encoded video; `_sN` for a
  specific slide; `_silent` for audio-stripped.
- `-y` on ffmpeg to overwrite cleanly; clean up temp files after.
