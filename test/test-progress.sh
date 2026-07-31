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

# yt-dlp: a *Python* process writing progress to stdout, which is what the real one is.
# The language matters: CPython block-buffers stdout when it is a pipe, so this stub
# reproduces the buffering trap rather than papering over it.
cat > "$BIN/yt-dlp" <<'STUB'
#!/usr/bin/env bash
out=""; prev=""
for a in "$@"; do [ "$prev" = "-o" ] && out="$a"; prev="$a"; done
if [ -n "${CARABINER_TEST_NOVIDEO:-}" ]; then
  echo "ERROR: No video formats found!" >&2
  exit 1
fi
if [ -n "${CARABINER_TEST_FAIL:-}" ]; then
  # Leaves a file behind *and* exits non-zero, which is what an interrupted download or a
  # failed merge/post-process does — `ls "${tmp}".*` matches the partial too. The exit
  # status is therefore the only reliable signal, and check 9 below is only load-bearing
  # because of this line: with no file, ig_video's "no source file" guard catches the
  # failure on its own and check 9 passes even with the exit status thrown away.
  echo "ERROR: login required" >&2
  : > "${out/\%(ext)s/mp4}"
  exit 1
fi
python3 -c '
import sys, time
for p in ("  0.0%", " 50.0%", "100.0%"):
    sys.stdout.write("::progress:download:%s\n" % p)
    time.sleep(0.3)
'
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
# gallery-dl reports nothing while it runs, so ig_gallery announces the stage itself. This
# is the only check that reaches that line at all — check 2 takes the default dialog answer
# and routes to ig_video, so without this assertion the marker could be deleted outright
# and the suite would stay green.
contains "gallery download announced" "::progress:download" "$err"

# 5. The save marker closes the run.
err="$(run 'https://www.instagram.com/reel/ABC123/' 2>&1 >/dev/null)"
contains "save marker emitted" "::progress:save" "$err"

# 6. Percentages reach stderr, and not stdout.
err="$(run 'https://www.instagram.com/reel/ABC123/' 2>&1 >/dev/null)"
contains "download percent emitted" "::progress:download: 50.0%" "$err"
out="$(run 'https://www.instagram.com/reel/ABC123/' 2>/dev/null)"
lacks "stdout still carries no markers" "::progress:" "$out"

# 7. Progress must arrive LIVE. Without PYTHONUNBUFFERED=1 a Python process writing to a
#    pipe block-buffers, so every marker lands in one burst when it exits — the ring would
#    freeze for the whole download and then snap to full, which is the exact symptom this
#    feature exists to remove. Measured 2026-07-31: 1.7s of output delivered at t=1.7s.
#    The stub sleeps 0.3s between three markers, so live delivery spans >= ~0.6s.
#    The threshold lives in one variable and is interpolated into both the comparison and
#    the failure label — hardcoding the label separately makes a raised threshold print a
#    message that lies about what was wanted.
live_ms=400
first=""; last=""
while IFS= read -r line; do
  case "$line" in
    ::progress:download:*)
      now="$(python3 -c 'import time; print(int(time.time()*1000))')"
      [ -z "$first" ] && first="$now"
      last="$now" ;;
  esac
done < <(run 'https://www.instagram.com/reel/ABC123/' 2>&1 >/dev/null)
if [ -n "$first" ] && [ -n "$last" ] && [ "$((last - first))" -ge "$live_ms" ]; then
  check "progress arrives live, not buffered to the end" "live" "live"
else
  check "progress arrives live, not buffered to the end" "spread >= ${live_ms}ms" "spread $((last - first))ms"
fi

# 8. Gotcha #4's fallback still works: "No video formats found!" means this is an image
#    post, and the caller must fall through to gallery-dl. Breaking this breaks every
#    image post, with no error that points at the pipeline change that caused it.
out="$(CARABINER_TEST_NOVIDEO=1 run 'https://www.instagram.com/p/ABC123/' 2>/dev/null)"
contains "no-video falls back to gallery-dl" "✓ " "$out"

# 9. A genuine yt-dlp failure must still fail. pipefail is what carries the exit status
#    out of the tee pipeline; without it a failed download would look like a success.
out="$(CARABINER_TEST_FAIL=1 run 'https://www.instagram.com/reel/ABC123/' 2>/dev/null)"; rc=$?
check "a failing download exits non-zero" "nonzero" "$([ "$rc" -ne 0 ] && echo nonzero || echo "zero")"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
