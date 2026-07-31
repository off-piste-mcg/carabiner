# Menu-bar progress ring — design

**Date:** 2026-07-31
**Status:** approved, not yet implemented
**Applies to:** `Carabiner.app` (the app only — the Shortcut path is untouched by design)

## The problem

A grab posts "Grabbing…" and then says nothing until it finishes. In between there is
resolving the tab, sometimes a carousel probe, the download itself, and sometimes a
12-second re-encode. On a long reel that silence runs for ten seconds or more, and it is
indistinguishable from the failure mode gotcha #14 describes — a hotkey that was silently
stolen by something else. Gotcha #22 already made the *start* legible; this makes the
middle legible.

## What was ruled out, and why

**A progress bar inside the notification.** `UNUserNotificationCenter` has no progress API
on macOS — that is iOS Live Activities, which has no AppKit equivalent. The only way to
animate a banner is re-posting it on the same identifier every half-second with a text bar
in the body, which re-alerts on every update. Rejected: it turns one banner into a
flashing one, and gotcha #22 exists precisely because banner hygiene matters here.

**A coloured (OFF-PISTE blue) arc.** Would force `isTemplate = false` on the status item,
which today is what makes the mark adapt to light and dark menu bars for free
(`MenuBarController.swift:25`). The app would have to observe `effectiveAppearance` and
tint the mark itself, and menu-bar tinting/reduced-transparency is exactly where that goes
wrong. The arc is monochrome and the icon stays a template image.

**Real ffmpeg percentages.** Would need `-progress pipe:` plus duration extraction from
the existing probe. Deferred: gotcha #21 made the slow-encode path rare (most files remux
in ~0.2s), so it buys accuracy on a path that mostly does not run. The convert stage
creeps instead. Revisit only if a slow encode visibly stalls the arc in practice.

**Indeterminate-only spinner.** Cheapest option — no script changes at all — but it never
answers "how far", which was the ask.

## Geometry (settled on a real menu bar, 2026-07-31)

A throwaway prototype was run on the actual menu bar and the numbers were chosen by eye,
not derived:

| | value |
|---|---|
| composite image | 22 × 22 pt |
| mark height while busy | 10 pt (from 16 pt at rest) |
| stroke | 1.5 pt |
| track opacity | 12% |
| arc | starts at 12 o'clock, sweeps clockwise, round cap |

A true circle does not fit around the mark at its resting size — the mark is 20.5 × 16 pt,
so a ring around it lands near 25 pt diameter in a 22–24 pt bar. The mark therefore shrinks
to 10 pt for the duration of a grab and returns to 16 pt after. This is a visible pop at
the start and end of every grab; it was judged acceptable in the prototype and is the
reason the prototype existed.

Alpha is the only channel template rendering uses, so the 12% track survives tinting and
the whole composite still adapts to light/dark bars with no appearance-handling code.

## Architecture

The script reports **what stage it is in and how far through that stage**. The app owns
**what that looks like**. The script has no concept of arcs, circles or an overall
percentage; the app has no concept of yt-dlp.

### The wire protocol

Emitted on **stderr**, always on — no env-var gate.

```
::progress:probe                 # ig_item_count is running
::progress:prompt                # carousel dialog is up — waiting on the human
::progress:download:42.3         # percent known (yt-dlp)
::progress:download              # no percent available (gallery-dl) → creep
::progress:item:2:5              # item 2 of 5; subdivides the download+convert range
::progress:convert:encode        # or :remux — sets the creep rate
::progress:save
```

stderr rather than stdout because stdout is the `✓ <filename>` channel that both
`GrabRunner` and the Shortcut parse; nothing may be added to it. Always-on rather than
gated because a terminal run currently shows nothing during a download either, and this
improves it for free — the tools' own output is swallowed into `log="$(…)"` today.

### Arc bands (app-side policy)

| stage | band | driven by |
|---|---|---|
| resolve | 0 → 5% | Swift; the AppleScript tab read happens before the process launches |
| probe | 5 → 12% | creep |
| prompt | **frozen** | held at entry value — the block is the user, not the machine |
| download | 12 → 75% | yt-dlp's percentage, linear; gallery-dl creeps |
| convert | 75 → 96% | creep, rate from `:encode` vs `:remux` |
| save | 96 → 100% | — |

**Creep** is `lo + (hi - lo) * (1 - exp(-elapsed / tau))`: it approaches its band's ceiling
and never reaches it, so an unknown-length stage always looks alive but never claims to be
finished. Time constants: 0.9s for probe, 1.6s for convert, 0.7s otherwise.

The displayed value is smoothed toward its target and **is clamped to be non-decreasing** —
a retreating arc reads as an error.

When `::progress:item:i:n` has been seen, the 12 → 96% range is divided into `n` equal
slices and the download/convert bands apply within the current slice.

### Ending

- **Success:** arc completes to a full circle, holds 0.5s so the completion is actually
  seen, then fades over 0.4s back to the resting icon.
- **Failure:** arc stops where it is and fades immediately. The `✗` banner carries the
  reason; the icon does not persist an error state.

### Timer

30fps, running **only while a grab is in flight**. An idle menu-bar app must not schedule
wakeups.

## Components

