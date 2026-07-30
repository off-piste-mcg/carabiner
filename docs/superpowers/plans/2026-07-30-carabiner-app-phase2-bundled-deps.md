# Carabiner.app Phase 2 — Bundled Dependencies Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make `Carabiner.app` run on a Mac with no Homebrew and no Terminal, by shipping `yt-dlp`, `ffmpeg`, `gallery-dl` and the `carabiner` script inside the signed app bundle.

**Architecture:** The bash script stays the single engine for both front ends (gotcha: "two front ends, one engine"). The app tells it where its private binaries live via a new `CARABINER_BIN` environment variable, which the script prepends to `PATH` *ahead of* Homebrew. Nothing about the Shortcut/terminal path changes: with `CARABINER_BIN` unset the script behaves exactly as it does today. Upstream publishes no macOS standalone for `ffmpeg` or `gallery-dl`, so a GitHub Actions workflow builds both on macOS runners and publishes them as release assets; a fetch script pulls pinned, checksum-verified copies into a gitignored cache at build time.

**Tech Stack:** Bash, Swift/AppKit, XcodeGen, GitHub Actions (macos-14 arm64 + macos-13 x86_64), PyInstaller, `lipo`, `codesign`.

## Global Constraints

- **Minimum macOS: 13.0** (`deploymentTarget` in `app/project.yml`).
- **Every build signs.** `CODE_SIGN_STYLE: Automatic`, `CODE_SIGN_IDENTITY: "Apple Development"`, `DEVELOPMENT_TEAM: ${CARABINER_TEAM_ID}`. Export `CARABINER_TEAM_ID` before `xcodegen generate` — read from the certificate's **OU field**, never the parenthetical in the identity name (gotcha #12).
- **Hardened Runtime is on** (`ENABLE_HARDENED_RUNTIME: YES`) and must stay on — notarization requires it (gotcha #16).
- **Every Mach-O in the bundle must be signed with `--options runtime`** or notarization rejects the whole app.
- **`app/project.yml` is the single source of truth.** `Carabiner.xcodeproj`, `app/Carabiner/Info.plist` and `app/Carabiner/Carabiner.entitlements` are generated and gitignored — never hand-edit them.
- **Never commit the binaries.** ~150 MB of third-party executables stay out of git; they live in a gitignored cache and on GitHub Releases.
- **`xattr -cr` runs before signing** via `postBuildScripts` — this repo is under iCloud-synced `~/Documents` and the file provider stamps `com.apple.FinderInfo`, which `codesign` rejects (gotcha #13).
- **Launch the bundle with `open`, never the inner binary** when testing — direct exec skips LaunchServices and breaks notifications (gotcha #11).
- **Do not trust timestamps to verify a grab.** gallery-dl preserves Instagram's original mtime *and* birth time. Snapshot filenames and diff instead.
- Bash, macOS/zsh target. No new runtime dependencies beyond the three bundled tools.

## File Structure

| File | Responsibility |
|---|---|
| `carabiner` (modify, line 37) | `PATH` construction — bundled binaries win, Homebrew stays the fallback |
| `test/test-path.sh` (create) | Fast, network-free tests for the `PATH` and dependency-resolution logic |
| `.github/workflows/build-deps.yml` (create) | Builds static ffmpeg + universal2 gallery-dl, publishes a `deps-<version>` release |
| `scripts/fetch-deps.sh` (create) | Downloads pinned deps into `app/.deps/`, verifying SHA-256 |
| `scripts/deps.lock` (create) | Pinned versions + checksums — the single source of truth for what gets bundled |
| `app/project.yml` (modify) | Copy phase for `Resources/bin` + script + assets; per-Mach-O signing; library-validation entitlement |
| `app/Carabiner/GrabRunner.swift` (modify) | Resolve the bundled script and export `CARABINER_BIN` |
| `app/CarabinerTests/GrabRunnerTests.swift` (modify) | Cover the new env var and bundled-path resolution |
| `README.md`, `CLAUDE.md` (modify) | Install instructions and the new gotchas |

---

### Task 1: Fix the PATH shadowing blocker

The known blocker. `carabiner:37` re-prepends Homebrew ahead of anything the app sets, so bundled binaries are silently shadowed on any machine that also has Homebrew's yt-dlp — i.e. every machine this gets tested on. Fixing it first means the rest of the phase can be trusted.

**Files:**
- Modify: `carabiner:37`
- Create: `test/test-path.sh`

**Interfaces:**
- Consumes: nothing.
- Produces: the `CARABINER_BIN` contract — when set, its value is prepended to `PATH` ahead of `/opt/homebrew/bin` and `/usr/local/bin`; when unset or empty, `PATH` is built exactly as it is today. Task 2 and Task 6 both depend on this.

- [ ] **Step 1: Write the failing test**

Create `test/test-path.sh`:

```bash
#!/usr/bin/env bash
# Tests for carabiner's PATH construction. No network, no downloads: we stub the
# three dependencies and assert which copy the script would resolve.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$HERE/../carabiner"
pass=0; fail=0

check() {  # $1 = label, $2 = expected, $3 = actual
  if [ "$2" = "$3" ]; then
    printf '  ok   %s\n' "$1"; pass=$((pass + 1))
  else
    printf '  FAIL %s\n       expected: %s\n       actual:   %s\n' "$1" "$2" "$3"; fail=$((fail + 1))
  fi
}

# A throwaway dir standing in for the app's Resources/bin.
BUNDLED="$(mktemp -d)"
trap 'rm -rf "$BUNDLED"' EXIT
printf '#!/bin/bash\necho BUNDLED\n' > "$BUNDLED/yt-dlp"
chmod +x "$BUNDLED/yt-dlp"

# Ask the script which yt-dlp it would use, without running a grab or touching the
# network. Take the script's whole prologue — everything before the first setting
# (`BROWSER=`) — and source it in a subshell. Slicing at `export PATH=` instead would
# cut the if/else in half and leave an unterminated `if`.
PROLOGUE="$BUNDLED/.prologue.sh"
sed -n '1,/^BROWSER=/p' "$SCRIPT" | sed '$d' > "$PROLOGUE"

resolve_ytdlp() {  # env comes from the caller
  bash -c 'source "$1" >/dev/null 2>&1; command -v yt-dlp' _ "$PROLOGUE"
}

show_path() {
  bash -c 'source "$1" >/dev/null 2>&1; printf "%s" "$PATH"' _ "$PROLOGUE"
}

echo "test-path.sh"

# 1. Bundled binaries must win over Homebrew — this is the blocker.
actual="$(CARABINER_BIN="$BUNDLED" resolve_ytdlp)"
check "CARABINER_BIN wins over Homebrew" "$BUNDLED/yt-dlp" "$actual"

# 2. With no CARABINER_BIN the Shortcut/terminal path is unchanged.
actual="$(unset CARABINER_BIN; resolve_ytdlp)"
case "$actual" in
  "$BUNDLED"/*) check "unset CARABINER_BIN ignores the bundle" "not $BUNDLED/yt-dlp" "$actual" ;;
  *)            check "unset CARABINER_BIN ignores the bundle" "ok" "ok" ;;
esac

# 3. An empty CARABINER_BIN must not inject an empty PATH entry (":" means cwd —
#    a real security footgun, since it would run ./yt-dlp from whatever directory
#    the hotkey happened to fire in).
actual="$(CARABINER_BIN="" show_path)"
case "$actual" in
  *::*|:*|*:) check "empty CARABINER_BIN leaves no empty PATH entry" "clean" "empty entry in: $actual" ;;
  *)          check "empty CARABINER_BIN leaves no empty PATH entry" "clean" "clean" ;;
esac

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
```

```bash
chmod +x test/test-path.sh
```

- [ ] **Step 2: Run it to verify it fails**

Run: `./test/test-path.sh`
Expected: FAIL on "CARABINER_BIN wins over Homebrew" — the current line 37 ignores `CARABINER_BIN` entirely, so `command -v yt-dlp` resolves to Homebrew's copy (or nothing).

- [ ] **Step 3: Implement the minimal change**

Replace `carabiner:37` (`export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"`) with:

```bash
# Bundled binaries win when the app supplies them; Homebrew stays the fallback so the
# Shortcut and terminal paths are untouched. The order matters and is the whole point:
# prepending Homebrew unconditionally (as this line used to) silently shadows the app's
# private copies on any machine that also has Homebrew's yt-dlp — which is every machine
# this gets tested on, so bundling would *look* like it worked. See gotcha #17.
if [ -n "${CARABINER_BIN:-}" ]; then
  export PATH="$CARABINER_BIN:/opt/homebrew/bin:/usr/local/bin:$PATH"
else
  export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"
fi
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `./test/test-path.sh && bash -n carabiner`
Expected: `3 passed, 0 failed`, then a clean syntax check.

- [ ] **Step 5: Verify the Shortcut path still works end-to-end**

Run a real grab with no `CARABINER_BIN` set, and confirm it still resolves Homebrew's tools:

```bash
CARABINER_NO_NOTIFY=1 ./carabiner -s 1 'https://www.instagram.com/p/SHORTCODE/'
```

Expected: the file appears in `~/Downloads`. Verify by filename diff, not timestamp:

```bash
ls -1 ~/Downloads > /tmp/before.txt   # before the grab
ls -1 ~/Downloads | diff /tmp/before.txt - | grep '^>'
```

- [ ] **Step 6: Commit**

```bash
git add carabiner test/test-path.sh
git commit -m "fix(script): let CARABINER_BIN take precedence over Homebrew on PATH"
```

---

### Task 2: Teach the app to use a bundled script and binaries

Wire the app side before any binaries exist, so this is testable on its own: the app should prefer a bundled `carabiner` and pass `CARABINER_BIN`, falling back to the Homebrew script when the bundle has neither.

**Files:**
- Modify: `app/Carabiner/GrabRunner.swift`
- Modify: `app/CarabinerTests/GrabRunnerTests.swift`
- Modify: `app/project.yml` (copy `carabiner` and `assets/` into `Resources`)

**Interfaces:**
- Consumes: the `CARABINER_BIN` contract from Task 1.
- Produces: `GrabRunner.bundledExecutable` (`static func () -> String?`) returning the bundled script path or `nil`; `GrabRunner.binDirectory` (`static func () -> String?`) returning `Contents/Resources/bin` or `nil`. Task 6 relies on both resolving once the copy phase exists.

- [ ] **Step 1: Write the failing tests**

Append to `app/CarabinerTests/GrabRunnerTests.swift`:

```swift
    /// The app must hand the script its private bin directory. Without this the script
    /// falls back to Homebrew, which is exactly the silent-shadowing failure Phase 2 exists
    /// to remove — and it would look like bundling worked on any dev machine.
    func testPassesCarabinerBinWhenBundleHasOne() {
        let binDir = NSTemporaryDirectory() + "carabiner-bin-\(UUID().uuidString)"
        try! FileManager.default.createDirectory(atPath: binDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: binDir) }

        let stub = writeStub("echo \"  ✓ ${CARABINER_BIN:-UNSET}\"; exit 0")
        var runner = GrabRunner(executable: stub)
        runner.binDirectory = binDir
        let result = runner.run(url: "https://x/y")

        XCTAssertTrue(result.ok)
        XCTAssertEqual(result.message, binDir)
    }

    /// With no bundled bin directory the variable must be absent, not empty: an empty
    /// entry in PATH means the current directory, so the script would run whatever
    /// ./yt-dlp happened to be in the folder the hotkey fired from.
    func testOmitsCarabinerBinWhenNoneBundled() {
        let stub = writeStub("echo \"  ✓ ${CARABINER_BIN-ABSENT}\"; exit 0")
        var runner = GrabRunner(executable: stub)
        runner.binDirectory = nil
        let result = runner.run(url: "https://x/y")

        XCTAssertEqual(result.message, "ABSENT")
    }
```

- [ ] **Step 2: Run the tests to verify they fail**

```bash
export CARABINER_TEAM_ID=$(security find-certificate -a -c "Apple Development" -p \
  | openssl x509 -noout -subject | tr ',/' '\n\n' \
  | sed -nE 's/.*OU=([A-Z0-9]{10}).*/\1/p' | head -1)
cd app && xcodegen generate
xcodebuild -project Carabiner.xcodeproj -scheme Carabiner -destination 'platform=macOS' test
```

Expected: compile error — `GrabRunner` has no member `binDirectory`.

- [ ] **Step 3: Implement**

In `app/Carabiner/GrabRunner.swift`, replace the `executable` property and add the resolvers:

```swift
    /// The bundled script when the app ships one, else the Homebrew-installed copy.
    /// Phase 2 bundles it; the fallback keeps a dev build working before `fetch-deps.sh`
    /// has ever run, so an unbundled build fails at the *dependency* check with a real
    /// message instead of "couldn't launch carabiner".
    var executable: String = GrabRunner.bundledExecutable() ?? "/opt/homebrew/bin/carabiner"

    /// The app's private binaries. `nil` when this build has no bundled copies, in which
    /// case CARABINER_BIN is left unset entirely and the script uses Homebrew.
    var binDirectory: String? = GrabRunner.binDirectory()

    static func bundledExecutable() -> String? {
        Bundle.main.url(forResource: "carabiner", withExtension: nil)?.path
    }

    static func binDirectory() -> String? {
        guard let res = Bundle.main.resourceURL?.appendingPathComponent("bin").path,
              FileManager.default.fileExists(atPath: res) else { return nil }
        return res
    }
```

And in `run(url:)`, immediately after the existing `env["CARABINER_BROWSER"] = browser.rawValue`:

```swift
        // Only set it when we actually have one: an empty CARABINER_BIN would put an
        // empty entry at the front of the script's PATH, which means the current
        // directory. See test above.
        if let binDirectory { env["CARABINER_BIN"] = binDirectory }
```

- [ ] **Step 4: Add the copy phase**

In `app/project.yml`, under the `Carabiner` target, add `sources` entries so the script and its assets land in `Resources`:

```yaml
    sources:
      - Carabiner
      - path: ../carabiner
        buildPhase: resources
      - path: ../assets
        buildPhase: resources
```

The `assets/` folder carries `Carabiner.icns`, which the script resolves relative to its own directory — inside the bundle that resolves to `Contents/Resources/assets/Carabiner.icns`, so the carousel dialog stays branded.

- [ ] **Step 5: Run the tests to verify they pass**

```bash
cd app && xcodegen generate
xcodebuild -project Carabiner.xcodeproj -scheme Carabiner -destination 'platform=macOS' test
```

Expected: PASS, including the two new tests.

- [ ] **Step 6: Verify the script and icon actually landed in the bundle**

```bash
xcodebuild -project Carabiner.xcodeproj -scheme Carabiner -configuration Debug \
  -derivedDataPath build build
ls -l build/Build/Products/Debug/Carabiner.app/Contents/Resources/carabiner \
      build/Build/Products/Debug/Carabiner.app/Contents/Resources/assets/Carabiner.icns
```

Expected: both exist, and `carabiner` is executable (`-rwxr-xr-x`).

- [ ] **Step 7: Commit**

```bash
git add app/project.yml app/Carabiner/GrabRunner.swift app/CarabinerTests/GrabRunnerTests.swift
git commit -m "feat(app): bundle the carabiner script and pass CARABINER_BIN"
```

---

### Task 3: CI — build a static universal ffmpeg

> **Corrected after review, 2026-07-30. The YAML inlined in Tasks 3 and 4 below is
> SUPERSEDED — do not re-derive a brief from it.** `.github/workflows/build-deps.yml` as
> committed (`d4b117c`) is the authoritative version. Six defects were found in the text
> below, two of which would have produced a *green* run with no usable artifact:
>
> 1. **`macos-13` was retired 2025-12-08** and `macos-14` is deprecated (retires
>    2026-11-02). The Intel leg dies on a runner-image error, `ffmpeg-universal` then
>    *skips* via `needs:` rather than failing, and the arm64 leg still burns ~25 minutes
>    and reports success — having produced no universal ffmpeg. Use `macos-15-intel` and
>    `macos-15`.
> 2. **`--list-extractors | grep -qi instagram` fails on a correct binary.** Under
>    `set -o pipefail`, grep exits at the first match, CPython takes EPIPE and exits 120,
>    and pipefail propagates it. Reproduced against real gallery-dl 1.32.8. Capture the
>    listing to a file once and grep the file.
> 3. **No deployment target**, so `minos` defaults to the host OS while the app declares a
>    13.0 floor — macOS 13 users would get an ffmpeg the loader rejects, and it cannot
>    reproduce on any runner. Set `MACOSX_DEPLOYMENT_TARGET=13.0` for x264 *and* ffmpeg.
> 4. **Floating versions** — x264 at default HEAD, `pyinstaller` unpinned,
>    `python-version: "3.12"` drifting. These land inside a signed, notarized app. Note
>    3.12.11+ ship no darwin builds at all, so 3.12.10 is the newest usable one, and x264
>    has zero tags upstream so a commit SHA is the only real pin.
> 5. **`architecture: "x64"`** is unnecessary — `actions/python-versions` installs
>    python.org's universal2 pkg for both the x64 and arm64 manifest entries — and it adds
>    a constraint (a darwin-x64 asset must exist) that newer 3.12 releases no longer meet.
> 6. **`lipo -archs` was printed, never asserted**, so it gated nothing; it exits 0 on a
>    single-arch binary. Assert it — equality with `matrix.arch` in the per-arch legs
>    (stronger there: it also catches a mis-scheduled runner), both arches in the two
>    genuinely universal outputs.

Homebrew's ffmpeg links 18 Homebrew dylibs, so it cannot be copied into a bundle. There is no official static macOS build. This produces one.

**Files:**
- Create: `.github/workflows/build-deps.yml` (ffmpeg job only; Task 4 adds the second job)

**Interfaces:**
- Produces: a release asset `ffmpeg-<version>-macos-universal.tar.gz` containing a single static, universal (`arm64` + `x86_64`) `ffmpeg` binary. Task 5 downloads it by that exact name.

- [ ] **Step 1: Write the workflow**

Create `.github/workflows/build-deps.yml`:

```yaml
name: build-deps

# Manual only. These builds take ~30 minutes and the outputs are pinned in
# scripts/deps.lock, so they should be deliberate, not on every push.
on:
  workflow_dispatch:
    inputs:
      ffmpeg_version:
        description: "ffmpeg release tag (e.g. n7.1)"
        required: true
        default: "n7.1"

jobs:
  ffmpeg:
    strategy:
      matrix:
        include:
          - runner: macos-14   # Apple Silicon
            arch: arm64
          - runner: macos-13   # Intel
            arch: x86_64
    runs-on: ${{ matrix.runner }}
    steps:
      - name: Build static x264
        run: |
          set -euo pipefail
          git clone --depth 1 https://code.videolan.org/videolan/x264.git
          cd x264
          ./configure --prefix="$HOME/ffbuild" --enable-static --disable-cli --disable-opencl
          make -j"$(sysctl -n hw.ncpu)" && make install

      - name: Build static ffmpeg
        run: |
          set -euo pipefail
          git clone --depth 1 --branch "${{ inputs.ffmpeg_version }}" \
            https://github.com/FFmpeg/FFmpeg.git ffmpeg
          cd ffmpeg
          # --enable-gpl is required by libx264. The native `aac` encoder is built in, so
          # `-c:a aac` needs no external library. Everything the script uses is
          # -c:v libx264 -c:a aac -pix_fmt yuv420p, plus demuxing whatever IG serves.
          PKG_CONFIG_PATH="$HOME/ffbuild/lib/pkgconfig" ./configure \
            --prefix="$HOME/ffout" \
            --enable-gpl --enable-libx264 \
            --enable-static --disable-shared \
            --disable-doc --disable-debug --disable-ffplay --disable-ffprobe \
            --pkg-config-flags=--static
          make -j"$(sysctl -n hw.ncpu)" && make install

      - name: Verify it is static and the right arch
        run: |
          set -euo pipefail
          BIN="$HOME/ffout/bin/ffmpeg"
          # A static build must not reference anything outside /usr/lib and
          # /System/Library — a single Homebrew dylib here means the binary is
          # unshippable, and the failure would only surface on a machine without brew.
          if otool -L "$BIN" | tail -n +2 | grep -vE '^\s+(/usr/lib|/System/Library)'; then
            echo "::error::ffmpeg links non-system libraries"; exit 1
          fi
          lipo -archs "$BIN"
          "$BIN" -version | head -1

      - uses: actions/upload-artifact@v4
        with:
          name: ffmpeg-${{ matrix.arch }}
          path: ~/ffout/bin/ffmpeg

  ffmpeg-universal:
    needs: ffmpeg
    runs-on: macos-14
    steps:
      - uses: actions/download-artifact@v4
        with: { name: ffmpeg-arm64, path: arm64 }
      - uses: actions/download-artifact@v4
        with: { name: ffmpeg-x86_64, path: x86_64 }
      - name: lipo into a universal binary
        run: |
          set -euo pipefail
          chmod +x arm64/ffmpeg x86_64/ffmpeg
          lipo -create arm64/ffmpeg x86_64/ffmpeg -output ffmpeg
          lipo -archs ffmpeg   # expect: x86_64 arm64
          ./ffmpeg -version | head -1
          tar -czf "ffmpeg-${{ inputs.ffmpeg_version }}-macos-universal.tar.gz" ffmpeg
          shasum -a 256 "ffmpeg-${{ inputs.ffmpeg_version }}-macos-universal.tar.gz"
      - uses: actions/upload-artifact@v4
        with:
          name: ffmpeg-universal
          path: ffmpeg-*.tar.gz
```

- [ ] **Step 2: Run it and confirm it produces a working binary**

```bash
gh workflow run build-deps.yml -f ffmpeg_version=n7.1
gh run watch
```

Expected: green. The `Verify` step must print both `arm64` and `x86_64` from `lipo -archs`, and the `otool -L` grep must find nothing.

- [ ] **Step 3: Record the checksum**

```bash
gh run download --name ffmpeg-universal
shasum -a 256 ffmpeg-*.tar.gz
```

Keep the hash — Task 5 pins it.

- [ ] **Step 4: Commit**

```bash
git add .github/workflows/build-deps.yml
git commit -m "ci: build a static universal ffmpeg for bundling"
```

---

### Task 4: CI — build a universal2 gallery-dl

Upstream ships no binaries at all (0 release assets). PyInstaller `--onefile` appends an archive to the executable, so two per-arch builds **cannot** be merged with `lipo` — the appended payload would be mangled. The only workable route is a single build against a universal2 Python.

**Files:**
- Modify: `.github/workflows/build-deps.yml` (add the `gallery-dl` job)

**Interfaces:**
- Produces: a release asset `gallery-dl-<version>-macos-universal.tar.gz` containing a universal2 `gallery-dl` executable. Task 5 downloads it by that exact name.

- [ ] **Step 1: Add the job**

Add to `.github/workflows/build-deps.yml`, under `on.workflow_dispatch.inputs`:

```yaml
      gallery_dl_version:
        description: "gallery-dl version (e.g. 1.32.8)"
        required: true
        default: "1.32.8"
```

and as a new job:

```yaml
  gallery-dl:
    runs-on: macos-14
    steps:
      # python.org ships a universal2 framework build; the runner's default Python is
      # single-arch, and PyInstaller can only emit universal2 from a universal2 Python.
      - uses: actions/setup-python@v5
        with:
          python-version: "3.12"
          architecture: "x64"   # the macOS setup-python builds are universal2 framework builds

      - name: Build
        run: |
          set -euo pipefail
          python -m pip install --upgrade pip pyinstaller
          python -m pip install "gallery-dl==${{ inputs.gallery_dl_version }}"
          # gallery-dl loads its ~400 extractors by name at runtime, so PyInstaller's
          # static import scan misses all of them. --collect-submodules is mandatory:
          # without it the binary builds fine and then fails on every single URL.
          pyinstaller --onefile --clean --name gallery-dl \
            --target-arch universal2 \
            --collect-submodules gallery_dl \
            "$(python -c 'import gallery_dl, os; print(os.path.join(os.path.dirname(gallery_dl.__file__), "__main__.py"))')"

      - name: Verify arch and that extractors actually loaded
        run: |
          set -euo pipefail
          BIN=dist/gallery-dl
          lipo -archs "$BIN"           # expect: x86_64 arm64
          "$BIN" --version
          # The real smoke test: listing extractors proves --collect-submodules worked.
          # A stripped binary prints a handful; a good one prints hundreds.
          n="$("$BIN" --list-extractors | grep -c . || true)"
          echo "extractors: $n"
          [ "$n" -gt 100 ] || { echo "::error::extractors missing — check --collect-submodules"; exit 1; }
          "$BIN" --list-extractors | grep -qi instagram \
            || { echo "::error::instagram extractor missing"; exit 1; }

      - name: Package
        run: |
          set -euo pipefail
          cd dist
          tar -czf "gallery-dl-${{ inputs.gallery_dl_version }}-macos-universal.tar.gz" gallery-dl
          shasum -a 256 gallery-dl-*.tar.gz
      - uses: actions/upload-artifact@v4
        with:
          name: gallery-dl-universal
          path: dist/gallery-dl-*.tar.gz
```

- [ ] **Step 2: Run it**

```bash
gh workflow run build-deps.yml -f ffmpeg_version=n7.1 -f gallery_dl_version=1.32.8
gh run watch
```

Expected: green, with `lipo -archs` printing both architectures and the extractor count above 100 including `instagram`.

- [ ] **Step 3: Record the checksum**

```bash
gh run download --name gallery-dl-universal
shasum -a 256 gallery-dl-*.tar.gz
```

- [ ] **Step 4: Publish both as a release**

```bash
gh release create deps-2026.07 \
  ffmpeg-*.tar.gz gallery-dl-*.tar.gz \
  --title "Bundled dependencies 2026.07" \
  --notes "Static universal ffmpeg and universal2 gallery-dl for Carabiner.app. Built by .github/workflows/build-deps.yml."
```

- [ ] **Step 5: Commit**

```bash
git add .github/workflows/build-deps.yml
git commit -m "ci: build a universal2 gallery-dl for bundling"
```

---

### Task 5: Pinned, checksum-verified dependency fetch

**Files:**
- Create: `scripts/deps.lock`
- Create: `scripts/fetch-deps.sh`
- Modify: `app/.gitignore`

**Interfaces:**
- Consumes: the release assets from Tasks 3 and 4.
- Produces: `app/.deps/bin/{yt-dlp,ffmpeg,gallery-dl}`, all executable. Task 6 copies this directory into the bundle.

> **Permission note for the implementer:** this task downloads third-party executables. State the filenames, sources and sizes and get explicit approval before running the fetch for the first time.

- [ ] **Step 1: Write the lock file**

Create `scripts/deps.lock` — substitute the real checksums recorded in Tasks 3 and 4:

```
# One row per bundled binary: name  url  sha256
# yt-dlp is upstream's own universal2 build. ffmpeg and gallery-dl have no upstream
# macOS binaries, so these come from our own build-deps.yml (see docs/superpowers/plans).
# Pin exact versions — "latest" would make builds unreproducible and let a bad upstream
# release land in a signed, notarized app without anyone noticing.
yt-dlp      https://github.com/yt-dlp/yt-dlp/releases/download/2026.07.04/yt-dlp_macos                                              REPLACE_WITH_SHA256
ffmpeg      https://github.com/off-piste-mcg/carabiner/releases/download/deps-2026.07/ffmpeg-n7.1-macos-universal.tar.gz            REPLACE_WITH_SHA256
gallery-dl  https://github.com/off-piste-mcg/carabiner/releases/download/deps-2026.07/gallery-dl-1.32.8-macos-universal.tar.gz      REPLACE_WITH_SHA256
```

- [ ] **Step 2: Write the fetch script**

Create `scripts/fetch-deps.sh`:

```bash
#!/usr/bin/env bash
#
# fetch-deps.sh — download the binaries Carabiner.app bundles, into a gitignored cache.
# Idempotent: a file whose checksum already matches is left alone.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
DEST="$HERE/../app/.deps/bin"
LOCK="$HERE/deps.lock"

mkdir -p "$DEST"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT

while read -r name url sha; do
  case "$name" in ''|\#*) continue ;; esac

  if [ -f "$DEST/$name" ] && [ "$(shasum -a 256 "$DEST/$name" | cut -d' ' -f1)" = "$sha" ]; then
    echo "✓ $name (cached)"; continue
  fi

  echo "→ $name"
  curl -fsSL "$url" -o "$tmp/dl"

  # Verify BEFORE unpacking or running anything. A tarball is unpacked only after its
  # hash matches, so a compromised release can't execute anything during extraction.
  actual="$(shasum -a 256 "$tmp/dl" | cut -d' ' -f1)"
  [ "$actual" = "$sha" ] || {
    echo "✗ $name checksum mismatch" >&2
    echo "  expected $sha" >&2
    echo "  actual   $actual" >&2
    exit 1
  }

  case "$url" in
    *.tar.gz) tar -xzf "$tmp/dl" -C "$tmp" && mv "$tmp/$name" "$DEST/$name" ;;
    *)        mv "$tmp/dl" "$DEST/$name" ;;
  esac
  chmod +x "$DEST/$name"
