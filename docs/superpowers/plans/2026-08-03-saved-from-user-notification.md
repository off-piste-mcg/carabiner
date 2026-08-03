# "Saved from @user" Outcome Notification Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** The app's success banner names the Instagram account a grab came from — `✓ Saved from @wissevellinga` — falling back to today's `✓ Saved` whenever the handle isn't known.

**Architecture:** The engine (bash `carabiner`) asks the tools it already runs for metadata sidecars (gallery-dl `--write-metadata`, yt-dlp `--write-info-json`), parses the handle out with `grep`, and emits one `::progress:from:@handle` marker on **stderr**. The app (`GrabRunner`) captures it into `GrabResult.user`, and `Notifier` composes the subtitle. stdout — the Shortcut's channel — is byte-for-byte unchanged.

**Tech Stack:** bash (the `carabiner` script), Swift/AppKit (`app/`), offline shell tests (`test/test-progress.sh`), XCTest.

**Spec:** `docs/superpowers/specs/2026-08-03-saved-from-user-notification-design.md`

## Global Constraints

- **Instagram only.** YouTube / Pinterest / generic branches are not touched.
- **No new dependencies in the script** — no `python3`, no `jq`. Parsing is `grep`/`sed`/`head` only (CLAUDE.md convention: dependency-light).
- **No extra network calls** (gotcha #21). The sidecars come from tool invocations that already happen.
- **stdout is untouched.** The marker goes to stderr via the existing `progress()` helper. `test/test-progress.sh` check 2 enforces this; do not weaken it.
- **The handle is decoration, never a dependency.** Missing/unparseable sidecar → no marker, grab proceeds exactly as today, banner says `✓ Saved`.
- **The marker carries the `@`:** `::progress:from:@wissevellinga`. The app displays it verbatim.
- **Failure banner is unchanged:** `✗ Grab failed`, even if the handle was captured.
- **Every stub must model the real tool faithfully** (gotcha #23/#24 lesson) — sidecar names, JSON shape, and the decoy numeric `uploader_id` all come from Task 1's real-post observation, not from guesses.
- Build commands, signing, and install steps are exactly CLAUDE.md's ("Working on this project" section). The running app executes a **bundled snapshot** of the script — rebuild + reinstall before trusting any app-driven test of a script change.

---

### Task 1: Verify the metadata fields against a real post

The whole design hangs on two facts that must be observed, not assumed (gotcha #7: yt-dlp's `uploader_id` is a numeric trap):

1. Which yt-dlp info-json field carries the IG **handle** (candidates: `channel`, `uploader`).
2. The exact sidecar filenames and JSON shape both tools write.

**Files:** none modified — this task produces the two facts and records them in this plan file.

**Interfaces:**
- Produces: `IG_HANDLE_FIELD` — the verified yt-dlp field name. Every later task written as `channel` must be corrected to the verified name if it differs. Also produces: real sidecar naming + shape for the Task 2 stubs.

- [ ] **Step 1: Get a real Instagram URL**

Any real post works. Use one from the OFF-PISTE account (both its posts are mixed carousels — the proven regression case from gotcha #15), plus any reel for the video path. If no URL is at hand, ask Wisse or read the front browser tab.

- [ ] **Step 2: Inspect yt-dlp's fields on a reel**

```bash
yt-dlp --cookies-from-browser chrome -j 'https://www.instagram.com/reel/REAL/' \
  | tr ',' '\n' | grep -E '"(uploader|uploader_id|channel)"'
```

Expected: one of the fields holds the `@`-less handle (e.g. `"channel": "offpiste.mcg"`), and `uploader_id` is likely numeric. Record the winner as `IG_HANDLE_FIELD` here:

> **IG_HANDLE_FIELD = channel** ← placeholder assumption; overwrite with the observed value and note the date.

- [ ] **Step 3: Observe both tools' real sidecars**

```bash
d="$(mktemp -d)"
yt-dlp --cookies-from-browser chrome -o "$d/src.%(ext)s" --write-info-json \
  --no-write-playlist-metafiles 'https://www.instagram.com/reel/REAL/'
ls "$d"                      # expect: src.info.json + src.mp4 — confirm the .info.json name
head -c 400 "$d/src.info.json"; echo   # confirm compact one-line JSON, "FIELD": "handle" with a space after the colon

d2="$(mktemp -d)"
gallery-dl --cookies-from-browser chrome -D "$d2" --range 1 --write-metadata \
  'https://www.instagram.com/p/REAL/'
ls "$d2"                     # expect: <file> + <file>.json — confirm the sidecar is <filename>.json
grep -o '"username": *"[^"]*"' "$d2"/*.json   # confirm the key and its pretty-printed form
rm -rf "$d" "$d2"
```

Record here what was actually observed (sidecar names, whether `": "` has a space, the username key). The Task 2 stubs must copy this shape.

- [ ] **Step 4: No commit** — this task changes only this plan file (the recorded facts). Commit the annotated plan:

```bash
git add docs/superpowers/plans/2026-08-03-saved-from-user-notification.md
git commit -m "docs(plan): record verified IG metadata fields for the from-marker"
```

---

### Task 2: The engine emits `::progress:from:@handle` (offline TDD via test-progress.sh)

**Files:**
- Modify: `carabiner` — `ig_video()` (~lines 309–377), `ig_gallery()` (~lines 384–438), plus one new helper near `lower()` (~line 302)
- Test: `test/test-progress.sh` — extend the `gallery-dl` and `yt-dlp` stubs, add check 11

**Interfaces:**
- Consumes: `IG_HANDLE_FIELD` from Task 1 (written as `channel` below — substitute if Task 1 said otherwise).
- Produces: at most one stderr line per grab of the exact form `::progress:from:@<handle>`, `<handle>` matching `[A-Za-z0-9._]+`, emitted only on the Instagram paths and only when the sidecar yielded a handle. Task 3's Swift parser depends on this exact format.

- [ ] **Step 1: Teach the stubs the sidecars (faithfully — gotcha #23)**

In `test/test-progress.sh`, replace the `gallery-dl` stub with this (adds `--write-metadata` handling; everything else unchanged):

```bash
# gallery-dl: `-g` lists slides (the carousel probe); otherwise it "downloads" into -D.
# With --write-metadata the real tool drops a pretty-printed `<file>.json` beside every
# file, containing "username" — the stub models that (shape observed in Task 1), plus a
# CARABINER_TEST_NOMETA switch standing in for a post/tool that yields no metadata.
cat > "$BIN/gallery-dl" <<'STUB'
#!/usr/bin/env bash
dest=""; prev=""; listing=0; meta=0
for a in "$@"; do
  [ "$prev" = "-D" ] && dest="$a"
  [ "$a" = "-g" ] && listing=1
  [ "$a" = "--write-metadata" ] && meta=1
  prev="$a"
done
if [ "$listing" -eq 1 ]; then
  echo "ytdl:https://www.instagram.com/p/CODE/1.mp4"
  echo "| https://scontent.example/continuation"
  echo "https://scontent.example/2.jpg"
  exit 0
fi
: > "$dest/01.mp4"; : > "$dest/02.jpg"
if [ "$meta" -eq 1 ] && [ -z "${CARABINER_TEST_NOMETA:-}" ]; then
  for f in 01.mp4 02.jpg; do
    printf '{\n    "username": "stubuser",\n    "shortcode": "CODE"\n}\n' > "$dest/$f.json"
  done
fi
exit 0
STUB
```

In the `yt-dlp` stub, add `infojson` flag parsing to the existing argv loop:

```bash
out=""; prev=""; newline=0; infojson=0
for a in "$@"; do
  [ "$prev" = "-o" ] && out="$a"
  [ "$a" = "--newline" ] && newline=1
  [ "$a" = "--write-info-json" ] && infojson=1
  prev="$a"
done
```

…and just before the stub's final `: > "${out/\%(ext)s/mp4}"`, write the sidecar the way the real tool does — compact one-line JSON, with the numeric `uploader_id` decoy in place so parsing the wrong field fails loudly (copy the exact shape observed in Task 1):

```bash
if [ "$infojson" -eq 1 ] && [ -z "${CARABINER_TEST_NOMETA:-}" ]; then
  printf '{"id": "ABC123", "channel": "stubuser", "uploader_id": "17841400000000000", "title": "clip"}' \
    > "${out/\%(ext)s/info.json}"
fi
```

- [ ] **Step 2: Add check 11 (after check 10)**

```bash
# 11. The engine names the account. Both Instagram paths read the tool's metadata sidecar
#     and emit exactly one ::progress:from:@handle marker on stderr — and a post that
#     yields no metadata degrades to no marker, never to a failure. stdout stays clean
#     (check 2 already pins that for all markers).
err="$(run 'https://www.instagram.com/reel/ABC123/' 2>&1 >/dev/null)"
contains "video path names the account" "::progress:from:@stubuser" "$err"

err="$(CARABINER_TEST_DIALOG="All 2" run 'https://www.instagram.com/p/ABC123/' 2>&1 >/dev/null)"
contains "gallery path names the account" "::progress:from:@stubuser" "$err"
n="$(printf '%s\n' "$err" | grep -c '^::progress:from:' | tr -d ' ')"
check "exactly one from marker per grab" "1" "$n"

out="$(CARABINER_TEST_NOMETA=1 run 'https://www.instagram.com/reel/ABC123/' 2>/dev/null)"
contains "no sidecar still saves" "✓ " "$out"
err="$(CARABINER_TEST_NOMETA=1 run 'https://www.instagram.com/reel/ABC123/' 2>&1 >/dev/null)"
lacks "no sidecar emits no from marker" "::progress:from" "$err"
```

- [ ] **Step 3: Run the suite — the three new positive checks must FAIL**

Run: `./test/test-progress.sh`
Expected: checks 1–10 still pass; "video path names the account", "gallery path names the account" FAIL; "exactly one from marker per grab" FAILs (0, not 1); the two NOMETA checks pass vacuously. If anything in 1–10 broke, the stub edit is wrong — fix before proceeding.

- [ ] **Step 4: Implement in `carabiner`**

Add the helper directly below `lower()` (~line 302):

```bash
# Pull a string field out of a tool's JSON sidecar without a JSON parser. First match
# wins, and the pattern cannot hit inside a longer string value: an embedded quote
# there is escaped (\"), so the bytes `"key": "` never occur mid-string. The value
# charset is exactly an IG username's, which doubles as sanitisation — a weird value
# simply doesn't match, and no marker is emitted (the handle is decoration, never a
# dependency).
json_field() {  # $1 = key, $2 = file → prints the bare value, or nothing
  grep -oE "\"$1\": ?\"[A-Za-z0-9._]+\"" "$2" 2>/dev/null \
    | head -n1 | sed -E 's/^.*: ?"//; s/"$//'
}
```

In `ig_video()`, make three edits:

1. Extend the args (line ~312) so yt-dlp writes the sidecar — `--no-write-playlist-metafiles` because with `--playlist-items` the playlist-level metafile would land under the same `${tmp}` prefix:

```bash
  local -a args=(--cookies-from-browser "$BROWSER" -o "${tmp}.%(ext)s"
                 --write-info-json --no-write-playlist-metafiles)
```

2. Tighten the src pickup (line ~361) — this is the rolled-in fix for the latent `head -n1` issue flagged in gotcha #23; without it `.info.json` sorts before `.mp4` and wins:

```bash
  local src
  src="$(ls "${tmp}".* 2>/dev/null | grep -v '\.json$' | head -n1)"
```

3. Emit the marker right after the src guard (`[ -n "$src" ] || …`), substituting Task 1's field for `channel` if it differs:

```bash
  local user
  user="$(json_field channel "${tmp}.info.json")"
  [ -n "$user" ] && progress "from:@${user}"
```

(The existing `rm -f "${tmp}".*` cleanups on both the success and failure paths already delete the sidecar; the failure path returns before the emit, so a failed grab never names an account.)

In `ig_gallery()`, two edits:

1. Add the flag to the args (line ~387):

```bash
  local -a args=(--cookies-from-browser "$BROWSER" -D "$tmp" -q --write-metadata)
```

2. Emit after the download succeeds — insert between the `die "gallery-dl failed…"` block and the `local n=0 i=0 …` line. Any one sidecar will do (all slides of a post share the account):

```bash
  local meta user
  meta="$(find "$tmp" -type f -name '*.json' | head -n1)"
  if [ -n "$meta" ]; then
    user="$(json_field username "$meta")"
    [ -n "$user" ] && progress "from:@${user}"
  fi
```

(The file loop and the `total` count already exclude `*.json` — that exclusion is now load-bearing, which check 4's `item:1:2`/`item:2:2` assertions pin: sidecars present, total still 2.)

- [ ] **Step 5: Verify**

Run: `bash -n carabiner && ./test/test-progress.sh && ./test/test-path.sh`
Expected: syntax clean, all checks pass including the five new ones, PATH tests untouched.

- [ ] **Step 6: Commit**

```bash
git add carabiner test/test-progress.sh
git commit -m "feat: engine emits ::progress:from:@handle from tool metadata sidecars"
```

---

### Task 3: The app captures the handle — `ProgressParser.parseUser` + `GrabRunner`

**Files:**
- Modify: `app/Carabiner/ProgressModel.swift` (the `ProgressParser` enum, ~line 38)
- Modify: `app/Carabiner/GrabRunner.swift` (`GrabResult` ~line 3, the stderr loop ~lines 81–95, the success returns ~lines 127–128)
- Test: `app/CarabinerTests/ProgressEventTests.swift`, `app/CarabinerTests/GrabRunnerTests.swift`

**Interfaces:**
- Consumes: the Task 2 marker format `::progress:from:@<handle>` on stderr.
- Produces: `ProgressParser.parseUser(_ rawLine: String) -> String?` (returns `"@handle"` verbatim, nil otherwise) and `GrabResult.user: String?` (nil when no marker arrived). Task 4 reads `GrabResult.user`.

- [ ] **Step 1: Write the failing tests**

Append to `ProgressEventTests.swift`:

```swift
    // MARK: - the `from` metadata marker

    /// `from` is metadata, not a stage: parse() must NOT turn it into an event, or the
    /// ring machinery grows an ignore-branch for a line that has nothing to do with it.
    func testFromLineIsNotAProgressEvent() {
        XCTAssertNil(ProgressParser.parse("::progress:from:@offpiste.mcg"))
    }

    func testParseUserReadsTheHandleVerbatim() {
        XCTAssertEqual(ProgressParser.parseUser("::progress:from:@offpiste.mcg"), "@offpiste.mcg")
    }

    func testParseUserTrimsWhitespace() {
        XCTAssertEqual(ProgressParser.parseUser("  ::progress:from:@wisse \n"), "@wisse")
    }

    func testParseUserIgnoresOtherMarkersAndNoise() {
        XCTAssertNil(ProgressParser.parseUser("::progress:download: 50.0%"))
        XCTAssertNil(ProgressParser.parseUser("plain log line"))
        XCTAssertNil(ProgressParser.parseUser("::progress:from:"))   // empty handle is no handle
    }
```

Append to `GrabRunnerTests.swift`:

```swift
    /// The `from` marker rides stderr like every other marker, but lands in the result —
    /// not in onProgress — because it describes the grab, not a stage of it.
    func testFromMarkerIsCapturedAsUser() {
        let stub = writeStub("""
        echo '::progress:from:@offpiste.mcg' 1>&2
        echo '  ✓ ABC_fixed.mp4'
        exit 0
        """)
        let result = GrabRunner(executable: stub).run(url: "https://x/y")
        XCTAssertTrue(result.ok)
        XCTAssertEqual(result.user, "@offpiste.mcg")
    }

    func testNoFromMarkerMeansNilUser() {
        let stub = writeStub("echo '  ✓ ABC_fixed.mp4'; exit 0")
        XCTAssertNil(GrabRunner(executable: stub).run(url: "https://x/y").user)
    }

    /// The marker filter that keeps progress lines out of failure messages must keep
    /// covering `from` lines — a failed grab should banner the tool's complaint, not
    /// the account it would have come from.
    func testFromLineIsNeverTheFailureReason() {
        let stub = writeStub("""
        echo '✗ login required' 1>&2
        echo '::progress:from:@offpiste.mcg' 1>&2
        exit 1
        """)
        XCTAssertEqual(GrabRunner(executable: stub).run(url: "https://x/y").message, "login required")
    }
```

- [ ] **Step 2: Run the tests to verify they fail**

```bash
cd app && xcodegen generate && \
xcodebuild -project Carabiner.xcodeproj -scheme Carabiner -destination 'platform=macOS' test
```

Expected: compile error — `parseUser` and `user` don't exist yet. (Export `CARABINER_TEAM_ID` first, per CLAUDE.md.)

- [ ] **Step 3: Implement**

In `ProgressModel.swift`, add inside `enum ProgressParser` (below `parse`):

```swift
    /// The one marker that is metadata rather than a stage: `::progress:from:@handle`,
    /// naming the account a grab came from. Kept out of `ProgressEvent` on purpose —
    /// an event case would force the ring machinery (`ProgressModel.apply`,
    /// `BannerPlanner.handle`, `beginsActivity`) to each ignore it explicitly.
    static func parseUser(_ rawLine: String) -> String? {
        let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
        let prefix = marker + "from:"
        guard line.hasPrefix(prefix) else { return nil }
        let handle = String(line.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
        return handle.isEmpty ? nil : handle
    }
```

In `GrabRunner.swift`:

1. Add the field to `GrabResult`:

```swift
struct GrabResult {
    let ok: Bool
    let message: String
    /// The user dismissed the carousel dialog. Not a failure to report — the only correct
    /// banner response is silence.
    var cancelled: Bool = false
    /// `@handle` of the Instagram account the grab came from, when the engine reported
    /// one (`::progress:from:` marker). Decoration for the banner — nil is normal.
    var user: String? = nil
}
```

2. In `run()`, declare `var user: String?` next to `outData`/`errData` (~line 74), and extend the stderr loop (~lines 88–94) — same captured-variable pattern as `errData`, ordered by `group.wait()`:

```swift
            for line in buffer.append(chunk) {
                if let event = ProgressParser.parse(line) { self.onProgress?(event) }
                if let u = ProgressParser.parseUser(line) { user = u }
            }
```

and the flush tail:

```swift
            if let last = buffer.flush() {
                if let event = ProgressParser.parse(last) { self.onProgress?(event) }
                if let u = ProgressParser.parseUser(last) { user = u }
            }
```

3. Thread it into the success returns (~lines 127–128) — failures keep `user` nil by simply not passing it:

```swift
        if saved.count == 1 { return GrabResult(ok: true, message: saved[0], user: user) }
        return GrabResult(ok: true, message: "\(saved.count) files", user: user)
```

- [ ] **Step 4: Run the tests to verify they pass**

Same command as Step 2. Expected: all green, including every pre-existing test.

- [ ] **Step 5: Commit**

```bash
git add app/Carabiner/ProgressModel.swift app/Carabiner/GrabRunner.swift \
        app/CarabinerTests/ProgressEventTests.swift app/CarabinerTests/GrabRunnerTests.swift
git commit -m "feat(app): capture the ::progress:from: handle into GrabResult.user"
```

---

### Task 4: The banner says "✓ Saved from @user"

**Files:**
- Modify: `app/Carabiner/BannerPlanner.swift` (the `BannerAction` enum ~line 12, `finished` ~line 57)
- Modify: `app/Carabiner/Notifier.swift` (the `.postOutcome` case ~lines 44–63)
- Test: `app/CarabinerTests/BannerPlannerTests.swift`

**Interfaces:**
- Consumes: `GrabResult.user` from Task 3.
- Produces: `BannerAction.postOutcome(ok: Bool, message: String, user: String?)` and `Notifier.outcomeSubtitle(ok: Bool, user: String?) -> String` — the pure, testable subtitle policy.

- [ ] **Step 1: Write the failing tests**

In `BannerPlannerTests.swift`, update the two existing outcome assertions to the new case shape:

```swift
        XCTAssertEqual(planner.finished(GrabResult(ok: true, message: "ABC_fixed.mp4")),
                       [.postOutcome(ok: true, message: "ABC_fixed.mp4", user: nil)])
```

```swift
        XCTAssertEqual(planner.finished(GrabResult(ok: false, message: "cookies expired")),
                       [.postOutcome(ok: false, message: "cookies expired", user: nil)])
```

…and append:

```swift
    /// The handle rides the outcome — the planner passes it through untouched so the
    /// subtitle policy stays in one place (Notifier.outcomeSubtitle).
    func testSuccessCarriesTheHandleThrough() {
        var planner = BannerPlanner()
        _ = planner.grabStarted()
        XCTAssertEqual(planner.finished(GrabResult(ok: true, message: "9 files", user: "@offpiste.mcg")),
                       [.postOutcome(ok: true, message: "9 files", user: "@offpiste.mcg")])
    }

    // MARK: - subtitle policy (pure, so it is testable outside a signed bundle)

    func testSubtitleNamesTheAccountOnSuccess() {
        XCTAssertEqual(Notifier.outcomeSubtitle(ok: true, user: "@offpiste.mcg"),
                       "✓ Saved from @offpiste.mcg")
    }

    func testSubtitleFallsBackWhenHandleUnknown() {
        XCTAssertEqual(Notifier.outcomeSubtitle(ok: true, user: nil), "✓ Saved")
    }

    /// A failure never names the account, even when the engine reported one before dying.
    func testFailureSubtitleIgnoresTheHandle() {
        XCTAssertEqual(Notifier.outcomeSubtitle(ok: false, user: "@offpiste.mcg"), "✗ Grab failed")
    }
```

- [ ] **Step 2: Run the tests to verify they fail**

```bash
cd app && xcodebuild -project Carabiner.xcodeproj -scheme Carabiner -destination 'platform=macOS' test
```

Expected: compile error — `postOutcome` has no `user` label, `outcomeSubtitle` doesn't exist.

- [ ] **Step 3: Implement**

In `BannerPlanner.swift`:

```swift
    /// Post the grab's outcome as a fresh banner.
    case postOutcome(ok: Bool, message: String, user: String?)
```

```swift
        return [.postOutcome(ok: result.ok, message: result.message, user: result.user)]
```

In `Notifier.swift`, change the case and pull the subtitle into a pure static (the comment on the old inline ternary moves with it):

```swift
            case .postOutcome(let ok, let message, let user):
                let content = UNMutableNotificationContent()
                content.title = "Carabiner"
                // Subtitle carries the verdict, body the detail the script actually
                // reported (a filename, a directory, a reason) — never each other's text.
                content.subtitle = Self.outcomeSubtitle(ok: ok, user: user)
                content.body = message
```

…and below `execute`:

```swift
    /// The verdict line. Static and pure so the one piece of banner *copy* with logic in
    /// it is testable — UNUserNotificationCenter itself only works in a signed,
    /// LaunchServices-launched bundle. A failure never names the account: "Grab failed
    /// from @x" reads as blame, and the message line already says what went wrong.
    static func outcomeSubtitle(ok: Bool, user: String?) -> String {
        guard ok else { return "✗ Grab failed" }
        if let user { return "✓ Saved from \(user)" }
        return "✓ Saved"
    }
```

(Everything else in the `.postOutcome` arm — fresh UUID, stale-banner removals, `lastOutcomeId` — stays exactly as it is; gotcha #22 is not being relitigated.)

- [ ] **Step 4: Run the tests to verify they pass**

Same command. Expected: all green.

- [ ] **Step 5: Commit**

```bash
git add app/Carabiner/BannerPlanner.swift app/Carabiner/Notifier.swift \
        app/CarabinerTests/BannerPlannerTests.swift
git commit -m "feat(app): success banner reads 'Saved from @user' when the handle is known"
```

---

### Task 5: End-to-end verification and docs

**Files:**
- Modify: `CLAUDE.md` (the **Progress** bullet in "Current state — BUILT")

**Interfaces:**
- Consumes: everything above, plus a real Instagram post.

- [ ] **Step 1: Verify the engine half directly, with real data**

```bash
ls -1 ~/Downloads > /tmp/before.txt
CARABINER_NO_NOTIFY=1 ./carabiner 'https://www.instagram.com/reel/REAL/' 2>/tmp/err.txt
grep '^::progress:from:' /tmp/err.txt          # expect exactly: ::progress:from:@<real handle>
ls -1 ~/Downloads | diff /tmp/before.txt - | grep '^>'   # filename diff, NOT timestamps (CLAUDE.md)
```

Repeat with a carousel URL (`/p/…`, answer the dialog) and confirm the marker names the same account.

- [ ] **Step 2: Rebuild, reinstall, and verify the banner in the real app**

The installed app runs a bundled snapshot of the script — the rebuild is mandatory, not hygiene:

```bash
export CARABINER_TEAM_ID=$(security find-certificate -a -c "Apple Development" -p \
  | openssl x509 -noout -subject | tr ',/' '\n\n' \
  | sed -nE 's/.*OU=([A-Z0-9]{10}).*/\1/p' | head -1)
./scripts/fetch-deps.sh
cd app && xcodegen generate && \
xcodebuild -project Carabiner.xcodeproj -scheme Carabiner -configuration Debug \
  -derivedDataPath build build
pkill -x Carabiner; rm -rf ~/Applications/Carabiner.app
cp -R build/Build/Products/Debug/Carabiner.app ~/Applications/ && open ~/Applications/Carabiner.app
```

Open a real post, fire ⌃⌥⌘V, and confirm with Wisse that the banner reads `✓ Saved from @<handle>` with the filename / "N files" underneath. Also grab one YouTube/Pinterest URL and confirm its banner still says plain `✓ Saved` (the fallback path, exercised for real).

- [ ] **Step 3: Update CLAUDE.md**

In the **Progress** bullet, after "the app is the only consumer, via `GrabRunner`.", add:

```
    One marker is metadata rather than a stage: `::progress:from:@user` names the
    Instagram account a grab came from (parsed from gallery-dl `--write-metadata` /
    yt-dlp `--write-info-json` sidecars — no extra network) and drives the app's
    "✓ Saved from @user" banner; a missing handle degrades to the plain "✓ Saved".
```

- [ ] **Step 4: Commit**

```bash
git add CLAUDE.md
git commit -m "docs: record the ::progress:from: metadata marker after end-to-end verification"
```
