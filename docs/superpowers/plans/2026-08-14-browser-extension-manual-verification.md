# Browser extension — manual verification checklist

**Date:** 2026-08-14 · **Updated:** 2026-08-18
**Status:** 17 of 21 done — the extension is WORKING in both browsers (button, grabs,
mixed carousel, Cancel), the Setup & Permissions window is verified except for the
fallback, and **cold launch now works (item 11, Chrome only)**. Open: 10 (button
patience), 17 (the FDA-denied Safari→Chrome fallback, which costs an FDA revoke and an
OS-forced relaunch), and 19 (the Chrome Web Store listing).

**New and NOT on this list, found while fixing 11:** `ping()` used the same bare
`GET /health` that Chrome answers 403 to, so the extension's check-in has never reached
the app from Chrome — meaning the onboarding window's **Chrome row can never have turned
green**. Fixed in commit 0864b45, unverified. Safari's row was verified (item 15) because
Safari sends an `Origin`; that is why this survived.

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
- [x] **11. Quit Carabiner, then click a button — DONE 2026-08-18 (Wisse, Chrome).** Cold
      click launches the app, the launch tab closes itself, focus returns to the post, and
      the file lands. Commit 0864b45. It took **three** distinct bugs, and the first two
      were not the cause — worth knowing, because each one alone reproduces the symptom:

      | Bug | Why it hid |
      |---|---|
      | launch tab created `active: false` | Chrome's "Open Carabiner?" dialog is TAB-MODAL, so it rendered on a tab nobody could see, then our own `tabs.remove(1500ms)` destroyed it. Nothing could answer it. |
      | fixed 2500ms retry | Sized against the app's 0.21s cold start, but the launch waits on a HUMAN answering that dialog. Measured: app started fine, grab still failed with a red X. |
      | **`GET /health` → 403 (the actual cause)** | `/health` is origin-gated, and Chrome sends **no `Origin`** on a simple GET from an extension worker — host permissions bypass CORS, so there is nothing to attach one to. The probe could not have succeeded at ANY timeout. |

      The decisive measurement, in Chrome's own service-worker console against a running
      app — five seconds of work that should have come first:

      ```
      GET  /health → 403
      POST /health (content-type: application/json) → 200
      ```

      Two process lessons, both paid for in real runs:

      - **"curl works, the extension doesn't" means the REQUESTS differ.** Three rounds went
        into worker-termination and hung-socket theories, both consistent with the symptom
        and both wrong, before anyone compared the two requests.
      - **An open DevTools console keeps an MV3 worker alive**, so it cannot observe a
        worker-termination bug — it prevents it. A `chrome.storage` trace was added to see
        past that, and was itself inert at first because the manifest lacked the `storage`
        permission while the write was wrapped in a silent `catch`. **Verify the instrument
        before trusting a run made with it.**

      The `storage` permission and all trace/console diagnostics were removed before the
      commit, and the cold path was re-verified on the cleaned build — not on the
      instrumented one.

      **Safari's cold-launch path is still unverified.** Safari sends an `Origin` where
      Chrome does not (gotcha #29), so it may well have been fine all along, or fail
      differently. Do not assume this tick covers it.

## C. Permissions and setup

- [x] **12. The Setup & Permissions window with 5 rows** — done 2026-08-17. Five rows plus
      the hotkey block render with no clipped text at the default window size.
- [x] **13. The Full Disk Access row.** Done 2026-08-17, and the answer is better than the
      question feared. A fresh grant does **not** reach the running process — but macOS
      enforces that itself: toggling Carabiner on offered **only "Quit & Reopen"**, with no
      "Later". After the OS-forced relaunch (pid 87789 → 89252) the row read green. **No
      "quit and reopen" note is needed** — macOS closes the hole for us. The green was then
      cross-checked against gotcha #28's false-green trap with a real grab driven through
      `POST /grab` with `browser: safari`: 2 files, `::progress:from:@off__piste`, and a
      single clean stage sequence, so no Chrome fallback fired (`shouldRetryWithChrome`
      only runs on a *failed* Safari attempt, which would have replayed the stages and
      re-shown the dialog).
- [x] **14. The deep link** `x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles`
      — done 2026-08-17. Opening it leaves System Settings showing a window whose title is
      literally `Full Disk Access`, so it lands on the exact pane, not the Privacy root.
- [x] **15. The Safari row's Allow** — done 2026-08-17, but it **failed the first time and
      the failure was invisible**, which is the part worth keeping. Safari's settings simply
      never appeared (confirmed via System Events: Safari had one window, "Instagram"), with
      no error anywhere, because the call passed no completion handler and threw its
      `Error?` away. Instrumented with one (`OnboardingViewModel.installBrowserButton`), it
      has since reported **success 3 for 3** and Safari's Extensions pane opens with the
      extension selected. Cause of the first failure unproven; the reinstall +
      `lsregister -f` in between is the only candidate. The identifier is correct and now
      lives in `OnboardingViewModel.safariExtensionIdentifier`, coupled by nothing but a
      comment to the appex's `PRODUCT_BUNDLE_IDENTIFIER`.
      **Noted, not chased:** Safari's Installed list shows **two identical "Carabiner"
      entries**, both enabled, identical panes — while `pluginkit -m -A -v` reports exactly
      **1 plug-in** and only one appex exists on disk. So it is Safari-side state, not a
      second registration. Prime suspect is the "Share across devices" checkbox (iCloud-
      synced extension records); second is a stale record from the `/Applications` copy
      deleted the same day. Not a blocker — the extension works — but check this before
      concluding a user has installed it twice.
- [x] **16. `lastSeen` survives a restart.** Done 2026-08-17, isolated so a fresh check-in
      could not fake it: the worker pings `/health` only on `onInstalled`/`onStartup`, so an
      app restart cannot trigger one, and the persisted timestamps were byte-identical
      before and after (`chrome` 09:39:22Z, `safari` 10:07:51Z). Row still green after the
      restart, so the value came off disk.
- [ ] **17. The Safari→Chrome cookie fallback end to end:** with FDA denied, a Safari grab
      should silently succeed using Chrome's login and the banner should say so
      ("used Chrome's login"). Watch whether the ring visibly restarts mid-grab.

## D. Before the Chrome Web Store listing

- [x] **18. `chrome://policy`** — checked and clean: no extension restrictions, so the $5
      listing is unblocked. (Verified earlier; this box was never ticked here.)
- [ ] **19. Publish unlisted, then replace `PLACEHOLDER_ID`** in
      `app/Carabiner/Onboarding/OnboardingViewModel.swift`. Until then the Chrome row's
      Allow button opens a dead link — and observed 2026-08-17, "dead" is gentler and
      worse than expected: `chromewebstore.google.com/detail/PLACEHOLDER_ID` does not 404,
      it **silently redirects to the Web Store home page**, so a user who clicks Allow
      lands on "Welcome to the Chrome Web Store" with no hint of what went wrong.

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
