#!/usr/bin/env bash
# Copies the single extension source into both delivery shapes. One source tree, two
# builds — the Safari appex gets a copy at build time, Chrome gets a zip for the store.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
dist="$here/dist"
rm -rf "$dist"; mkdir -p "$dist/chrome"
cp -R "$here/manifest.json" "$here/src" "$here/icons" "$dist/chrome/"
(cd "$dist/chrome" && zip -qr ../carabiner-chrome.zip .)
echo "✓ $dist/carabiner-chrome.zip"
