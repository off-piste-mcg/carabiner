# Carabiner — in-page download button (browser extension)

**Date:** 2026-08-12
**Status:** draft (design) — awaiting approval

## Problem

Carabiner can only grab what the **tab URL** points at. `resolve_url` reads the frontmost
browser tab via AppleScript and falls back to the clipboard; both give one URL for the
whole window. That is fine on a permalink page and useless everywhere else:

- Scrolling the **home feed**, the URL is `instagram.com/` — there is no "current post".
- On a **profile grid**, the URL is `instagram.com/<handle>/`.
- The only way to grab something you scrolled past is to open it first, which is exactly
  the friction the hotkey was built to remove.

There is no fix for this inside the current architecture. A global hotkey has no notion
of which post the pointer is over; only code running *inside the page* does.

Separately, the hotkey is invisible. A new teammate has to be told it exists, and a
silently-lost chord (gotcha #14) is indistinguishable from a broken app.

Prompted by the team using a Chrome extension ("Turbo Downloader for Instagram") that
puts a download icon on each post. It is smoother to reach for — and strictly worse at
the job, see below.

## Why the obvious version of this is wrong

The referenced extension does its own downloading: it reads Instagram's own API JSON
from inside the page (which carries a direct progressive `.mp4` CDN URL — this is why
gotcha #2's `blob:` problem does not apply to it), then saves it with `chrome.downloads`.
Cross-origin saving is free for an extension, which is what killed our bookmarklet
(gotcha #5).

What it cannot do is run ffmpeg. It hands you Instagram's raw file, which for 10-bit /
`yuv444p` posts is precisely the file QuickTime refuses to open (gotcha #3). It is easier
because it does less. Reimplementing that would be a regression.

## Decision

**The extension does not touch media.** Every feed post's DOM already contains an anchor
to `/p/<shortcode>/`. The extension's entire job is:

> locate a post → read its shortcode → inject a button → tell Carabiner.app to grab
> `https://www.instagram.com/p/<shortcode>/` → draw a progress ring from the app's replies.

Every decision that took months to settle — cookies, carousel detection, the QuickTime
re-encode, deterministic filenames, notifications — stays in the bash engine, unchanged.
The button is a new way to **ask**, not a new way to **download**.

Consequences worth stating plainly:

- No API scraping, no CDN URLs, no download code in the extension. When Instagram changes
  its API, we are unaffected; only a layout change can break us, and only cosmetically.
- The carousel prompt, the re-encode, the `@user` attribution and the branded notification
  all keep working with no new code.
- The extension is small enough to review in one sitting, which matters for Web Store
  review and for trust.

## Scope

**In:** feed posts, profile grid, post/reel permalink pages. Chrome (and Chromium
siblings: Brave, Arc, Edge) and Safari.

**Out, deliberately:** Stories (most fragile surface — ephemeral, autoplaying, obfuscated
markup, per-segment lifecycle; a follow-on phase). Non-Instagram sites in-page (the
hotkey remains the answer for YouTube/Pinterest). Firefox. Windows/Linux.

## What the team experiences

**First run, once, ~30 seconds**

1. Download Carabiner, drag to Applications, open it.
2. The existing **Setup & Permissions** window opens.
3. A new **Instagram button** section lists a row per browser found on the machine.
4. *Allow* on the Safari row → Safari's extension settings open with Carabiner already
   listed → one switch, then "Always Allow on instagram.com".
   *Allow* on the Chrome row → the unlisted Web Store page opens → "Add to Chrome".
5. Each row turns green **only once that browser's extension has actually reached the
   app** — never a guess. Same honesty rule as every other row in that window.

**Daily**

- Browse Instagram normally.
- A small OFF-PISTE mark sits in the corner of each post's media (always visible on a
  permalink page; on hover in feed and grid).
- Click it → it fills into a progress ring → settles to a checkmark.
- File lands in `~/Downloads`, QuickTime-ready.
- Carousel → the same native "this slide or all of them?" dialog as today.

The hotkey is untouched and stays the answer for anything outside Instagram.

## Architecture

```
Chrome / Safari extension (one MV3 codebase, two builds)
  content script  — find posts, inject button (shadow DOM), render ring
  service worker  — POST http://127.0.0.1:51847/grab  {url, browser}
                    ← NDJSON stream of progress events, then a final result
        │ on connection failure: open carabiner:// to launch the app, retry once
        ▼
Carabiner.app
  GrabServer.swift (new)  — loopback HTTP, origin + URL gate, streams progress
  GrabRunner.swift        — unchanged
        ▼
carabiner (bash engine, unchanged) → yt-dlp / gallery-dl / ffmpeg → ~/Downloads
```

### The local channel

A loopback HTTP listener (`NWListener`, bound to `127.0.0.1` only — never `0.0.0.0`) on a
fixed port **51847**. Two routes, nothing else:

| Route | Purpose |
|---|---|
| `GET /health` | Returns app version + build. Extension calls it on install and on browser/extension startup (`chrome.runtime.onInstalled` / `onStartup` — corrected, final review: as-built this is NOT "on each page load", which was this doc's original, never-implemented plan) to prove the connection; the app records "last seen" per browser, which is what turns the onboarding row green. |
| `POST /grab` | Body `{url, browser, slide?}`. Streams NDJSON progress events, then a terminal result event. |

The port is fixed rather than negotiated, because the extension has no other way to find
it. If the bind fails because something else holds 51847, the app does **not** silently
pick another port — it surfaces the failure in the onboarding row ("port in use"), since a
silently-moved port would present as a button that does nothing. **Checked true, final
review, Finding 2:** this was written before anything actually read `GrabServer.state` —
`state` sat `private(set)` with zero readers, so the claim was aspirational, not built,
and doubled as a real exposure (a local process squatting on 51847 before Carabiner starts
would win the bind silently and receive every permalink the extension POSTs). Now wired:
`browserButtonStatus(lastSeen:now:serverState:)` (PermissionModels.swift) checks
`GrabServer.state` before it even looks at `lastSeen`, and a `.failed` listener renders as
a `.serverUnavailable` row — cross-tick, no "Allow" button, no System Settings deep-link,
since neither can fix a port collision.

**Why HTTP and not a custom URL scheme.** `carabiner://grab?url=…` was the first
candidate and is simpler, but it has no return channel: the button could not show
progress, and every click would fire the browser's "Open Carabiner?" interstitial. The
return channel is what makes this feel finished, so it is worth the extra machinery. The
scheme is still registered — it is the *launch* fallback below, where a one-time prompt
is acceptable.

**Why not native messaging.** Chrome and Safari implement it via entirely different
mechanisms (a `NativeMessagingHosts` manifest keyed to a fixed extension ID vs. an
`NSExtension` handler in the app bundle). Two code paths and two failure modes to carry
one string.

### Access control

The threat is a malicious *web page* reaching the port and making the machine download
things. Two gates, no pairing token and no setup step:

1. **Origin prefix.** The browser sets `Origin` itself and a page cannot forge it. Pages
   always send `https://…`; extensions send `chrome-extension://…` or
   `safari-web-extension://…`. Only those two schemes are accepted. Exact-ID allowlisting
   is *not* used because Safari's extension origin is a random per-install UUID.
   **Load-bearing detail:** the request must be sent from the **background service
   worker**. A `fetch` from the content script carries `https://www.instagram.com` as its
   origin and would be rejected — correctly.
2. **URL allowlist, server-side.** Only Instagram/YouTube/Pinterest URL patterns are
   accepted, so a request that somehow cleared gate 1 still cannot *submit* an arbitrary
   address to `yt-dlp` — though see the redirect limit below, which is why this is
   defence in depth and not a boundary. Anything else → `400`. **`https` only** — an extension will only
   ever see https on these hosts, and allowing plain http would widen the redirect seam
   below to any on-path attacker.

**Two corrections earned in review, 2026-08-12, before the listener existed.** Both were
defects in this document's own first draft, found by re-implementing the gate standalone
and running ~50 hostile inputs through it:

- **The gate must return the *parsed* URL, never the caller's raw string.** The first
  draft returned the input verbatim on success. `https://www.instagram.com/p/C1/\r\nX-Injected: 1`
  cleared both gates and came back with the CRLF intact — and this value is echoed into
  an HTTP response header, so that is header injection. The same applies to the origin:
  `chrome-extension://a\r\nAccess-Control-Allow-Credentials: true` passed a bare prefix
  check. The gate now validates the origin's character set (a serialised origin is
  scheme + host + port, never a path) and returns `parsed.absoluteString`. The rule
  generalises: everything downstream trusts a gate's *output*, so a gate that passes
  its input through unnormalised is not a gate.
- **Gate 2 constrains the URL submitted, not the address finally fetched.**
  `https://l.instagram.com/?u=https%3A%2F%2Fevil.example%2Fx` is a legitimate
  dot-boundary match, and yt-dlp/gallery-dl follow redirects without re-consulting
  anything. Gate 1 still requires an extension origin, so this is defence in depth
  rather than a hole — but the earlier wording ("cannot point the downloader at an
  arbitrary address") was false and is corrected here.

What survived the same adversarial pass unchanged, and should not be "improved": the host
dot-boundary match (`host == x || host.hasSuffix("." + x)`) blocked `instagram.com.evil.example`,
`evilinstagram.com`, punycode homographs and userinfo spoofs (`https://instagram.com@evil.example/`,
where `URL.host` correctly lands on `evil.example`); and anchoring the origin check with
`hasPrefix` blocked `https://evil.example/chrome-extension://x`.

Also: one grab at a time. A second `POST /grab` while one is running returns `409`, and
the button renders "busy" rather than queueing.

An extension the user has *already installed* could reach the port. That is accepted — a
hostile installed extension has far worse options available to it, and the URL allowlist
caps the damage at "downloads an Instagram post".

CORS: respond to `OPTIONS` with `Access-Control-Allow-Origin` echoing the (validated)
origin and `Access-Control-Allow-Headers: content-type`. The Chrome manifest also
declares `http://127.0.0.1:51847/*` in `host_permissions`.

### Progress

`GrabRunner` already parses the engine's `::progress:` markers to drive the menu-bar ring.
`GrabServer` subscribes to the same events and writes them to the open response as
newline-delimited JSON:

```
{"stage":"resolve"}
{"stage":"download","pct":42.0}
{"stage":"convert"}
{"from":"@offpiste.mcg"}
{"result":"ok","files":1,"name":"C1a2b3c4_fixed.mp4"}
```

The button ring mirrors the menu-bar ring's rule (gotcha: the ring means *downloading*):
it stays idle until the first activity marker, so the carousel probe and the dialog show
no ring. **Corrected, final review:** no streamed-body fallback exists — the original plan
here was never built. As-built, `worker.js#run()` calls `response.body.getReader()`
unconditionally; if that ever throws (a browser that can't stream a response body), the
error propagates out of `run()` and is caught by the same `.catch` that handles every
other failure in that function, which reports the grab as a plain error to the button. No
indeterminate spinner exists anywhere in this codebase — an unreadable body degrades to
the ordinary error state, not a distinct one.

The app's own banners and menu-bar ring are unchanged and still fire. A click in the page
produces in-page feedback *and* the usual notification; that is deliberate, since the
outcome banner is what reports the filename and the `@user`.

### Carousels

v1 changes nothing: the engine probes and shows its own native dialog (gotchas #9, #15,
#24 all continue to apply, untested code paths included). `::progress:prompt` reaches the
button's owning `grabTracker` and suspends its client-side watchdog there (a human reading
the dialog must not be flagged "interrupted"), but — **corrected, final review:** there is
no distinct visual "waiting for you" state on the button itself. `ringFractionForProgress`
treats `prompt` the same as `probe` (returns `null`, ring unmoved — see ring.js), so the
button simply holds whatever it was already showing while the dialog is up.

An in-page slide picker is *not* in v1. It would duplicate detection logic that gotcha #15
records as subtle and twice-broken, in a second language, against markup that changes
without warning. The optional `slide` field in `POST /grab` reserves the wire format for
it.

### Button injection

- A `MutationObserver` watches for post containers; each handled node is tagged so work
  is idempotent.
- Shortcode comes from the nearest `a[href*="/p/"], a[href*="/reel/"]` — a pure function,
  unit-tested against saved DOM fixtures.
- The button renders inside a **shadow root** so Instagram's CSS cannot reach it and ours
  cannot leak out.
- If no shortcode can be derived, no button is injected. Never throw, never log noisily
  into the page console.

### Distribution

- **Safari:** a Safari Web Extension app-extension target inside `Carabiner.app`
  (`Contents/PlugIns`), declared in `app/project.yml`, signed and notarized by the
  existing `scripts/release.sh`. No store, no separate download. The onboarding row opens
  its settings directly via `SFSafariApplication.showPreferencesForExtension(withIdentifier:)`.
- **Chrome:** an **unlisted** Chrome Web Store listing — installable by direct link,
  not searchable, not categorised. One-off $5 developer account plus review. Chose this
  over MDM force-install (the team has no MDM, confirmed 2026-08-12) and over
  developer-mode "load unpacked" (per-launch nag, silently disable-able, breaks if the
  folder moves). Self-hosted `.crx` is blocked by Chrome on macOS by policy — no
  certificate resolves it; Apple's Developer ID has no standing with Google.
- One source tree builds both; Safari 16.4+ supports MV3 and the `browser.*` namespace.

## Risks and unknowns

**Must be verified before the design is trusted, not assumed:**

1. ~~**Does Safari send `Origin` on a background-script `fetch`?**~~ **VERIFIED 2026-08-12
   — both browsers do, and the design holds.** Measured against a throwaway listener that
   recorded raw request headers, with the extension loaded unpacked in Chrome and built
   through `safari-web-extension-converter` for Safari:

   - Chrome → `Origin: chrome-extension://ccngbaicbbcdhbppljflaagmbfpcjjcn` (matches the
     extension ID exactly)
   - Safari → `Origin: safari-web-extension://dcea6524-ab56-4469-895f-d4f4e84f139e`
     (a per-install UUID, which is why exact-ID allowlisting was never an option)

   **Two things the measurement changed, both worth more than the yes/no answer:**

   - **Safari sends a CORS preflight `OPTIONS`; Chrome does not.** Chrome skips it because
     `http://127.0.0.1:51847/*` is in `host_permissions`; Safari preflights anyway. So
     `GrabServer`'s `OPTIONS` handler is **load-bearing for Safari**, not defensive
     politeness — remove it and Safari silently stops working while Chrome carries on
     fine, which is the worst shape a bug can have.
   - **The MV3 service worker is ephemeral and Safari kills it when idle.** It disappears
     from Develop → Web Extension Background Content mid-session, so any procedure that
     depends on catching it in an inspector console is unreliable. The measurement was
     taken by making the worker fire its request at startup instead. This matters beyond
     testing: the worker holds the streaming connection for the whole grab, so a long
     carousel must keep it alive. An in-flight `fetch` does reset the idle timer, but this
     is worth re-checking against a genuinely long grab before trusting it.
2. ~~**Safari cookies may need Full Disk Access.**~~ **CONFIRMED 2026-08-13 — they do.
   Safari users cannot download anything until it is granted.** Measured on this machine,
   Safari quit so its cookie file was flushed:

   ```
   carabiner -b safari -s 1 'https://www.instagram.com/p/<code>/'
   ERROR: [Errno 1] Operation not permitted:
     '~/Library/Containers/com.apple.Safari/Data/Library/Cookies/Cookies.binarycookies'
   ✗ download failed.
   ```

   The control matters as much as the result: **the same URL and the same command with
   `-b chrome` downloaded the file successfully**, so this is specifically macOS denying
   the Safari cookie read, not a bad post, a bad URL, or a broken engine.

   Consequences, all now certain rather than contingent:
   - The onboarding window gains a **Full Disk Access** row. It is not optional and not
     conditional — without it the button is decorative for every Safari user.
   - That row can neither grant nor even *prompt*: macOS provides no API for either.
     It can only detect (attempt the read), explain, and deep-link to
     `x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles`.
     Detection by attempting the read is what keeps it honest — the row goes green only
     when the read actually succeeds.
   - **Fallback:** on a Safari cookie-read failure, retry once against Chrome's cookies
     before surfacing an error. The control above proves this path works. It turns a hard
     failure into a silent success for anyone signed into Instagram in both browsers,
     which is most of the team.
   - The error text the user sees must name Full Disk Access. `Operation not permitted`
     on a path nobody recognises is not a diagnosis.

   **Requirement (stated by Wisse, 2026-08-12): whatever permissions this turns out to
   need, they are granted from the Setup & Permissions window like every other one — an
   Allow row with live status, never a written instruction to go hunting in System
   Settings.** For Full Disk Access specifically, note the honest limit of what an app can
   do: macOS has no API to grant it, and unlike Automation it cannot even be *prompted*
   for. The row must therefore (a) detect the real state by attempting the cookie read,
   (b) deep-link to `x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles`,
   and (c) explain in one line why it is needed. Detection is what makes it honest: the
   row goes green only when the read actually succeeds.
3. **Instagram markup churn** will break button placement periodically. Accepted: the
   hotkey and the app keep working, so this is never a single point of failure. The
   fixture-based shortcode tests localise the damage.
4. **Web Store review** may object to the localhost host permission. It is a common and
   defensible pattern (a companion desktop app), but budget for one round of questions.

## Testing

- **Pure functions, unit-tested** — shortcode extraction from saved DOM fixtures (JS);
  origin gate and URL allowlist (Swift, following the `BannerPlanner` precedent of
  keeping the decision pure because the I/O layer is untestable).
- **Server**, offline: `curl` against `/health` and `/grab` asserting **both directions** of
  each gate — a page origin is rejected *and* an extension origin is accepted; a
  non-allowlisted URL is rejected *and* an Instagram URL is accepted. Gotcha #25's lesson
  applies directly: a gate tested only on inputs it should reject proves nothing.
- **Manual, real:** grab from the feed in Chrome and in Safari, one image post and one
  mixed video+image carousel (gotcha #15 — both OFF-PISTE posts qualify), confirming the
  file opens in QuickTime.
- Existing `test/test-path.sh`, `test/test-progress.sh`, `test/test-release.sh` are
  unaffected; the engine does not change.

## Non-goals

Stories. In-page carousel picker. Any download logic in the extension. Firefox. A public
Web Store listing. Replacing the hotkey or the Shortcut.
