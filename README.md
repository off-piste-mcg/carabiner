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

## Download the app (easiest — no Terminal)

1. Download **Carabiner.dmg** from the [latest release](https://github.com/off-piste-mcg/carabiner/releases/latest).
2. Open it and drag **Carabiner** to your Applications folder.
3. Open Carabiner from Applications. It lives in the menu bar — there is no window.
4. A **Setup & Permissions** window opens the first time. Click Allow on each row:
   notifications, your browser, and System Events. You can reopen it any time from the
   menu-bar icon.
5. Open an Instagram post and press **⌃⌥⌘V**. The file lands in `~/Downloads`.

> **One hotkey, one owner.** If you also installed the macOS Shortcut below, unbind its
> keyboard shortcut first — a global chord belongs to exactly one app, and the loser gets
> no warning, it just silently never fires.

Everything below is the manual route: the script on its own, and the Shortcut. You don't
need it if you installed the app.

---

## Get it (once per Mac)

```bash
git clone https://github.com/off-piste-mcg/carabiner.git
cd carabiner
./setup.sh
```

`setup.sh` installs `yt-dlp`, `ffmpeg`, and `gallery-dl` via Homebrew, then links
`carabiner` (plus the `clip` / `crab` aliases) onto your PATH. Re-runnable; installs
only what's missing. Needs [Homebrew](https://brew.sh).

> Keep the cloned folder around — the `carabiner` command is symlinked to the script
> inside it. `git pull` in that folder to update.

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

The goal: be on a post → hit a hotkey → file lands in Downloads. No copying, no Terminal.

### 1. Add the shortcut — one click

### → **[Add the Carabiner shortcut](https://www.icloud.com/shortcuts/1633ebc20bf04369a20ccab25b38dc8b)**

Click it, then **Add Shortcut** in the window that opens. That's the whole thing — it
finds `carabiner` whether you're on Apple Silicon or Intel.

**Then enable shell scripts (one-time, required):** open the **Shortcuts** app →
**Settings** (⌘,) → **Advanced** → turn on **Allow Running Scripts**. macOS blocks
script actions by default, so without this the shortcut *errors* with "this action
can't be run… script actions aren't allowed" (it does **not** prompt you). On a
non-English Mac the tab/toggle are localised (e.g. Dutch: **Opdrachten → Instellingen →
Geavanceerd → Sta uitvoeren van scripts toe**).

The first run also asks permission for Shortcuts to control your browser — click **Allow**.

### 2. Set your hotkey — each Mac picks its own

Keyboard shortcuts aren't stored inside a shared shortcut, so choose yours: in the
**Shortcuts** app, right-click **Carabiner** in the sidebar → **Add Keyboard Shortcut**
→ press your combo (e.g. ⌃⌥⌘V).

### That's it

Open a reel/post in your browser → hit your hotkey → the file lands in `~/Downloads`,
and a **macOS notification** confirms it (`✓ Saved to Downloads` + filename, or
`✗ Grab failed` with the reason, e.g. not logged into Instagram). Carabiner reads your
**front browser tab's URL** automatically (falling back to the clipboard). Cookies come
from Chrome by default — `export CARABINER_BROWSER=safari` for another browser.

<details>
<summary>Prefer to build the shortcut by hand?</summary>

1. Open **Shortcuts** → **＋** new shortcut, name it **Carabiner**.
2. **Settings → Advanced →** tick **Allow Running Scripts** (macOS disables shell
   actions by default).
3. Add **Run Shell Script**, set **Shell** to `zsh`, and paste:
   ```sh
   CB=/opt/homebrew/bin/carabiner; [ -x "$CB" ] || CB=/usr/local/bin/carabiner; "$CB"
   ```
4. Right-click the shortcut → **Add Keyboard Shortcut** → pick your combo.

</details>

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
