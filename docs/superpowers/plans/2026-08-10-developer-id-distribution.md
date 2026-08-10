# Developer ID Distribution Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Produce a notarized, stapled `Carabiner.dmg` that a non-technical teammate can download, drag to Applications, and open with no Gatekeeper warning.

**Architecture:** A Release build configuration in `app/project.yml` signs with the org's Developer ID Application certificate and secure timestamps; `scripts/release.sh` drives build → local preflight gate → notarize app → DMG → notarize DMG → staple → verify. The gate is the substance: it catches the two rejections that cost a round-trip (`get-task-allow`, missing timestamps) locally, in seconds.

**Tech Stack:** bash, XcodeGen 2.46.0, `xcodebuild`, `codesign`, `xcrun notarytool`, `xcrun stapler`, `hdiutil`, `spctl`.

## Global Constraints

- **Spec:** `docs/superpowers/specs/2026-08-10-developer-id-distribution-design.md`.
- **Deployment target:** macOS 13.0. Do not change it.
- **Dependency-light:** no new Homebrew packages, no `create-dmg`. `hdiutil` only.
- **Debug behaviour must not change.** Every dev build today signs with `Apple Development` and `--timestamp=none`; a Debug build after this work must be byte-for-byte equivalent in configuration. Debug is the path gotcha #11 depends on.
- **Post-build script order is load-bearing.** The iCloud xattr strip stays **last** in `postBuildScripts` (gotcha #13). Add nothing below it.
- **Team ID comes from the certificate's `OU` field**, never the parenthetical in the identity name (gotcha #12).
- **Never notarize a Debug build** — Xcode injects `com.apple.security.get-task-allow` and notarization rejects it (gotcha #16).
- **Two team variables:** `CARABINER_TEAM_ID` (Debug, from the `Apple Development` cert) and `CARABINER_RELEASE_TEAM_ID` (Release, from the `Developer ID Application` cert). They are different teams and must not be merged.
- Shell tests live in `test/`, are offline, and follow `test/test-path.sh`'s `check()` / pass-fail-counter style.

---

### Task 1: Release build configuration and the secure-timestamp fix

The bundled-binary signing loop currently passes `--timestamp=none` unconditionally. Notarization requires a secure timestamp on every signature, so all ~117 nested Mach-Os would be rejected. The flag stays correct for Debug (one TSA round-trip per file would make dev builds crawl), so it branches on `$CONFIGURATION`.

**Files:**
- Modify: `app/project.yml:66-67` (the `codesign` invocation in "Sign bundled binaries with Hardened Runtime")
- Modify: `app/project.yml:127-157` (the `Carabiner` target's `settings`)

**Interfaces:**
- Consumes: nothing.
- Produces: a `Release` build configuration that signs with `Developer ID Application` and reads `DEVELOPMENT_TEAM` from the environment variable `CARABINER_RELEASE_TEAM_ID`. Task 4 sets that variable and builds `-configuration Release`.

- [ ] **Step 1: Add the `$CONFIGURATION` branch to the signing loop**

In `app/project.yml`, inside the "Sign bundled binaries with Hardened Runtime" script, immediately after the `[ -d "$BIN" ] || { ... }` guard, add:

```bash
          # Notarization requires a secure timestamp on EVERY signature, and this loop
          # signs ~117 nested Mach-Os. A timestamp is a network round-trip to Apple's TSA
          # per file, so paying it on every dev build is the kind of friction that gets a
          # build script abandoned — Debug keeps --timestamp=none, Release earns the wait.
          # Getting this backwards is invisible until notarytool rejects the whole upload.
          if [ "${CONFIGURATION:-Debug}" = "Release" ]; then
            TIMESTAMP_FLAG="--timestamp"
          else
            TIMESTAMP_FLAG="--timestamp=none"
          fi
```

Then change the `codesign` call from `--timestamp=none` to `"$TIMESTAMP_FLAG"`:

```bash
            codesign --force --sign "$EXPANDED_CODE_SIGN_IDENTITY" \
              --options runtime "$TIMESTAMP_FLAG" "$f"
```

- [ ] **Step 2: Add the Release configuration to the `Carabiner` target**

In `app/project.yml`, the `Carabiner` target's `settings:` block currently has only `base:`. Keep `base:` exactly as it is and add a sibling `configs:` block after it:

```yaml
      configs:
        # Distribution signing. Deliberately NOT in base: Debug must keep signing with
        # Apple Development, because that is what the branded notification depends on
        # (gotcha #11) and it is what every dev build has always used.
        Release:
          # Developer ID needs no provisioning profile — apple-events is a Hardened
          # Runtime entitlement, not a capability — so Manual signing is both sufficient
          # and deterministic. Automatic would want -allowProvisioningUpdates and can
          # silently resolve to a different identity than the one intended.
          CODE_SIGN_STYLE: Manual
          CODE_SIGN_IDENTITY: "Developer ID Application"
          # A DIFFERENT team from CARABINER_TEAM_ID. That one comes from the Apple
          # Development certificate, which is a personal team; this one is OFF-PISTE B.V.
          # XcodeGen writes ${VAR} through literally and xcodebuild expands it at BUILD
          # time, so this resolves from scripts/release.sh's environment.
          DEVELOPMENT_TEAM: ${CARABINER_RELEASE_TEAM_ID}
          # The app's own signature needs a secure timestamp too, not just the bundled
          # binaries Task 1 Step 1 covers.
          OTHER_CODE_SIGN_FLAGS: "--timestamp"
```

- [ ] **Step 3: Regenerate and assert the Release settings landed**

```bash
cd app && xcodegen generate
```

Run:
```bash
grep -A2 'CODE_SIGN_IDENTITY = "Developer ID Application"' app/Carabiner.xcodeproj/project.pbxproj | head -20
```
Expected: shows `CODE_SIGN_STYLE = Manual;` and `DEVELOPMENT_TEAM = "${CARABINER_RELEASE_TEAM_ID}";` — the variable **unexpanded**, which confirms xcodebuild resolves it at build time.

- [ ] **Step 4: Assert Debug is unchanged**

Run:
```bash
grep -c 'CODE_SIGN_IDENTITY = "Apple Development"' app/Carabiner.xcodeproj/project.pbxproj
```
Expected: `4` — Debug and Release for both the `Carabiner` and `CarabinerTests` targets *before* the Release override applies to the app target, so this count will now be `3`. Record whichever value you get and confirm by reading the surrounding block that the app target's Debug config still says `Apple Development` and the test target still says it for both configs.

- [ ] **Step 5: Build Debug and confirm it still signs and runs**

```bash
export CARABINER_TEAM_ID=$(security find-certificate -a -c "Apple Development" -p \
  | openssl x509 -noout -subject | tr ',/' '\n\n' \
  | sed -nE 's/.*OU=([A-Z0-9]{10}).*/\1/p' | head -1)
cd app && xcodebuild -project Carabiner.xcodeproj -scheme Carabiner \
  -configuration Debug -derivedDataPath build build 2>&1 | tail -5
```
Expected: `** BUILD SUCCEEDED **`. This proves the `$CONFIGURATION` branch defaults correctly — the Debug path must still take `--timestamp=none`, or the build would slow to a crawl making 117 TSA calls.

- [ ] **Step 6: Confirm the Debug bundled binaries are still un-timestamped**

Run:
```bash
codesign -dvv app/build/Build/Products/Debug/Carabiner.app/Contents/Resources/bin/ffmpeg 2>&1 | grep -E '^(Timestamp|Signed Time)='
```
Expected: a `Signed Time=` line and **no** `Timestamp=` line. A `Timestamp=` line here means the branch took the Release path in a Debug build.

- [ ] **Step 7: Commit**

```bash
git add app/project.yml
git commit -m "build: add Release config with Developer ID signing and secure timestamps

The bundled-binary signing loop passed --timestamp=none unconditionally,
which notarization rejects on every one of the ~117 nested Mach-Os. It is
still right for Debug — a secure timestamp is a TSA round-trip per file —
so it now branches on CONFIGURATION."
```

---

### Task 2: `release.sh` preconditions and team-ID derivation

The script must be sourceable so Task 3 can unit-test its gate functions without running a build.

**Files:**
- Create: `scripts/release.sh`
- Create: `test/test-release.sh`

**Interfaces:**
- Produces, for Tasks 3 and 4:
  - `die MESSAGE` — prints `release: MESSAGE` to stderr, exits 1.
  - `note MESSAGE` — prints `==> MESSAGE` to stdout.
  - `developer_id_team` — prints the 10-character team OU of the `Developer ID Application` certificate to stdout; prints nothing if absent.
  - `require_developer_id_cert` — `die`s with a fix command if no such certificate.
  - `require_notary_profile` — `die`s with a fix command if the `carabiner` notarytool profile is not stored.
  - Constants `NOTARY_PROFILE=carabiner`, `IDENTITY="Developer ID Application"`.
  - Sourcing guard: the file defines functions and runs nothing when sourced.

- [ ] **Step 1: Write the failing test**

Create `test/test-release.sh`:

```bash
#!/usr/bin/env bash
# Tests for scripts/release.sh. No network, no builds, no uploads: we source the script
# for its functions and drive them against stubs and real local artifacts.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RELEASE="$HERE/../scripts/release.sh"
pass=0; fail=0

check() {  # $1 = label, $2 = expected, $3 = actual
  if [ "$2" = "$3" ]; then
    printf '  ok   %s\n' "$1"; pass=$((pass + 1))
  else
    printf '  FAIL %s\n       expected: %s\n       actual:   %s\n' "$1" "$2" "$3"; fail=$((fail + 1))
  fi
}

echo "test-release.sh"

# Sourcing must define functions and run NOTHING. If the sourcing guard is wrong this
# kicks off a real build, which is exactly the accident the guard exists to prevent.
# shellcheck source=/dev/null
source "$RELEASE"

check "sourcing defines die"                 "function" "$(type -t die)"
check "sourcing defines developer_id_team"   "function" "$(type -t developer_id_team)"
check "notary profile name"                  "carabiner" "$NOTARY_PROFILE"

# A stubbed `security` returning a cert whose OU is the team ID. The OU is the ONLY
# correct source (gotcha #12) — the parenthetical in the CN is the agent ID and signing
# fails with it. So the stub deliberately makes those two DIFFER: a naive parse of the
# CN would return AGENT00000 and this test would catch it.
STUB="$(mktemp -d)"
trap 'rm -rf "$STUB"' EXIT
openssl req -x509 -newkey rsa:2048 -nodes -days 1 \
  -keyout "$STUB/k.pem" -out "$STUB/c.pem" \
  -subj "/CN=Developer ID Application: OFF-PISTE B.V. (AGENT00000)/OU=TEAM123456/O=OFF-PISTE B.V." \
  >/dev/null 2>&1
cat > "$STUB/security" <<'EOF'
#!/bin/bash
# Only the find-certificate call is stubbed; anything else is a test bug.
[ "$1" = "find-certificate" ] || { echo "unexpected security call: $*" >&2; exit 2; }
cat "$STUB_CERT"
EOF
chmod +x "$STUB/security"

actual="$(PATH="$STUB:$PATH" STUB_CERT="$STUB/c.pem" developer_id_team)"
check "team comes from OU, not the CN parenthetical" "TEAM123456" "$actual"

# No certificate at all → empty, so require_developer_id_cert can fail with advice.
cat > "$STUB/security" <<'EOF'
#!/bin/bash
exit 1
EOF
chmod +x "$STUB/security"
actual="$(PATH="$STUB:$PATH" developer_id_team 2>/dev/null)"
check "no certificate yields empty team" "" "$actual"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
```

- [ ] **Step 2: Run it to make sure it fails**

Run: `chmod +x test/test-release.sh && ./test/test-release.sh`
Expected: FAIL — `scripts/release.sh: No such file or directory`.

- [ ] **Step 3: Write the minimal implementation**

Create `scripts/release.sh`:

```bash
#!/usr/bin/env bash
# Build, notarize and staple a distributable Carabiner.dmg.
#
# Usage: ./scripts/release.sh [version]
#
# Everything here needs a Developer ID Application certificate and a stored notarytool
# credential profile — see docs/superpowers/specs/2026-08-10-developer-id-distribution-design.md.
# The script refuses to start without them rather than failing halfway through a build.
#
# Sourceable: `source scripts/release.sh` defines the functions and runs nothing, which
# is how test/test-release.sh exercises the preflight gate without doing a build.
set -uo pipefail

IDENTITY="Developer ID Application"
NOTARY_PROFILE="carabiner"

die()  { printf 'release: %s\n' "$*" >&2; exit 1; }
note() { printf '==> %s\n' "$*"; }

# The team ID lives in the certificate's OU field. NOT the parenthetical in the identity
# name — that is the agent ID, and signing with it fails with "No signing certificate
# matching team ID". Same trap as gotcha #12, different certificate.
developer_id_team() {
  security find-certificate -a -c "$IDENTITY" -p 2>/dev/null \
    | openssl x509 -noout -subject 2>/dev/null \
    | tr ',/' '\n\n' \
    | sed -nE 's/.*OU=([A-Z0-9]{10}).*/\1/p' \
    | head -1
}

require_developer_id_cert() {
  [ -n "$(developer_id_team)" ] || die "no \"$IDENTITY\" certificate in the keychain.
  Create one: Xcode > Settings > Accounts > the OFF-PISTE team > Manage Certificates
  > + > Developer ID Application. Needs the Account Holder role."
}

require_notary_profile() {
  xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1 \
    || die "no stored notarytool profile named \"$NOTARY_PROFILE\".
  Create one: xcrun notarytool store-credentials $NOTARY_PROFILE
  It asks for your Apple ID, the team ID, and an app-specific password
  from appleid.apple.com (not your account password)."
}

main() {
  require_developer_id_cert
  require_notary_profile
  note "preconditions ok — team $(developer_id_team)"
}

# Run only when executed, never when sourced.
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  main "$@"
fi
```

- [ ] **Step 4: Run the tests and make sure they pass**

Run: `chmod +x scripts/release.sh && ./test/test-release.sh`
Expected: `3 passed... ` through `5 passed, 0 failed`, exit 0.

- [ ] **Step 5: Prove the preconditions actually fire**

This is the one thing in this plan that can be honestly verified today, because the preconditions are genuinely absent on this machine.

Run: `./scripts/release.sh`
Expected: exits 1 with `release: no "Developer ID Application" certificate in the keychain.` followed by the Xcode instructions. **If it gets past that line, the check is broken** — there is no such certificate right now.

- [ ] **Step 6: Commit**

```bash
git add scripts/release.sh test/test-release.sh
git commit -m "feat(release): preconditions and Developer ID team derivation"
```

---

### Task 3: The preflight gate

Four assertions run against the built bundle before anything is uploaded. Notarytool's rejection output is a JSON log behind a URL; discovering a flag there that a local `codesign` call would have caught is a wasted round-trip.

**Files:**
- Modify: `scripts/release.sh` (add functions, extend `main`)
- Modify: `test/test-release.sh` (add gate tests)

**Interfaces:**
- Consumes: `die`, `note` from Task 2.
- Produces, for Task 4:
  - `assert_hardened_runtime PATH`
  - `assert_no_get_task_allow BUNDLE`
  - `assert_timestamped PATH`
  - `assert_developer_id BUNDLE`
  - `preflight BUNDLE` — runs all four over the bundle and every Mach-O under `Contents/Resources/bin`.

- [ ] **Step 1: Write the failing tests**

Append to `test/test-release.sh`, immediately before the final `printf`:

```bash
# --- preflight gate -------------------------------------------------------------------
# Driven against a REAL locally-built Debug bundle, not a fabricated fixture. A Debug
# build genuinely carries get-task-allow and genuinely lacks secure timestamps, so it is
# a true negative for two of the four gates. A stub that merely echoed the strings we
# grep for would prove only that grep works — gotcha #23's lesson.
DEBUG_APP="$HERE/../app/build/Build/Products/Debug/Carabiner.app"
if [ -d "$DEBUG_APP" ]; then
  # Debug IS hardened (ENABLE_HARDENED_RUNTIME is on in every build, gotcha #16), so
  # this gate must PASS on it.
  (assert_hardened_runtime "$DEBUG_APP") >/dev/null 2>&1
  check "hardened-runtime gate passes a Debug build" "0" "$?"

  # ...but Debug carries get-task-allow, so this gate must FAIL on it. This is the check
  # that stops us uploading a Debug build (gotcha #16).
  (assert_no_get_task_allow "$DEBUG_APP") >/dev/null 2>&1
  check "get-task-allow gate rejects a Debug build" "1" "$?"

  # ...and Debug signs with --timestamp=none, so this must FAIL on a bundled binary.
  if [ -e "$DEBUG_APP/Contents/Resources/bin/ffmpeg" ]; then
    (assert_timestamped "$DEBUG_APP/Contents/Resources/bin/ffmpeg") >/dev/null 2>&1
    check "timestamp gate rejects an un-timestamped binary" "1" "$?"
  else
    printf '  skip timestamp gate (no bundled binaries — run scripts/fetch-deps.sh)\n'
  fi

  # Debug is signed Apple Development, not Developer ID, so this must FAIL too.
  (assert_developer_id "$DEBUG_APP") >/dev/null 2>&1
  check "developer-id gate rejects an Apple Development build" "1" "$?"
else
  printf '  skip preflight gate tests (no Debug build — see Task 1 Step 5)\n'
fi
```

- [ ] **Step 2: Run to verify they fail**

Run: `./test/test-release.sh`
Expected: FAIL — `assert_hardened_runtime: command not found`, and the `check` lines report `expected: 0 actual: 127`.

- [ ] **Step 3: Write the implementation**

In `scripts/release.sh`, add after `require_notary_profile`:

```bash
# --- preflight gate -------------------------------------------------------------------
# Everything below runs against the built bundle BEFORE anything is uploaded. Each check
# is a rejection notarytool would hand back as JSON behind a URL twenty minutes later.

assert_hardened_runtime() {  # $1 = signed bundle or binary
  codesign -dv "$1" 2>&1 | grep -q 'flags=.*runtime' \
    || die "$1 is not signed with the Hardened Runtime.
  Expected flags=0x10000(runtime). Notarization requires it."
}

assert_no_get_task_allow() {  # $1 = bundle
  # Xcode injects this into Debug builds only, and notarization rejects any binary that
  # carries it (gotcha #16). A Debug build looks identical to a Release one at a glance,
  # which makes this the likeliest way to waste a round-trip.
  if codesign -d --entitlements - --xml "$1" 2>/dev/null \
     | plutil -p - 2>/dev/null | grep -q 'get-task-allow'; then
    die "$1 carries com.apple.security.get-task-allow — this is a Debug build.
  Notarization rejects it. Build with -configuration Release."
  fi
}

assert_timestamped() {  # $1 = signed bundle or binary
  # codesign prints "Timestamp=" for a secure timestamp and "Signed Time=" for none, so
  # the anchor matters: a substring match would accept the un-timestamped case.
  codesign -dvv "$1" 2>&1 | grep -q '^Timestamp=' \
    || die "$1 has no secure timestamp.
  Notarization requires one on every signature. Check that CONFIGURATION=Release
  reached the bundled-binary signing loop in app/project.yml."
}

assert_developer_id() {  # $1 = bundle
  # Catches a CARABINER_RELEASE_TEAM_ID that expanded to empty, which produces a build
  # signed with whatever identity came to hand rather than an outright failure.
  codesign -dvv "$1" 2>&1 | grep -q "Authority=$IDENTITY" \
    || die "$1 is not signed by \"$IDENTITY\".
  Is CARABINER_RELEASE_TEAM_ID set? Actual authority:
  $(codesign -dvv "$1" 2>&1 | grep '^Authority=' | head -1)"
}

preflight() {  # $1 = bundle
  local app="$1" f count=0
  note "preflight: $app"
  assert_hardened_runtime "$app"
  assert_no_get_task_allow "$app"
  assert_timestamped "$app"
  assert_developer_id "$app"

  # Every nested Mach-O too. Resources/ is sealed as data and signed by our own
  # post-build script (gotcha #19), so it is exactly where an unsigned or un-timestamped
  # file hides.
  if [ -d "$app/Contents/Resources/bin" ]; then
    while IFS= read -r f; do
      file -b "$f" | grep -q "Mach-O" || continue
      assert_hardened_runtime "$f"
      assert_timestamped "$f"
      count=$((count + 1))
    done < <(find "$app/Contents/Resources/bin" -type f)
    note "preflight: $count bundled Mach-Os hardened and timestamped"
  else
    die "no Contents/Resources/bin — run scripts/fetch-deps.sh before releasing.
  Shipping without it produces an app that silently needs Homebrew on the
  recipient's machine, which is the whole reason bundling exists."
  fi
  note "preflight passed"
}
```

- [ ] **Step 4: Run the tests and make sure they pass**

Run: `./test/test-release.sh`
Expected: `9 passed, 0 failed`, exit 0. If the timestamp check reports `skip`, run `./scripts/fetch-deps.sh` and rebuild Debug (Task 1 Step 5) first — that gate is the one guarding the defect this whole phase turns on.

- [ ] **Step 5: Commit**

```bash
git add scripts/release.sh test/test-release.sh
git commit -m "feat(release): preflight gate catching Debug builds and missing timestamps"
```

---

### Task 4: Build, notarize, DMG, staple, verify

**Files:**
- Modify: `scripts/release.sh` (add the pipeline, extend `main`)
- Modify: `.gitignore` (add `dist/`)

**Interfaces:**
- Consumes: `die`, `note`, `preflight`, `NOTARY_PROFILE`, `developer_id_team`.
- Produces: `dist/Carabiner-<version>.dmg`, notarized and stapled.

- [ ] **Step 1: Add `dist/` to `.gitignore`**

Append to `.gitignore`:

```
# Release artifacts from scripts/release.sh — DMGs are ~150 MB, never committed.
dist/
```

- [ ] **Step 2: Write the pipeline**

In `scripts/release.sh`, replace `main()` entirely with:

```bash
build_app() {  # $1 = staging dir; echoes the built .app path
  local stage="$1"
  # Derived data goes in the staging temp dir, not the repo: this repo is under
  # ~/Documents and iCloud's file provider stamps com.apple.FinderInfo on anything that
  # sits there, which codesign refuses outright (gotcha #13).
  ( cd "$REPO/app" && xcodegen generate \
      && xcodebuild -project Carabiner.xcodeproj -scheme Carabiner \
           -configuration Release -derivedDataPath "$stage/dd" \
           build ) >"$stage/build.log" 2>&1 \
    || { tail -30 "$stage/build.log" >&2; die "Release build failed — full log at $stage/build.log"; }
  printf '%s' "$stage/dd/Build/Products/Release/Carabiner.app"
}

notarize() {  # $1 = path to .zip or .dmg
  note "notarizing $(basename "$1") — this takes a few minutes"
  xcrun notarytool submit "$1" --keychain-profile "$NOTARY_PROFILE" --wait \
    || die "notarization failed for $1.
  Read the log with:
    xcrun notarytool log <submission-id> --keychain-profile $NOTARY_PROFILE"
}

make_dmg() {  # $1 = staging dir, $2 = stapled .app, $3 = output dmg path
  local stage="$1" app="$2" out="$3" root="$1/dmgroot"
  rm -rf "$root"; mkdir -p "$root"
  cp -R "$app" "$root/"
  ln -s /Applications "$root/Applications"
  # Strip iCloud detritus from the staging tree before it is sealed into the image
  # (gotcha #13) — cp -R carries xattrs across.
  xattr -cr "$root"
  rm -f "$out"
  hdiutil create -volname "Carabiner" -srcfolder "$root" -ov -format UDZO "$out" \
    >/dev/null || die "hdiutil failed to build $out"
}

main() {
  local version="${1:-}"
  REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

  require_developer_id_cert
  require_notary_profile
  CARABINER_RELEASE_TEAM_ID="$(developer_id_team)"
  export CARABINER_RELEASE_TEAM_ID
  note "signing as team $CARABINER_RELEASE_TEAM_ID"

  # Idempotent; a release without bundled binaries is an app that silently needs Homebrew.
  "$REPO/scripts/fetch-deps.sh" || die "scripts/fetch-deps.sh failed"

  local stage; stage="$(mktemp -d)"
  trap 'rm -rf "$stage"' EXIT

  note "building Release"
  local app; app="$(build_app "$stage")"
  [ -d "$app" ] || die "no app at $app after a successful build"

  preflight "$app"

  # Notarize the app itself, not just the DMG. Stapling only the DMG leaves the installed
  # copy relying on an online Gatekeeper check — fine until a colleague first opens it
  # offline. ditto, not zip: zip mangles symlinks and bundle structure.
  note "zipping for notarization"
  ditto -c -k --keepParent "$app" "$stage/Carabiner.zip" || die "ditto failed"
  notarize "$stage/Carabiner.zip"
  xcrun stapler staple "$app" || die "stapling the app failed"

  version="${version:-$(defaults read "$app/Contents/Info" CFBundleShortVersionString)}"
  mkdir -p "$REPO/dist"
  local dmg="$REPO/dist/Carabiner-$version.dmg"

  note "building $dmg"
  make_dmg "$stage" "$app" "$stage/Carabiner.dmg"
  notarize "$stage/Carabiner.dmg"
  xcrun stapler staple "$stage/Carabiner.dmg" || die "stapling the DMG failed"
  cp "$stage/Carabiner.dmg" "$dmg"

  note "verifying"
  xcrun stapler validate "$dmg" || die "stapler validate failed on the DMG"
  spctl -a -vvv -t install "$app" 2>&1 | grep -q "accepted" \
    || die "spctl rejected the app — Gatekeeper would warn on a teammate's machine"

  note "done: $dmg"
  note "publish with: gh release create v$version \"$dmg\" --title \"Carabiner $version\""
}
```

- [ ] **Step 3: Syntax-check and re-run the unit tests**

Run:
```bash
bash -n scripts/release.sh && ./test/test-release.sh
```
Expected: no syntax errors, `9 passed, 0 failed`. The sourcing-guard test is the important one here — `main` now does real work, so a broken guard would start a build inside the test run.

- [ ] **Step 4: Confirm it still refuses to run**

Run: `./scripts/release.sh`
Expected: still exits 1 on the missing certificate, before touching `fetch-deps.sh` or `xcodebuild`.

- [ ] **Step 5: Commit**

```bash
git add scripts/release.sh .gitignore
git commit -m "feat(release): build, notarize, DMG, staple and verify pipeline"
```

---

### Task 5: README download section

**Files:**
- Modify: `README.md` (insert before the existing `## Get it (once per Mac)` at line 16)

**Interfaces:**
- Consumes: the DMG naming convention from Task 4 (`Carabiner-<version>.dmg` on a GitHub Release).
- Produces: nothing consumed by later tasks.

- [ ] **Step 1: Insert the section**

Insert immediately above `## Get it (once per Mac)`:

```markdown
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

Everything below is the manual route: the script on its own, and the Shortcut. You do not
need it if you installed the app.
```

- [ ] **Step 2: Verify the release link resolves**

Run: `curl -sI https://github.com/off-piste-mcg/carabiner/releases/latest | head -1`
Expected: `HTTP/2 302` (or `200`). A `404` means no release has been published yet — expected until the first DMG ships, so record it rather than treating it as a failure.

- [ ] **Step 3: Commit**

```bash
git add README.md
git commit -m "docs: DMG install instructions for app users"
```

---

## After the plan

The first real `./scripts/release.sh` run happens once the Developer ID certificate and the notarytool profile exist. Expect a failure; the gates are built to make it legible. When it succeeds, record in `CLAUDE.md`:

- a new gotcha for whatever the first run actually caught, and
- an update to the `CARABINER_TEAM_ID` snippet noting the second, Release-only variable.

## Self-review

**Spec coverage.** Defect fix → Task 1. Release build configuration table → Task 1 Step 2. Preconditions → Task 2. Preflight gate (all four checks) → Task 3. Build/notarize/DMG/staple/verify, two notarization passes, temp-dir staging, `dist/` → Task 4. README → Task 5. Out-of-scope items (Sparkle, styled DMG, CI, `gh release create`) are absent from the tasks; publishing appears only as a printed hint in Task 4. Covered.

**Placeholders.** None: every code step carries the literal text to write, and the two conditional outcomes (Task 1 Step 4's grep count, Task 5 Step 2's 404) say what to record rather than leaving a decision open.

**Type consistency.** `die`/`note`/`developer_id_team`/`require_developer_id_cert`/`require_notary_profile` defined in Task 2 and used unchanged in Tasks 3 and 4. `assert_hardened_runtime`/`assert_no_get_task_allow`/`assert_timestamped`/`assert_developer_id`/`preflight` defined in Task 3, called in Task 4. `NOTARY_PROFILE` and `IDENTITY` defined once in Task 2. `CARABINER_RELEASE_TEAM_ID` is the same name in `app/project.yml` (Task 1) and `main` (Task 4).
