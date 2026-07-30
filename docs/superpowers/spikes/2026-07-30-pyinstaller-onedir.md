# Spike: PyInstaller `--onedir` for the bundled Python tools

**Date:** 2026-07-30 · **Verdict: do it.** Both hoped-for wins are real, and the one
integration unknown has a working answer.

## Why

Bundling (Phase 2) made the app dramatically less responsive. The two Python tools are
PyInstaller **one-file** builds, which unpack their entire embedded Python to a fresh temp
directory on *every* launch. Measured on this machine:

| | startup (`--version`) |
|---|---|
| `yt-dlp`, bundled one-file | **7.9s** |
| `gallery-dl`, bundled one-file | **4.4s** |
| `yt-dlp`, Homebrew (python script) | 0.19s |
| `gallery-dl`, Homebrew (python script) | 0.07s |

Our code signature is *not* the cause — the ad-hoc CI binaries are identically slow
(7.89s vs 7.97s). See CLAUDE.md gotcha #21.

## What was tested

Built `gallery-dl==1.32.8` locally with `pyinstaller==6.21.0` under Python 3.12 (matching
CI), both ways, same toolchain. arm64-only — this spike measures *startup*, not arch.

## Result 1 — speed: confirmed, ~49×

| | startup | size |
|---|---|---|
| `--onedir` | **0.09s** | 23 MB |
| `--onefile` (same toolchain) | 0.41s | 12 MB |
| `--onefile` (what we ship today, universal2) | 4.44s | 21 MB |
| Homebrew python script | 0.07s | — |

`--onedir` is effectively as fast as a plain Python install. 3780 extractors present,
Instagram among them, so `--collect-submodules` still behaves.

## Result 2 — the entitlement can go: confirmed

Gotcha #20 exists because a one-file build dlopens a Python framework *we didn't sign*,
so Hardened Runtime's library validation kills it unless
`com.apple.security.cs.disable-library-validation` is granted.

With `--onedir` the libraries are ordinary files we can sign ourselves. There are only
**five** Mach-Os in the whole tree:

```
_internal/libpython3.12.dylib
_internal/ada92cb5d92a588d1b93__mypyc.cpython-312-darwin.so
_internal/charset_normalizer/cd.cpython-312-darwin.so
_internal/charset_normalizer/md.cpython-312-darwin.so
gallery-dl
```

Signed all five with `--options runtime` and **no entitlements at all**, then:

- `--version` → `1.32.8`
- `--list-extractors` → 3780, Instagram present
- a real cookie-authenticated Instagram fetch → returned the media URLs
- every nested Mach-O passes `codesign --verify --strict`

So the entitlement is not needed under `--onedir`. That is a genuine reduction in how much
hardening we give away, not just a speed change.

## Result 3 — bundle layout: solved

`--onedir` produces a *directory*, but the `CARABINER_BIN` contract puts executables
directly on `PATH`. A symlink resolves it — PyInstaller locates `_internal` from the
executable's real path, so it works through the link:

```
Contents/Resources/
  bin/gallery-dl -> ../gallery-dl.app-dir/gallery-dl     # what CARABINER_BIN points at
  gallery-dl.app-dir/{gallery-dl,_internal/…}
```

Verified: `command -v gallery-dl` resolves the symlink, `--version` works, all 3780
extractors load.

## What productionising still needs

1. **`yt-dlp` has to be built by us too.** Upstream ships only a one-file `yt-dlp_macos`;
   there is no `--onedir` asset. It gains its own CI job, and `deps.lock`'s yt-dlp row
   stops pointing at upstream and points at our release like the other two.
2. **Confirm universal2.** This spike was arm64-only. The risk is the nested wheel `.so`
   files, which must exist as universal2. Good sign: the *existing* one-file build already
   succeeds with `--target-arch universal2` and contains these same `.so` files, so they
   are already universal2-capable — but assert it per-file in CI with `lipo -archs`, not
   just on the launcher, because a thin nested library would only fail on the other arch.
3. **`project.yml` signing loop changes shape.** It currently walks a flat `bin/*`. It has
   to walk the onedir trees and sign every Mach-O, deepest-first, then the launcher.
   Keep the existing post-signing smoke test — it is what catches "signed it into a brick".
4. **Size roughly doubles**, and universal2 doubles it again: expect ~45 MB per Python tool
   rather than ~21 MB. Acceptable for a DMG; worth stating out loud before it surprises us.
5. **Drop `disable-library-validation`** from `BundledBinaries.entitlements` once both
   tools are onedir — and update gotcha #20 to say it *was* required and why it no longer
   is, rather than deleting it, since the reasoning is what stops someone re-adding it.

## Do not

Do not go back to relying on Homebrew instead. It is fast, but the whole point of Phase 2
is that teammates will not have it (see [[carabiner-distribution-decision]] — they cannot
build or install toolchains themselves).
