# Carabiner.app (native menu-bar app)

Native wrapper around the repo's `carabiner` script. See
`docs/superpowers/specs/2026-07-29-carabiner-mac-app-design.md`.

## Dev build
```bash
cd app
xcodegen generate
open Carabiner.xcodeproj   # or: xcodebuild -scheme Carabiner build
```
(The `.xcodeproj` is generated from `project.yml`, so it's gitignored.)
