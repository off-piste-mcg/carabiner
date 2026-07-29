# CLAUDE.md — Carabiner

**Carabiner** — a small, trustworthy piece of kit that clips onto media and holds it.
A **local** macOS tool: paste/share a URL → clean, QuickTime-openable file in `~/Downloads`.

Read this first. It captures the built tool plus the non-obvious gotchas discovered the
hard way — treat "Known gotchas" as settled fact, not theory to re-test.

## What this project is

A local macOS tool that takes a pasted URL (Instagram first; YouTube / Pinterest
secondary), auto-detects image vs video, handles carousels (all slides OR one specific
slide via `img_index`), and saves clean files. Primary UX: a macOS **Shortcut** with a
global hotkey + Share Sheet — copy link → hotkey → file in `~/Downloads`. No Terminal.

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
- **`setup.sh`** — installs the three deps via Homebrew, links `carabiner`/`clip`/`crab`.
- **`README.md`** — team setup + the macOS Shortcut wiring (the manual GUI step).
- **`files/`** — original seed: proven `igdl`/`igdls` functions + the `ig-grab.js`
  bookmarklet. Reference only.

**Decision that was made:** images fold into the paste-a-link flow via gallery-dl (the
click-to-pick bookmarklet is retired to `files/` as reference, not part of the tool).

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