done < "$LOCK"

echo
echo "Bundled binaries in $DEST:"
for b in yt-dlp ffmpeg gallery-dl; do
  printf '  %-11s %s\n' "$b" "$(lipo -archs "$DEST/$b" 2>/dev/null || echo '(not a Mach-O)')"
done
```

```bash
chmod +x scripts/fetch-deps.sh
```

- [ ] **Step 3: Gitignore the cache**

Add to `app/.gitignore`:

```
# Third-party binaries pulled by scripts/fetch-deps.sh — ~150 MB, never committed.
.deps/
```

- [ ] **Step 4: Run it and verify**

Run: `./scripts/fetch-deps.sh`
Expected: three `→` lines, then an arch summary listing `x86_64 arm64` for all three.

Then confirm each one runs and is genuinely self-contained:

```bash
cd app/.deps/bin
./yt-dlp --version && ./ffmpeg -version | head -1 && ./gallery-dl --version
for b in yt-dlp ffmpeg gallery-dl; do
  echo "== $b"; otool -L "$b" | tail -n +2 | grep -vE '^\s+(/usr/lib|/System/Library)' || echo "  self-contained"
done
```

Expected: three version strings, and `self-contained` for each.

- [ ] **Step 5: Verify the checksum guard actually fires**

A checksum that never fails is not a check. Corrupt the cache and confirm it's caught:

```bash
echo tampered >> app/.deps/bin/ffmpeg
./scripts/fetch-deps.sh   # must re-download rather than accept it
```

Expected: `→ ffmpeg` (re-fetched, not `✓ ffmpeg (cached)`).

- [ ] **Step 6: Commit**

```bash
git add scripts/deps.lock scripts/fetch-deps.sh app/.gitignore
git commit -m "build: pin and fetch bundled dependencies with checksum verification"
```

---

### Task 6: Copy and sign the binaries into the bundle

**Files:**
- Modify: `app/project.yml`

**Interfaces:**
- Consumes: `app/.deps/bin/*` from Task 5, `binDirectory()` from Task 2.
- Produces: a signed bundle with `Contents/Resources/bin/{yt-dlp,ffmpeg,gallery-dl}`, every Mach-O carrying the runtime flag.

- [ ] **Step 1: Add the entitlement**

PyInstaller `--onefile` binaries unpack their own `.so` files to a temp directory and `dlopen` them at runtime. Those libraries are inside the appended archive, not signed individually, so Hardened Runtime's library validation kills both `yt-dlp` and `gallery-dl` on launch. In `app/project.yml`, extend the `entitlements.properties` block added for Apple Events:

```yaml
    entitlements:
      path: Carabiner/Carabiner.entitlements
      properties:
        com.apple.security.automation.apple-events: true
        # yt-dlp and gallery-dl are PyInstaller one-file builds: they extract their own
        # .so files to a temp dir and dlopen them, which library validation refuses
        # because those libraries aren't signed by us. This is a real weakening of the
        # hardening and it is load-bearing — without it both tools die instantly. The
        # alternative is --onedir builds with every nested .so signed; revisit if the
        # temp-extraction cost or this entitlement ever becomes a problem.
        com.apple.security.cs.disable-library-validation: true
```

- [ ] **Step 2: Add the copy phase**

Add to the `Carabiner` target's `sources` in `app/project.yml`:

```yaml
      - path: .deps/bin
        buildPhase: resources
        name: bin
```

- [ ] **Step 3: Sign every nested Mach-O**

Xcode only auto-signs nested code in `Frameworks`, `PlugIns` and `XPCServices`; anything in `Resources` is sealed as data and left unsigned, which notarization rejects. Add a second entry to `postBuildScripts` in `app/project.yml`, **after** the existing xattr strip (post-build scripts run before Xcode's own CodeSign step, which is exactly the window we need):

```yaml
      - name: Sign bundled binaries with Hardened Runtime
        basedOnDependencyAnalysis: false
        script: |
          set -euo pipefail
          BIN="$TARGET_BUILD_DIR/$WRAPPER_NAME/Contents/Resources/bin"
          [ -d "$BIN" ] || { echo "note: no bundled binaries (run scripts/fetch-deps.sh)"; exit 0; }
          for f in "$BIN"/*; do
            [ -f "$f" ] || continue
            # --options runtime on every Mach-O, or notarization rejects the whole app.
            codesign --force --sign "$EXPANDED_CODE_SIGN_IDENTITY" \
              --options runtime --timestamp=none "$f"
            codesign --verify --strict "$f"
          done
```

- [ ] **Step 4: Build and verify every binary is signed with the runtime flag**

```bash
export CARABINER_TEAM_ID=$(security find-certificate -a -c "Apple Development" -p \
  | openssl x509 -noout -subject | tr ',/' '\n\n' \
  | sed -nE 's/.*OU=([A-Z0-9]{10}).*/\1/p' | head -1)
