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

# 4. With CARABINER_BIN unset, the resulting PATH must be byte-for-byte identical to
#    the pre-change script's PATH — the Shortcut/terminal path is not allowed to change
#    behaviour at all. Build the same prologue slice from the pre-change script
#    (git HEAD, before this fix) and diff the two PATH strings.
OLD_SCRIPT="$BUNDLED/.carabiner.old"
if git -C "$HERE/.." show HEAD:carabiner > "$OLD_SCRIPT" 2>/dev/null; then
  OLD_PROLOGUE="$BUNDLED/.prologue.old.sh"
  sed -n '1,/^BROWSER=/p' "$OLD_SCRIPT" | sed '$d' > "$OLD_PROLOGUE"

  old_path="$(unset CARABINER_BIN; bash -c 'source "$1" >/dev/null 2>&1; printf "%s" "$PATH"' _ "$OLD_PROLOGUE")"
  new_path="$(unset CARABINER_BIN; show_path)"
  check "unset CARABINER_BIN: PATH identical to pre-change script" "$old_path" "$new_path"
else
  printf '  FAIL %s\n       could not read HEAD:carabiner\n' "unset CARABINER_BIN: PATH identical to pre-change script"
  fail=$((fail + 1))
fi

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