| file | change |
|---|---|
| `carabiner` | `progress()` helper; markers in `ig_video`, `ig_gallery`, `plan_reencode`, the probe and the prompt |
| `app/Carabiner/GrabRunner.swift` | stream stderr line-by-line instead of `readDataToEndOfFile`; `onProgress` callback; filter `::progress:` lines out of the failure-reason extraction |
| `app/Carabiner/ProgressModel.swift` | **new** — pure functions: line → event, event → target arc value. All the band/creep policy lives here |
| `app/Carabiner/StatusIconRenderer.swift` | **new** — draws the composite template `NSImage` (shrunk mark + track + arc) |
| `app/Carabiner/MenuBarController.swift` | owns the timer, drives the renderer, complete/hold/fade |
| `app/CarabinerTests/ProgressModelTests.swift` | **new** |
| `app/CarabinerTests/GrabRunnerTests.swift` | extend |
| `test/test-progress.sh` | **new** — offline, stubbed binaries |

`ProgressModel` and `StatusIconRenderer` are pure and side-effect free: one maps text to a
number, the other maps a number to an image. Neither knows the other exists, and both are
testable without a menu bar or a network.

## The dangerous change

`ig_video:292` currently is:

```bash
log="$(yt-dlp "${args[@]}" "$url" 2>&1)"; rc=$?
```

and becomes:

```bash
log="$(PYTHONUNBUFFERED=1 yt-dlp "${args[@]}" "$url" 2>&1 \
       | tee >(grep --line-buffered '^::progress:' >&2))"; rc=$?
```

with `--newline --progress --progress-delta 0.2 --progress-template` added to `args` so
yt-dlp emits the marker format directly rather than being screen-scraped.

**`PYTHONUNBUFFERED=1` is load-bearing, not defensive.** Measured 2026-07-31: a Python
process writing to a *pipe* block-buffers its stdout, so without it every progress line
arrives in one burst when the process exits — 1.7s of output delivered at t=1.7s instead of
at 0.0/0.4/0.8/1.2s. The ring would freeze for the whole download and then snap to 100%,
which is precisely the symptom this feature exists to remove, and it would read as "the
creep is broken" rather than as a buffering problem. Both bundled tools are PyInstaller
CPython builds, so both need it.

**`rc=$?` is correct here and `PIPESTATUS` is not needed** — verified 2026-07-31. `set -uo
pipefail` at `carabiner:31` makes the pipeline return yt-dlp's non-zero status, and `grep`
sits in a *process substitution* rather than in the pipeline, so its exit status is not
part of it. That last point is what makes this safe: `grep` exits 1 when it matches
nothing, which is every image post, and if it were a genuine pipeline stage that 1 would
become the script's view of yt-dlp's exit code.

**This is still the change most likely to break something silently.** Gotcha #4's `return
10` fallback — "no video formats" meaning *this is an image, try gallery-dl* — is decided
from `rc` and `log`. Break either and image posts and carousels stop working, with no error
that points here. `pipefail` is now load-bearing for a second reason; removing it would
make a failed download look like a success.

Second trap, app-side: `GrabRunner.swift:79` takes the last stderr line as the failure
reason. Unfiltered, a failed grab would report `::progress:download:87.1` instead of what
gallery-dl actually said, destroying the diagnostics gotcha-driven work put there
deliberately (`ig_gallery:334-348`).

`ig_gallery` needs the same treatment, and additionally emits `::progress:item:i:n` from
its post-processing loop (`carabiner:352`), which is where a multi-video carousel spends
most of its time re-encoding.

## Verification

Per the project's standing rule, every assertion below is made to fail on purpose before
it is trusted.

**`test/test-progress.sh`** — offline, no network, stubbed yt-dlp/gallery-dl/ffmpeg
injected via `CARABINER_BIN` (the same mechanism `test-path.sh` already uses):

1. `::progress:` lines appear on stderr during a download.
2. **stdout is byte-identical to the pre-change script** for a successful grab.
3. A non-zero exit from yt-dlp still surfaces as a failure — i.e. `pipefail` is doing its
   job and `grep`'s no-match exit is not being read as the tool's.
4. A stubbed "No video formats found!" still produces `return 10` and the gallery-dl
   fallback still runs.
5. A stubbed tool failure still reports the tool's own last line as the reason, not a
   progress line.
6. **Progress arrives live, not in a burst at exit.** A stub that emits markers with
   delays between them must be observed to produce them with those delays intact. Without
   this assertion the buffering trap above is invisible to every other test in the file.

**`CarabinerTests`** — `ProgressModel` line parsing and band mapping (including: creep
never crosses its ceiling, the value never decreases, `prompt` freezes); `GrabRunner`
never returns a `::progress:` line as an error message.

**Manual, on a real grab:** a mixed video+image carousel (gotcha #15 — both posts on the
OFF-PISTE account qualify), watched on a light *and* a dark menu bar. Timestamps prove
nothing here (see the `ls -1 ~/Downloads | diff` procedure in CLAUDE.md).

**Reminder that has bitten this project before:** the running app executes the *bundled*
snapshot of `carabiner` from `Contents/Resources`, not the repo copy. A script change
requires `xcodegen generate` → `xcodebuild` → reinstall before any app-driven test means
anything.

## Out of scope

- Real ffmpeg percentages (see above).
- Any change to the Shortcut path or to the shell tool's own notifications.
- A coloured arc, and any error state that persists on the icon.
