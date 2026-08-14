# Browser extension — manual verification checklist

**Date:** 2026-08-14
**Status:** outstanding — nothing on this list has been done

Everything on this branch that a machine can check has been checked: 227 Swift tests,
64 JS tests, both shell suites, and per-task reviews with adversarial verification.

This list is what none of that can reach. Every item needs a human, a real browser and a
logged-in Instagram session. **Until it is worked through, the honest status of the
extension is "built and reviewed", not "working".**

Ordered by risk: the earlier items can invalidate the later ones.

## A. Does it load at all?

The highest-risk unknown on the whole feature. A silent failure here looks identical to
"the button just doesn't appear".

- [ ] **1. Safari lists the extension.** Reinstall first — the copy in `~/Applications`
      predates the appex:
      ```bash
      cd ~/Documents/OFF-PISTE/Carabiner/app
      export CARABINER_TEAM_ID=$(security find-certificate -a -c "Apple Development" -p \
        | openssl x509 -noout -subject | tr ',/' '\n\n' \
        | sed -nE 's/.*OU=([A-Z0-9]{10}).*/\1/p' | head -1)
      xcodegen generate
      xcodebuild -project Carabiner.xcodeproj -scheme Carabiner \
        -configuration Debug -derivedDataPath /tmp/carabiner-dd build
      pkill -x Carabiner; rm -rf ~/Applications/Carabiner.app
      cp -R /tmp/carabiner-dd/Build/Products/Debug/Carabiner.app ~/Applications/
      open ~/Applications/Carabiner.app
      ```
      Then Safari → Settings → Extensions. If `open` fails, that is gotcha #27 — run
      `lsregister -f ~/Applications/Carabiner.app`, do not assume the build is broken.
      **If it does not appear, the prime suspect is App Sandbox:** Apple's own converter
      template sandboxes both the app and the appex; Carabiner is sandboxed in neither and
      cannot be (it shells out to yt-dlp/ffmpeg and writes `~/Downloads`). Whether Safari
      *requires* it is not determinable from a build.
- [ ] **2. Safari → Develop → Allow Unsigned Extensions is on.** A locally-signed,
      un-notarized extension usually will not list without it, and the setting resets every
      time Safari quits.
- [ ] **3. The service worker actually starts, in both browsers.** It is a *classic* worker
      using `importScripts`. If it does not register, every click fails and looks like a
      dead button. Chrome: `chrome://extensions` → "service worker" is active. Safari:
      Develop → Web Extension Background Content. (It is ephemeral and vanishes when idle —
      that is normal, not a fault.)
- [ ] **4. The content script's dynamic `import()` works on instagram.com.** Reasoned from
      documented Chrome behaviour, never measured on Instagram, and never in Safari at all.
      Instagram's page CSP is strict. Failure is silent by design → no buttons, no error.

## B. Does the button behave?

- [ ] **5. Exactly one button per post** on the home feed and on a post page, and one per
      tile on a profile grid. Fixtures say 1 / 1 / 12; real pages are the test.
- [ ] **6. Clicking does not navigate to the post.** Instagram uses `pointerdown`/
      `mousedown` SPA handlers, not just `click`.
- [ ] **7. The button survives Instagram re-rendering** — scroll away and back.
- [ ] **8. Full happy path:** ring advances against a real download, settles to a tick, file
      lands in `~/Downloads`, and the app's banner names it. Verify by filename diff, never
      by timestamp (gotcha: gallery-dl preserves Instagram's original mtime):
      ```bash
      ls -1 ~/Downloads > /tmp/before.txt   # …grab…   then:
      ls -1 ~/Downloads | diff /tmp/before.txt - | grep '^>'
      ```
- [ ] **9. A carousel:** the native dialog appears, "This slide" and "All" both work, and
      **Cancel downloads nothing and shows no banner**. Use a post that mixes video and
      images — gotcha #15's second failure is invisible on all-image carousels, and both
      OFF-PISTE posts qualify.
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
      success. Re-tested both directions against the real bundled ffmpeg. **Left open:** the
      same kill leaks `ig_video`'s 84 MB temp source (`.carabiner_src_<pid>.mp4`) into
      `~/Downloads`, because `rm -f "${tmp}".*` never runs on a kill. Needs a TERM trap.