cd app && xcodegen generate
xattr -cr build/Build/Products/Debug/Carabiner.app 2>/dev/null || true
xcodebuild -project Carabiner.xcodeproj -scheme Carabiner -configuration Debug \
  -derivedDataPath build build
APP=build/Build/Products/Debug/Carabiner.app
for f in "$APP"/Contents/Resources/bin/*; do
  printf '%-12s ' "$(basename "$f")"
  codesign -dv "$f" 2>&1 | grep -o 'flags=[^ ]*'
done
codesign --verify --deep --strict --verbose=2 "$APP"
```

Expected: `flags=0x10000(runtime)` for all three, and `satisfies its Designated Requirement` for the app.

- [ ] **Step 5: Commit**

```bash
git add app/project.yml
git commit -m "build(app): bundle and sign yt-dlp, ffmpeg and gallery-dl"
```

---

### Task 7: Prove it works without Homebrew

The whole phase is worthless if the app still quietly uses Homebrew. Everything so far would pass on a machine that has both.

**Files:**
- Modify: `CLAUDE.md`
- Modify: `README.md`

- [ ] **Step 1: Verify the app uses the bundled binaries, not Homebrew**

Install and launch the bundle (never the inner binary — gotcha #11):

```bash
pkill -x Carabiner; rm -rf ~/Applications/Carabiner.app
cp -R app/build/Build/Products/Debug/Carabiner.app ~/Applications/
open ~/Applications/Carabiner.app
```

Snapshot `~/Downloads`, grab an Instagram post with the hotkey, and diff (timestamps lie — gallery-dl preserves Instagram's mtime *and* birth time):

```bash
ls -1 ~/Downloads > /tmp/before.txt   # …fire the hotkey…
ls -1 ~/Downloads | diff /tmp/before.txt - | grep '^>'
```

Expected: the file appears, with a branded notification.

- [ ] **Step 2: Prove Homebrew is not involved**

This is the test that actually matters. Temporarily move Homebrew's copies aside and repeat the grab:

```bash
for b in yt-dlp ffmpeg gallery-dl; do sudo mv "/opt/homebrew/bin/$b" "/opt/homebrew/bin/$b.off"; done
```

Fire the hotkey on an Instagram post, confirm the file still lands in `~/Downloads`, then restore:

```bash
for b in yt-dlp ffmpeg gallery-dl; do sudo mv "/opt/homebrew/bin/$b.off" "/opt/homebrew/bin/$b"; done
```

Expected: the grab succeeds with Homebrew's tools gone. If it fails, `CARABINER_BIN` is not reaching the script — re-check Task 1 and Task 2 before going further.

- [ ] **Step 3: Confirm the Shortcut path is unaffected**

```bash
CARABINER_NO_NOTIFY=1 ./carabiner -s 1 'https://www.instagram.com/p/SHORTCODE/'
./test/test-path.sh
```

Expected: the grab works via Homebrew as before, and all `test-path.sh` cases pass.

- [ ] **Step 4: Record the new gotchas**

Add to `CLAUDE.md`, after gotcha #16:

```markdown
17. **Bundled binaries are shadowed by Homebrew unless `CARABINER_BIN` comes first, and
    you cannot detect that on a dev machine.** `carabiner` prepends
    `/opt/homebrew/bin:/usr/local/bin` to `PATH` so it can find its deps under the
    stripped-down environment a hotkey provides (gotcha #8). That same line used to run
    *after* whatever the app set, so the app's private copies lost every time — on any
    machine that also has Homebrew's yt-dlp, which is every machine this gets tested on.
    Bundling would have looked like it worked. `CARABINER_BIN` is now prepended ahead of
    Homebrew, and the only honest test is moving Homebrew's copies aside and grabbing
    again. `test/test-path.sh` covers the resolution order without touching the network.

18. **Nothing in `Contents/Resources` gets signed for you.** Xcode auto-signs nested code
    only in `Frameworks`, `PlugIns` and `XPCServices`; a Mach-O in `Resources` is sealed
    as data and left unsigned, and notarization rejects the whole app for it. The
    bundled binaries are signed by a `postBuildScripts` phase with `--options runtime`,
    which works because post-build scripts run *before* Xcode's CodeSign step — the same
    window the iCloud xattr strip uses (gotcha #13). Verify with
    `codesign -dv <binary> | grep flags` — every one must show `0x10000(runtime)`.

19. **PyInstaller binaries need `disable-library-validation`.** `yt-dlp_macos` and our
    `gallery-dl` are one-file PyInstaller builds: they unpack their own `.so` files to a
    temp directory and `dlopen` them. Those libraries aren't signed by us, so Hardened
    Runtime's library validation refuses to load them and both tools die instantly. The
    entitlement is load-bearing, not optional — and it genuinely weakens the hardening,
    which is the price of not building our own Python distribution. Upstream ships **no**
    macOS binaries for gallery-dl at all (0 release assets), which is why we build it.
```

- [ ] **Step 5: Update the README install instructions**

Replace the "clone + setup.sh" requirement for app users. Add above the existing script instructions:

```markdown
## Install the app (recommended)

1. Download the latest `Carabiner.dmg` from [Releases](https://github.com/off-piste-mcg/carabiner/releases).
2. Drag **Carabiner** to Applications, then open it.
3. Click **Allow** when macOS asks about controlling your browser and sending notifications.
4. Open an Instagram post and press ⌃⌥⌘V.

No Terminal, no Homebrew — the app carries its own copies of `yt-dlp`, `ffmpeg` and
`gallery-dl`.

> If you also use the Shortcut, unbind its keyboard shortcut first: a global chord has
> exactly one owner, and whichever registers second silently gets nothing.
```

- [ ] **Step 6: Commit**

```bash
git add CLAUDE.md README.md
git commit -m "docs: record the bundling gotchas and the no-Terminal install"
```

---

## Self-Review

**Spec coverage.** Spec phase 2 asks for: bundled yt-dlp/ffmpeg/gallery-dl (Tasks 3–6), "app no longer needs Homebrew" (Task 7 step 2 proves it), the PATH blocker fixed first (Task 1), and "decide deliberately whether the script stays shared with the Shortcut path" — decided: it stays shared, one engine, `CARABINER_BIN` is the only seam (Task 1, verified in Task 7 step 3). "Adapt the script's result output for the app" needs no work: `GrabRunner` already parses `✓ ` lines and that contract is unchanged.

**Deliberately out of scope.** Sparkle auto-update and Developer ID notarization are spec phases 4–5 and get their own plan. The spec's "~150 MB, all three universal" estimate holds: 36 MB yt-dlp + ~80 MB universal ffmpeg + ~25 MB gallery-dl.

**Known risk, flagged not hidden.** `--target-arch universal2` in Task 4 depends on the runner's Python being a universal2 framework build. If PyInstaller refuses, the fallback is an arm64-only gallery-dl plus a documented Apple-Silicon-only requirement — `lipo` is *not* an option for one-file builds, as the task explains. Task 4 step 2's `lipo -archs` check catches this immediately rather than at notarization time.
