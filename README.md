# Carabiner

> A small, trustworthy piece of kit that clips onto media and holds it.

Paste or share a link — Instagram (first-class), YouTube, Pinterest — and Carabiner
saves a clean, **QuickTime-openable** file to `~/Downloads`. It auto-detects image vs
video, handles carousels (all slides or just one), and fixes Instagram's awkward video
formats so they actually open.

It runs **locally as you**, using your own browser's login cookies. That's the whole
trick — and the reason it can't (and shouldn't) be a website. See
[CLAUDE.md](CLAUDE.md) for the why.

---

## Setup (once per Mac)

```bash
./setup.sh
```

Installs `yt-dlp`, `ffmpeg`, and `gallery-dl` via Homebrew, then links `carabiner`
(plus the `clip` / `crab` aliases) onto your PATH. Re-runnable; installs only what's
missing. Needs [Homebrew](https://brew.sh).

## Use

```bash
carabiner "https://www.instagram.com/reel/XXXXXXXXXXX/"   # smart grab
carabiner -a "https://www.instagram.com/p/XXXXXXXXXXX/"   # all carousel slides
carabiner -s 2 "https://www.instagram.com/p/XXXXXXXXXXX/" # just slide 2
carabiner --silent "https://www.instagram.com/reel/..."   # video, no sound
carabiner -o ~/Desktop "URL"                              # different output folder
```

| What you paste | What happens |
|---|---|
| A reel / video post | `yt-dlp` grabs it → re-encoded to QuickTime-safe H.264 → `CODE_fixed.mp4` |
| A single image | `gallery-dl` grabs it → `CODE_1.jpg` |
| A carousel (`-a`) | `gallery-dl` grabs every slide; any videos are re-encoded too |
| A slide link with `?img_index=N` | auto-targets that slide (same as `-s N`) |
| A YouTube / Pinterest link | `yt-dlp` with sensible, QuickTime-friendly settings |

**Naming:** deterministic from the Instagram shortcode. `_fixed` = re-encoded video,
`_sN` = a specific carousel slide, `_silent` = audio stripped.

**Cookies:** Chrome by default. Point it elsewhere with
`export CARABINER_BROWSER=safari` (also `firefox`, `brave`, `edge`).

---

## The no-Terminal flow (macOS Shortcut)

The goal: be on a post → hit a hotkey → file lands in Downloads. No copying, no
Terminal. This is a one-time setup in the **Shortcuts** app:

1. Open **Shortcuts** → **＋** new shortcut. Name it **Carabiner**.
2. Shortcuts **Settings → Advanced →** tick **Allow Running Scripts** (one-time; macOS
   disables shell actions by default).
3. Add the action **Run Shell Script** (search "shell"). Set **Shell** to `zsh` and
   paste exactly (no `"$1"`, no Get Clipboard action needed):
   ```sh
   /opt/homebrew/bin/carabiner
   ```
   (Apple Silicon path. Intel Mac: `/usr/local/bin/carabiner`. Run `which carabiner`.)
4. **Global hotkey:** right-click the shortcut in the sidebar → **Add Keyboard
   Shortcut**, e.g. ⌃⌥⌘V.

With no URL argument, Carabiner reads the **front browser tab's URL** automatically
(falling back to the clipboard) — so the flow is simply: open the reel/post in Chrome →
press the hotkey. The first run asks permission for Shortcuts to control Chrome — click
**Allow**.

When launched from the hotkey, Carabiner shows a **macOS notification** when it's
done — `✓ Saved to Downloads` with the filename, or `✗ Grab failed` with the reason (so
a press that finds nothing tells you *why*, e.g. not logged into Instagram). Runs from a
terminal stay quiet and just print instead.

**Share Sheet (optional):** open the shortcut's **ⓘ** details → tick **Use as Quick
Action → Share Sheet**, set **Accepts: URLs / Text**, and change the script to
`/opt/homebrew/bin/carabiner "$1"` so the shared URL is passed in.

---

## What's in here

- **[`carabiner`](carabiner)** — the tool. One script, does everything above.
- **[`setup.sh`](setup.sh)** — deps + PATH links.
- **[`CLAUDE.md`](CLAUDE.md)** — architecture + the hard-won gotchas. Read before changing anything.
- **[`files/`](files)** — the original seed bundle: the proven `igdl` functions and the
  click-to-pick bookmarklet, kept for reference.

## Troubleshooting

- **"empty media response" / nothing downloads** → you're not logged into Instagram in
  the cookie browser, or it's the wrong browser. Log in, or set `CARABINER_BROWSER`.
- **File won't open in QuickTime** → shouldn't happen (we re-encode), but if a raw
  `gallery-dl` video slips through, re-run with the reel's direct link so it routes
  through the video path.
- **`missing dependency`** → run `./setup.sh` again.
- **Private posts** → you must be able to see the post while logged in; Carabiner can
  only reach what your own session can.
