# CLAUDE.md — Carabiner

**Carabiner** — a small, trustworthy piece of kit that clips onto media and holds it.
Named in the climbing/off-piste register to sit with the OFF-PISTE brand.
Suggested shell command: `carabiner "url"`, with a short alias `clip` (or `crab`).

Context for Claude Code. Read this first. It captures a working pipeline plus the
non-obvious gotchas that were discovered the hard way — treat the "Known gotchas"
section as settled fact, not theory to re-test.

## What this project is

A **local** macOS tool that takes a pasted URL (Instagram first; Pinterest / YouTube
as secondary), auto-detects image vs video, handles carousels (all slides OR one
specific slide), and saves clean, QuickTime-openable files.

Primary target UX: a macOS **Shortcut** with a global hotkey + Share Sheet action, so
the flow is: copy link → hit hotkey (or Share → shortcut) → file lands in ~/Downloads.
No Terminal, no website.

## The single most important architectural fact

**Everything works because it runs locally as the logged-in user, using their own
browser cookies.** Do not turn this into a hosted website that accepts links from
strangers. The moment there's no per-user browser session:
- Instagram refuses anonymous requests ("empty media response").
- A public backend would need its own IG login, which gets rate-limited/banned fast
  and is against IG ToS.

Keep it local. It's still shareable — as a repo/Shortcut each person runs on their own
Mac with their own cookies.

## Working logic (already proven — reuse, don't reinvent)

The shell in `scripts/` is the real, tested logic from prior work. Start by reading it.

**Video download (with sound):**
```bash
yt-dlp --cookies-from-browser chrome -o "src.%(ext)s" "URL"
ffmpeg -y -i "src.mp4" -c:v libx264 -c:a aac -pix_fmt yuv420p "OUT.mp4"
```
**Video (silent):** add `-f "bv"` to yt-dlp and `-an` to ffmpeg (drop `-c:a aac`).

**Shortcode parsing** (handles `/p/`, `/reel/`, `/reels/`):
```bash
sed -E 's#.*/(p|reel|reels)/([^/?]+).*#\2#'
```

**Carousel:** `--playlist-items N`. Parse `img_index=N` from the URL for "just this slide".

## Known gotchas (settled — do not re-litigate by trial and error)

1. **Cookies are mandatory.** Anonymous IG requests return "empty media response".
   `--cookies-from-browser chrome` (or safari/firefox/brave/edge) is required.
2. **IG videos are streaming blobs.** A browser/bookmarklet cannot save them (the
   `<video>` src is a `blob:` URL backed by MediaSource, assembled from separate
   audio+video streams). yt-dlp is required for video. This is why the tool can't be
   pure-browser.
3. **QuickTime rejects IG's pixel formats.** Files download fine but won't open in
   QuickTime (esp. AI-generated footage: 10-bit / yuv444p). Fix = re-encode to 8-bit
   `-pix_fmt yuv420p`. A lossless `-c copy` remux sometimes suffices; the full
   libx264 re-encode is the guaranteed fix and the safe default.
4. **yt-dlp will NOT serve carousel *images*.** On an image slide it errors
   "No video formats found!". For images and full-carousel grabs, use **gallery-dl**
   instead (reads the same browser cookies). This is the clean fix — add gallery-dl
   as a first-class dependency, don't fight yt-dlp for images.
5. **Cross-origin `download` attribute fails** (image lives on cdninstagram.com, page
   is instagram.com) — historical note explaining why the old bookmarklet opened a tab
   instead of saving. Not relevant to the shell tool; noted so it isn't rediscovered.
6. **Home-vs-Downloads confusion.** Scripts should `cd ~/Downloads` (or take an explicit
   output dir) so files land predictably regardless of where the user invokes them.
7. **Filename guessing bites.** yt-dlp's `%(uploader_id)s` is a numeric ID, not the
   handle. Prefer deterministic naming from the shortcode (`%(id)s` or parsed code).

## Dependencies

- `yt-dlp` — video (IG/YouTube/etc.)
- `ffmpeg` — the re-encode/remux step
- `gallery-dl` — images + full carousels (the piece that fixes gotcha #4)

`setup.sh` should install all three via Homebrew and check for them on first run so the
tool works when dropped onto a colleague's Mac.

## Build order (suggested)

1. Read `scripts/igdl.sh` and `browser/ig-grab.js` to absorb the working logic.
2. A unified `grab` script: parse URL → detect platform → detect image/video →
   detect carousel + `img_index` → route to yt-dlp (video) or gallery-dl (image/all) →
   re-encode video → save to Downloads with deterministic name.
3. `setup.sh` (Homebrew deps + dependency check).
4. Wrap in a macOS Shortcut (Run Shell Script action + global hotkey + Share Sheet).
5. README for the team, including one-line setup.

## Open decision for the user (ask before building the image path)

Images can either stay as the click-to-pick **bookmarklet** (`browser/ig-grab.js` — lets
you eyeball the exact slide) OR fold into the same paste-a-link flow via gallery-dl
(cleaner single UX). Confirm which before committing the image path.

## Conventions

- Bash, macOS/zsh target. Keep it dependency-light beyond the three tools above.
- Deterministic filenames from shortcode; `_fixed` suffix for re-encoded video;
  `_sN` suffix when a specific carousel slide is grabbed so slides don't overwrite.
- `-y` on ffmpeg to overwrite cleanly. Clean up `src.*` temp files after.
