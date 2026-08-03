# "Saved from @user" outcome notification — design

**Date:** 2026-08-03
**Status:** approved (approach); spec pending user review

## Goal

The app's success banner currently reads:

> **Carabiner**
> ✓ Saved
> 9 files

For Instagram grabs it should name the account it came from:

> **Carabiner**
> ✓ Saved from @wissevellinga
> 9 files

Scope is **Instagram only** — YouTube / Pinterest / generic grabs keep the current
banner. The Shortcut's plain `osascript` notification is unchanged (the marker this
design adds would make upgrading it trivial later, but that is out of scope).

## Where the handle comes from: the engine reports it

Both tools already fetch the account handle with every grab; the script just never
asks for it. No extra network calls (gotcha #21):

- **`ig_gallery` (images / carousels):** add `--write-metadata` to the gallery-dl
  call. It writes a per-file `<name>.json` into the temp download dir containing
  `"username"` — the real handle, not a numeric ID. The existing
  `! -name '*.json'` exclusions in the file loop and the `total` count already keep
  those sidecars out of the saved output; that exclusion becomes load-bearing.
  Parse the handle from the first sidecar with `sed` (dependency-light, known key —
  no JSON parser needed).
- **`ig_video` (reels / video slides):** add `--write-info-json` to the yt-dlp
  call. It writes `${tmp}.info.json`, which the existing `rm -f "${tmp}".*`
  cleanup already covers. **Which field carries the handle must be verified
  against a real post during implementation** — gotcha #7 says `uploader_id` is a
  numeric trap; the candidates are `channel` and `uploader`.
  - `--write-info-json` is used rather than `--print` because `--print` implies
    `--quiet`/`--simulate` semantics that would interact with the progress
    template pipeline; a sidecar file is inert.

## How it reaches the app

The script emits one new stderr marker once the handle is known:

```
::progress:from:@wissevellinga
```

- stderr keeps stdout — the Shortcut's channel — byte-for-byte unchanged.
- Emitted at most once per grab, only on the Instagram paths, only when the
  handle was actually found. A missing/unparseable sidecar emits nothing and the
  grab proceeds exactly as today — the handle is decoration, never a dependency.

App side:

- `ProgressParser` gains a `.from(handle: String)` event.
- `GrabRunner` records the handle from the event stream and adds
  `user: String?` to `GrabResult`.
- `BannerPlanner.finished` passes it through:
  `.postOutcome(ok:message:user:)`.
- `Notifier` composes the subtitle:
  - success, handle known: `✓ Saved from @wissevellinga`
  - success, no handle (non-IG, metadata missing): `✓ Saved` (today's text)
  - failure: `✗ Grab failed` (unchanged)
- Body is unchanged: the filename for a single file, `N files` for a carousel.
- `BannerPlanner` ignores `.from` for the *working* banner — it is not a stage.

## Rolled-in fix (pre-existing, flagged by gotcha #23)

`ig_video` picks its downloaded file with `head -n1` of an alphabetical
`ls "${tmp}".*`. With `--write-info-json` added, `.info.json` sorts before
`.mp4` and would win — so the lookup is tightened to exclude `*.json`. This is
exactly the "worth tightening the next time that function is touched" note in
gotcha #23, and this change is what makes it mandatory rather than latent.

## Error handling

- Sidecar missing, key missing, or empty value → no marker, banner falls back to
  `✓ Saved`. Never fail or delay a grab over the handle.
- Handle sanitised to a single token (strip whitespace/newlines) before the
  marker is written, so a malformed sidecar cannot inject extra marker lines.

## Testing

- `test/test-progress.sh`: extend the stubbed gallery-dl/yt-dlp to write the
  sidecar the real tools write (per gotcha #23's stub lesson — the stub must
  model the real behaviour, including the field name verified against a real
  post), and assert the `::progress:from:` marker appears on stderr, not stdout.
- Swift unit tests: `ProgressParser` parses `::progress:from:@x`;
  `BannerPlanner` outcome carries the handle; fallback when `user == nil`.
- End-to-end: one real grab through the installed app (rebuilt — the app runs a
  bundled snapshot of the script) against a real IG post, confirming the banner
  reads `✓ Saved from @<handle>`; verify saved files by filename diff, not
  timestamps.
