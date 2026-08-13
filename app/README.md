# Carabiner.app (native menu-bar app)

Native wrapper around the repo's `carabiner` script. See
`docs/superpowers/specs/2026-07-29-carabiner-mac-app-design.md`.

## Dev build
```bash
./extension/build.sh   # once, before the first `xcodegen generate` — see below
cd app
xcodegen generate
open Carabiner.xcodeproj   # or: xcodebuild -scheme Carabiner build
```
(The `.xcodeproj` is generated from `project.yml`, so it's gitignored.)

`extension/build.sh` populates the gitignored `extension/dist/chrome/`, which the
`CarabinerSafariExtension` app-extension target (the Safari extension, embedded inside
`Carabiner.app`) copies its resources from. `xcodegen generate` fails outright if that
directory doesn't exist yet, so a fresh checkout needs it run once by hand first. After
that you don't need to run it again yourself: the target re-runs it automatically as a
pre-build script on every `xcodebuild`, so editing `extension/src/*.js` and rebuilding
picks up the change with no manual step.
