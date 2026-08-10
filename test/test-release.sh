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

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
