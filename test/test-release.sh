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

check "sourcing defines die"               "function"  "$(type -t die)"
check "sourcing defines developer_id_team" "function"  "$(type -t developer_id_team)"
check "notary profile name"                "carabiner" "$NOTARY_PROFILE"

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

# --- preflight gate -------------------------------------------------------------------
# Driven against a REAL locally-built Debug bundle, not a fabricated fixture. A Debug
# build genuinely carries get-task-allow and genuinely lacks secure timestamps, so it is
# a true negative for three of the four gates. A stub that merely echoed the strings we
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

  # --- appex coverage (Finding 3, fix round 1) -----------------------------------------
  # Same reasoning as the app-level block above, against the embedded appex instead: a
  # real Debug build, not a fabricated fixture, so the negative cases are genuine (Debug
  # carries get-task-allow and no secure timestamp on the appex too) and only the
  # hardened-runtime gate is a true positive (ENABLE_HARDENED_RUNTIME is on for every
  # build, gotcha #16). This also exercises preflight()'s own `find … -name '*.appex'`
  # discovery pattern, not just the assert_* functions it calls — those are already
  # covered generically by the positive-timestamp block further down.
  APPEX="$DEBUG_APP/Contents/PlugIns/CarabinerSafariExtension.appex"
  if [ -d "$APPEX" ]; then
    (assert_hardened_runtime "$APPEX") >/dev/null 2>&1
    check "hardened-runtime gate passes the embedded appex" "0" "$?"

    (assert_no_get_task_allow "$APPEX") >/dev/null 2>&1
    check "get-task-allow gate rejects a Debug-built appex" "1" "$?"

    (assert_timestamped "$APPEX") >/dev/null 2>&1
    check "timestamp gate rejects an un-timestamped appex" "1" "$?"

    (assert_developer_id "$APPEX") >/dev/null 2>&1
    check "developer-id gate rejects an Apple Development appex" "1" "$?"

    # preflight()'s own discovery pattern, run in isolation: proves the *.appex glob
    # under -maxdepth 1 finds exactly the one embedded appex, neither zero (silently
    # skipping the whole check, which is what shipping a build with no appex embedded
    # would look like from inside the loop) nor more than one.
    actual_count=0
    while IFS= read -r -d ''; do actual_count=$((actual_count + 1)); done \
      < <(find "$DEBUG_APP/Contents/PlugIns" -maxdepth 1 -name '*.appex' -print0)
    check "preflight finds exactly one embedded appex" "1" "$actual_count"
  else
    printf '  skip appex gate tests (no embedded appex — rebuild after task 10)\n'
  fi
else
  printf '  skip preflight gate tests (no Debug build — see the plan, Task 1 Step 5)\n'
fi

# The match path deserves its own test, because that is where the bug was: these gates
# were originally written as `codesign ... | grep -q`, and under pipefail grep -q's early
# exit gives codesign a SIGPIPE, so the pipeline reported 141 — failing precisely when
# the pattern was FOUND. Every negative test above still passed. Only a positive case
# catches it, so here is a genuinely timestamped binary rather than a fixture.
#
# This is the one test that needs the network (a secure timestamp is a round-trip to
# Apple's TSA, which is the whole reason Debug skips it). It skips rather than fails
# when offline or when no signing identity is around.
DEV_ID="$(security find-identity -v -p codesigning 2>/dev/null \
  | sed -nE 's/.*"(Apple Development: [^"]*)".*/\1/p' | head -1)"
if [ -n "$DEV_ID" ]; then
  cp /bin/echo "$STUB/timestamped"
  if codesign --force --sign "$DEV_ID" --options runtime --timestamp \
       "$STUB/timestamped" >/dev/null 2>&1; then
    (assert_timestamped "$STUB/timestamped") >/dev/null 2>&1
    check "timestamp gate ACCEPTS a genuinely timestamped binary" "0" "$?"
    (assert_hardened_runtime "$STUB/timestamped") >/dev/null 2>&1
    check "hardened-runtime gate accepts a hardened binary" "0" "$?"
  else
    printf '  skip positive timestamp test (codesign --timestamp failed — offline?)\n'
  fi
else
  printf '  skip positive timestamp test (no Apple Development identity)\n'
fi

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
