# Carabiner — starter bundle

Seed context for building the tool in Claude Code. This isn't the finished tool — it's
the **working logic + hard-won gotchas** packaged so Claude Code starts from proven code
instead of rediscovering the walls.

## Files

- **CLAUDE.md** — primary context (auto-loaded by Claude Code each session). The
  architectural fact (keep it local, use browser cookies), the proven commands, the
  settled gotchas, dependencies, and suggested build order. **Read this first.**
- **scripts/igdl.sh** — the proven `igdl` / `igdls` shell functions + one-off patterns
  for carousels, YouTube, Pinterest, cargo.site, LinkedIn. The reference implementation.
- **browser/ig-grab.js** — the proven click-to-pick bookmarklet for images. Reference
  for the "images stay as click-to-pick" option.

## What to build (short version)

A local macOS tool: paste/share a URL → auto-detect image vs video → handle carousels
(all slides or one via `img_index`) → save clean files to ~/Downloads. Wrapped as a
macOS **Shortcut** (global hotkey + Share Sheet). Uses the user's own browser cookies.
Deps: yt-dlp + ffmpeg + gallery-dl (Homebrew).

## First step for Claude Code

Read CLAUDE.md, then scripts/igdl.sh and browser/ig-grab.js. Then ask the one open
question in CLAUDE.md (images: keep bookmarklet, or fold into the paste-a-link flow via
gallery-dl?) before writing the unified script.

## One decision still open for the human

See the bottom of CLAUDE.md — the image-path question. Everything else is scoped.
