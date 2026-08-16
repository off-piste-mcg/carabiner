# Browser extension — manual verification checklist

**Date:** 2026-08-14 · **Updated:** 2026-08-16
**Status:** 11 of 21 done — the extension is WORKING in both browsers (button, grabs,
mixed carousel, Cancel). Open: 10-11, the permissions-window checks (12-17), and the
Chrome Web Store steps (18-19).

Everything on this branch that a machine can check has been checked: 227 Swift tests,
64 JS tests, both shell suites, and per-task reviews with adversarial verification.

This list is what none of that can reach. Every item needs a human, a real browser and a
logged-in Instagram session. **Until it is worked through, the honest status of the
extension is "built and reviewed", not "working".**

Ordered by risk: the earlier items can invalidate the later ones.

## A. Does it load at all?

The highest-risk unknown on the whole feature. A silent failure here looks identical to
"the button just doesn't appear".

- [x] **1. Safari lists the extension.** Done 2026-08-16, and it took a real fix: pkd
      was refusing the appex at discovery — "Ignoring mis-configured plugin ... plug-ins
      must be sandboxed" — so Safari silently had nothing to list. The sandbox requirement
      is on the APPEX, not the app (commit 21493d0); the app stays unsandboxed. After the
      entitlement, pluginkit registers it and Safari lists it.
- [x] **2. Safari → Develop → Allow Unsigned Extensions is on.** Done 2026-08-16 —
      needed, and it does reset every Safari quit.
- [x] **3. The service worker actually starts, in both browsers.** Done — Chrome
      2026-08-14, Safari 2026-08-16 (working button implies a live worker).
- [x] **4. The content script's dynamic `import()` works on instagram.com.** Done in
      both browsers — buttons render, so the import survives Instagram's CSP, in Safari too.

## B. Does the button behave?

- [x] **5. Exactly one button per post** — verified in Chrome 2026-08-16.
- [x] **6. Clicking does not navigate to the post.** Verified in Chrome 2026-08-16.
- [x] **7. The button survives Instagram re-rendering.** Verified in Chrome 2026-08-16.
- [x] **8. Full happy path:** verified in Chrome 2026-08-14/16 and Safari 2026-08-16
      (real grabs through the button, files landed).
- [x] **9. A carousel:** verified in Chrome 2026-08-16 on a mixed video+image post —
      "This slide", "All", and Cancel (nothing downloaded, no banner) all correct.
- [ ] **10. Leave the carousel dialog open for a few minutes**, then answer it. The button
      must not have given up; the app's own 3600s backstop should be the only bound.
- [ ] **11. Quit Carabiner, then click a button.** It should launch the app and complete.
      Note what the browser's "Open Carabiner?" prompt looks like, and whether a cold launch
      beats the 2500ms retry.

## C. Permissions and setup

- [ ] **12. The Setup & Permissions window with 5 rows** — layout, no clipped text.
- [ ] **13. The Full Disk Access row.** Grant it, and answer the question nobody has tested:
      **does the row go green without quitting and relaunching Carabiner?** If it does not,
      the row will read red immediately after the user grants it, and it needs a "quit and
      reopen Carabiner" note. This is the sharpest open question in this section.
- [ ] **14. The deep link** `x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles`
      opens the right pane on this macOS version.
- [ ] **15. The Safari row's Allow** actually opens Safari's extension settings
      (`SFSafariApplication.showPreferencesForExtension`) — only ever verified to compile.
- [ ] **16. `lastSeen` survives a restart.** Get a browser row green, quit and reopen
      Carabiner, confirm it is still green.
- [ ] **17. The Safari→Chrome cookie fallback end to end:** with FDA denied, a Safari grab
      should silently succeed using Chrome's login and the banner should say so
      ("used Chrome's login"). Watch whether the ring visibly restarts mid-grab.

## D. Before the Chrome Web Store listing

- [ ] **18. `chrome://policy`** — your Chrome is managed by offpiste.agency. If it blocks
      extensions, an unlisted Web Store listing will not help the team either, and the
      extension would need allowlisting centrally. **Check this before paying the $5.**
- [ ] **19. Publish unlisted, then replace `PLACEHOLDER_ID`** in
      `app/Carabiner/Onboarding/OnboardingViewModel.swift`. Until then the Chrome row's
      Allow button opens a dead link.

## E. One-off checks worth doing once

- [x] **20. The 5s connection deadline.** Done 2026-08-14: a socket that connects and then
      sends nothing is closed after **5.25s**, zero bytes written. `curl /health` returns
      **403** in the same session — gate 1 (no extension `Origin`) working as designed.
- [x] **21. A long silent re-encode killed by the watchdog.** Done 2026-08-14. Confirmed
      first — a SIGTERM'd encode left a 19 MB `_fixed.mp4` that plays fine and just ends
      early — then fixed: `reencode` writes to a hidden `.part.mp4` sibling and renames on
      success. Re-tested both directions against the real bundled ffmpeg. The follow-on
      temp-source leak that test found was closed 2026-08-16 by a TERM/INT trap
      (see CLAUDE.md's rough-edges entry); verified with real group-kills.
