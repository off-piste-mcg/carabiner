#!/usr/bin/env bash
# Copies the single extension source into both delivery shapes. One source tree, two
# builds — the Safari appex gets a copy at build time, Chrome gets a zip for the store.
#
# MUST run at least once before the first `xcodegen generate` in app/: dist/ is
# gitignored, and project.yml's CarabinerSafariExtension target sources its resources
# from dist/chrome — generate fails outright ("missing source directory") without it.
# After that, CarabinerSafariExtension's own pre-build script re-runs this automatically
# on every `xcodebuild`, so editing extension/src/*.js and rebuilding the app does NOT
# require running this by hand again — that gap (silently shipping stale JS, the same
# shape as the Contents/Resources/carabiner snapshot trap in CLAUDE.md) is closed at the
# Xcode-build level, not by remembering to re-run this script. Cheap and idempotent by
# design (a handful of small files, well under a second) so re-running it on every build
# costs nothing. scripts/release.sh also runs it, before `xcodegen generate`, to cover
# the fresh-checkout case a pre-build script can't reach (see app/project.yml's comment
# on CarabinerSafariExtension's preBuildScripts for why not).
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
dist="$here/dist"
rm -rf "$dist"; mkdir -p "$dist/chrome"
cp -R "$here/manifest.json" "$here/src" "$here/icons" "$dist/chrome/"
(cd "$dist/chrome" && zip -qr ../carabiner-chrome.zip .)
echo "✓ $dist/carabiner-chrome.zip"
