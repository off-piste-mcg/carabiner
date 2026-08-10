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

# --- preflight gate -------------------------------------------------------------------
# Everything below runs against the built bundle BEFORE anything is uploaded. Each check
# is a rejection notarytool would hand back as JSON behind a URL twenty minutes later.
#
# NOTE ON STYLE, because the obvious spelling is broken here. These all capture codesign's
# output into a variable and match it with a bash pattern, rather than the natural
# `codesign -dv "$f" 2>&1 | grep -q PATTERN`. Under `set -o pipefail` that pipeline is
# actively wrong: grep -q exits the instant it matches, codesign takes SIGPIPE, and the
# pipeline reports 141 — so the check FAILS exactly when the pattern is FOUND. Every gate
# here would have rejected a correctly signed Release build, and the get-task-allow gate
# would have inverted and waved a Debug build through to notarization. Caught by
# test-release.sh before the first real run; do not "simplify" these back into pipelines.

assert_hardened_runtime() {  # $1 = signed bundle or binary
  local out; out="$(codesign -dv "$1" 2>&1)"
  [[ "$out" == *"flags="*"runtime"* ]] \
    || die "$1 is not signed with the Hardened Runtime.
  Expected flags=0x10000(runtime). Notarization requires it."
}

assert_no_get_task_allow() {  # $1 = bundle
  # Xcode injects this into Debug builds only, and notarization rejects any binary that
  # carries it (gotcha #16). A Debug build looks identical to a Release one at a glance,
  # which makes this the likeliest way to waste a round-trip.
  local ents; ents="$(codesign -d --entitlements - --xml "$1" 2>/dev/null)"
  if [[ "$ents" == *"get-task-allow"* ]]; then
    die "$1 carries com.apple.security.get-task-allow — this is a Debug build.
  Notarization rejects it. Build with -configuration Release."
  fi
}

assert_timestamped() {  # $1 = signed bundle or binary
  # codesign prints "Timestamp=" for a secure timestamp and "Signed Time=" for none, so
  # the anchor matters: an unanchored match would accept the un-timestamped case, since
  # "Signed Time=" does not contain "Timestamp=" but a sloppier pattern could.
  local out; out="$(codesign -dvv "$1" 2>&1)"
  [[ "$out" == *$'\n'"Timestamp="* || "$out" == "Timestamp="* ]] \
    || die "$1 has no secure timestamp.
  Notarization requires one on every signature. Check that CONFIGURATION=Release
  reached the bundled-binary signing loop in app/project.yml."
}

assert_developer_id() {  # $1 = bundle
  # Catches a CARABINER_RELEASE_TEAM_ID that expanded to empty, which produces a build
  # signed with whatever identity came to hand rather than an outright failure.
  local out; out="$(codesign -dvv "$1" 2>&1)"
  [[ "$out" == *"Authority=$IDENTITY"* ]] \
    || die "$1 is not signed by \"$IDENTITY\".
  Is CARABINER_RELEASE_TEAM_ID set? Actual authority:
  $(printf '%s\n' "$out" | sed -n 's/^Authority=/  /p' | head -1)"
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

# --- pipeline -------------------------------------------------------------------------

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
  local spctl_out; spctl_out="$(spctl -a -vvv -t install "$app" 2>&1)"
  [[ "$spctl_out" == *accepted* ]] \
    || die "spctl rejected the app — Gatekeeper would warn on a teammate's machine:
  $spctl_out"

  note "done: $dmg"
  note "publish with: gh release create v$version \"$dmg\" --title \"Carabiner $version\""
}

# Run only when executed, never when sourced.
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  main "$@"
fi
