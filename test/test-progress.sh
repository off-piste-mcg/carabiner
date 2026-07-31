#!/usr/bin/env bash
# Tests for carabiner's progress markers. No network, no downloads: the three tools are
# stubbed and injected via CARABINER_BIN, which the script puts first on PATH (gotcha #17)
# — so the stubs also shadow `osascript`, which is how the carousel dialog is faked.
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

contains() {  # $1 = label, $2 = needle, $3 = haystack
  case "$3" in
    *"$2"*) printf '  ok   %s\n' "$1"; pass=$((pass + 1)) ;;
    *)      printf '  FAIL %s\n       wanted to find: %s\n       in: %s\n' "$1" "$2" "$3"; fail=$((fail + 1)) ;;
  esac
}

lacks() {  # $1 = label, $2 = needle, $3 = haystack
  case "$3" in
    *"$2"*) printf '  FAIL %s\n       should NOT contain: %s\n       in: %s\n' "$1" "$2" "$3"; fail=$((fail + 1)) ;;
    *)      printf '  ok   %s\n' "$1"; pass=$((pass + 1)) ;;
  esac
}

BIN="$(mktemp -d)"; OUT="$(mktemp -d)"
trap 'rm -rf "$BIN" "$OUT"' EXIT

# --- stubs -----------------------------------------------------------------
# gallery-dl: `-g` lists slides (the carousel probe); otherwise it "downloads" into -D.
cat > "$BIN/gallery-dl" <<'STUB'
#!/usr/bin/env bash
dest=""; prev=""; listing=0
for a in "$@"; do
  [ "$prev" = "-D" ] && dest="$a"
  [ "$a" = "-g" ] && listing=1
  prev="$a"
done
if [ "$listing" -eq 1 ]; then
  echo "ytdl:https://www.instagram.com/p/CODE/1.mp4"
  echo "| https://scontent.example/continuation"
  echo "https://scontent.example/2.jpg"
  exit 0
fi
: > "$dest/01.mp4"; : > "$dest/02.jpg"
exit 0
STUB

# yt-dlp: writes the file named by -o. Task 6 replaces this with a progress-emitting one.
cat > "$BIN/yt-dlp" <<'STUB'
#!/usr/bin/env bash
out=""; prev=""
for a in "$@"; do [ "$prev" = "-o" ] && out="$a"; prev="$a"; done
: > "${out/\%(ext)s/mp4}"
exit 0
STUB

# ffmpeg: the probe form prints a stream table on stderr and exits non-zero (which is how
# the real one behaves when given no output file); the encode form writes the output.
cat > "$BIN/ffmpeg" <<'STUB'
#!/usr/bin/env bash
case " $* " in
  *" -hide_banner "*)
    echo "    Stream #0:0: Video: h264 (High), ${CARABINER_TEST_PIXFMT:-yuv420p}, 1080x1920" >&2
    echo "    Stream #0:1: Audio: aac (LC), 44100 Hz" >&2
    exit 1 ;;
esac
out="${@: -1}"; : > "$out"
exit 0
STUB

# osascript: stands in for the carousel dialog. Answer comes from the environment.
cat > "$BIN/osascript" <<'STUB'
#!/usr/bin/env bash
echo "${CARABINER_TEST_DIALOG:-This slide}"
exit 0
STUB

chmod +x "$BIN"/*

run() {  # runs carabiner headless; stdout on fd1, stderr on fd2, both captured by caller
  CARABINER_BIN="$BIN" CARABINER_NO_NOTIFY=1 \
    "$SCRIPT" -o "$OUT" "$@" < /dev/null
}

echo "test-progress.sh"

# 1. The carousel probe announces itself, and the prompt does too.
err="$(run 'https://www.instagram.com/p/ABC123/' 2>&1 >/dev/null)"
contains "probe marker emitted"  "::progress:probe"  "$err"
contains "prompt marker emitted" "::progress:prompt" "$err"

# 2. Markers never appear on stdout — that is the ✓ channel GrabRunner and the Shortcut
#    parse, and anything added to it is a change in their input.
out="$(run 'https://www.instagram.com/p/ABC123/' 2>/dev/null)"
lacks "stdout carries no markers" "::progress:" "$out"
contains "stdout still announces the save" "✓ " "$out"

# 3. A QuickTime-safe file remuxes; an odd pixel format re-encodes. The ring creeps at a
#    different rate for each, so the distinction has to reach the app.
err="$(run 'https://www.instagram.com/reel/ABC123/' 2>&1 >/dev/null)"
contains "remux announced" "::progress:convert:remux" "$err"

err="$(CARABINER_TEST_PIXFMT=yuv420p10le run 'https://www.instagram.com/reel/ABC123/' 2>&1 >/dev/null)"
contains "encode announced" "::progress:convert:encode" "$err"

# 4. A whole-carousel grab counts its items, so the ring advances per slide instead of
#    snapping to the end on the first file.
err="$(CARABINER_TEST_DIALOG="All 2" run 'https://www.instagram.com/p/ABC123/' 2>&1 >/dev/null)"
contains "first item announced"  "::progress:item:1:2" "$err"
contains "second item announced" "::progress:item:2:2" "$err"

# 5. The save marker closes the run.
err="$(run 'https://www.instagram.com/reel/ABC123/' 2>&1 >/dev/null)"
contains "save marker emitted" "::progress:save" "$err"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
