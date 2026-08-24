# Main window: recent grabs + grab box, Dock drop, Settings → ⌘, — design

**Date:** 2026-08-21
**Status:** approved (Wisse, in conversation)

## What

Carabiner's Dock click stops opening Setup & Permissions and opens a real main
window instead: a paste/drop grab box on top, the recent-grabs history below.
Setup & Permissions moves to the standard "Settings…" ⌘, item in the app menu
(the status-bar menu row and the first-launch auto-open stay). A URL dragged
onto the Dock tile starts a grab.

Rejected in conversation: keeping Dock click on Settings (hides the daily-use
surface), session-only history (a restart wipes exactly what you wanted), and
unbounded history (needs search/cleanup to stay usable).

## Components

**1. `GrabResult.files`.** The runner already parses the script's `✓ <name>`
lines but keeps only a summary string. A new `files: [String]` carries the
announced names through (default `[]`, so every existing call site and test is
unaffected). Note the YouTube/Pinterest paths announce `saved to ~/Downloads`,
not a filename — history entries tolerate a non-filename entry (no thumbnail,
no reveal).

**2. `GrabHistoryStore`** (`app/Carabiner/History/`). `ObservableObject`
holding `[GrabHistoryEntry]` (`date, url, files, user`), newest first, capped
at 50. Persisted as JSON at `~/Library/Application Support/Carabiner/history.json`
(directory injectable for tests), written atomically on each record, loaded at
init. A corrupt or missing file means empty history, never a crash. Only
successful results are recorded; cancelled and failed grabs are not. Main
thread only — recording happens in the grab completion, which is already on
main.

**3. Recording point.** One place: `MenuBarController.grab(url:browser:...)`'s
completion — the funnel all app-driven grabs (hotkey, extension, window, Dock
drop) already pass through. Shortcut-path grabs never touch the app and
cannot appear; the spec records that as a known limit, not a bug.

**4. `GrabGate.checkURL`.** The URL half of `check(origin:url:)` extracted as
its own pure function (https-only + host allowlist + re-serialisation);
`check` now calls it, behavior unchanged. The window's Grab button and the
Dock drop route through `checkURL` — same rules as the extension.

**5. The main window** (`app/Carabiner/MainWindow/`). SwiftUI in an
`NSWindowController`, same pattern as onboarding. Grab box: URL text field
(paste) + Grab button, plus drag-and-drop of a URL onto the window; invalid
URLs show an inline message naming the allowed sites. While its grab runs the
box shows the stage text from `::progress:` events; `busy` from another front
end renders the button disabled with "already grabbing". History list: rows
with QuickLook thumbnail (file-icon fallback), filename, `@user`, relative
time. Click reveals in Finder, double-click opens; a row whose file no longer
exists in `~/Downloads` is dimmed with actions disabled. Banners behave
exactly as today for every path.

**6. Dock click & menu.** `applicationShouldHandleReopen` opens the main
window (was: Settings). The app menu gains "Settings…" (⌘,) →
`showOnboarding()`. First-launch auto-open of onboarding unchanged.

**7. Dock drop.** `project.yml` declares `CFBundleDocumentTypes` accepting
`public.url` (document-type acceptance only — no scheme claim, Carabiner does
not become a browser candidate). `application(_:open:)` routes each URL
through a pure `dockOpenAction(for:)`: `carabiner:` scheme → launch only
(existing behavior); anything `checkURL` accepts → start a grab with the
working banner as feedback; everything else → ignore with a log line. Busy
behaves like the hotkey path: log and drop.

## Testing

- `GrabHistoryStoreTests`: newest-first ordering, the 50 cap, persistence
  round-trip, corrupt file → empty, failed/cancelled results not recorded.
- `GrabGateTests`: `checkURL` directly (https/host/junk); existing `check`
  tests unchanged prove the refactor.
- `dockOpenAction`: carabiner:// vs accepted https vs http vs off-allowlist.
- `GrabRunner`: a stub-script run asserting `files` carries every `✓` line.
- Wiring limits stated where the tests live (gotcha #34): MenuBarController's
  recording call site and the window UI are AppKit-bound and verified by hand.
