#!/usr/bin/env bash
#
# setup.sh — install Carabiner's dependencies and put it on your PATH.
# Safe to re-run: it installs only what's missing.
#
# Deps: yt-dlp, ffmpeg, gallery-dl (all via Homebrew).

set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"

echo "── Carabiner setup ─────────────────────────────"

# 1. Homebrew
if ! command -v brew >/dev/null 2>&1; then
  echo "✗ Homebrew not found."
  echo "  Install it first: https://brew.sh  then re-run ./setup.sh"
  exit 1
fi
echo "✓ Homebrew found"

# 2. Dependencies
for dep in yt-dlp ffmpeg gallery-dl; do
  if command -v "$dep" >/dev/null 2>&1; then
    echo "✓ $dep already installed"
  else
    echo "→ installing $dep…"
    brew install "$dep"
  fi
done

# 3. Make the script executable
chmod +x "$HERE/carabiner"

# 4. Symlink carabiner + aliases into Homebrew's bin (on your PATH, no sudo)
BIN="$(brew --prefix)/bin"
for name in carabiner clip crab; do
  ln -sf "$HERE/carabiner" "$BIN/$name"
done
echo "✓ linked: carabiner, clip, crab → $BIN"

echo "────────────────────────────────────────────────"
echo "Ready. Try:"
echo "  carabiner \"https://www.instagram.com/reel/XXXXXXXXXXX/\""
echo
echo "Cookies come from Chrome by default. To use another browser:"
echo "  export CARABINER_BROWSER=safari   # or firefox / brave / edge"
