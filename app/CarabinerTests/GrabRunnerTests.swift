import XCTest
@testable import Carabiner

/// Thread-safe hand-off for a result produced on a background queue.
private final class ResultBox {
    private let lock = NSLock()
    private var value: GrabResult?
    func set(_ newValue: GrabResult) { lock.lock(); value = newValue; lock.unlock() }
    func get() -> GrabResult? { lock.lock(); defer { lock.unlock() }; return value }
}

final class GrabRunnerTests: XCTestCase {
    private func writeStub(_ body: String) -> String {
        let path = NSTemporaryDirectory() + "carabiner-stub-\(UUID().uuidString).sh"
        try! ("#!/bin/bash\n" + body).write(toFile: path, atomically: true, encoding: .utf8)
        try! FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
        return path
    }

    func testSuccessExitZero() {
        let stub = writeStub("echo '  ✓ ABC_fixed.mp4'; echo Done; exit 0")
        let result = GrabRunner(executable: stub).run(url: "https://x/y")
        XCTAssertTrue(result.ok)
        // The filename is the whole point of the banner — it must survive to the message.
        XCTAssertEqual(result.message, "ABC_fixed.mp4")
    }

    /// The URL must arrive as the single argument, and `CARABINER_NO_NOTIFY` /
    /// `CARABINER_BROWSER` must reach the child: the first is the entire contract with
    /// the script's notify gate (regress it and users get two banners), the second keeps
    /// the cookies coming from the same browser we read the tab from.
    func testPassesURLAndEnvironmentToScript() {
        let stub = writeStub(#"echo "  ✓ $#|$1|${CARABINER_NO_NOTIFY:-unset}|${CARABINER_BROWSER:-unset}"; exit 0"#)
        let result = GrabRunner(executable: stub, browser: .safari).run(url: "https://x/y")
        XCTAssertTrue(result.ok)
        XCTAssertEqual(result.message, "1|https://x/y|1|safari")
    }

    /// Several saves (a carousel) collapse to a count rather than one arbitrary filename.
    func testMultipleSavesSummarised() {
        let stub = writeStub("echo '  ✓ ABC_s1.jpg'; echo '  ✓ ABC_s2.jpg'; echo '  ✓ ABC_s3.mp4'; exit 0")
        let result = GrabRunner(executable: stub).run(url: "https://x/y")
        XCTAssertTrue(result.ok)
        XCTAssertEqual(result.message, "3 files")
        // The summary loses the names; `files` is where the history finds them, in order.
        XCTAssertEqual(result.files, ["ABC_s1.jpg", "ABC_s2.jpg", "ABC_s3.mp4"])
    }

    /// Cancelling the carousel prompt makes `carabiner` exit 0 having saved nothing,
    /// announcing `  cancelled.` on stdout. That is a deliberate act — it must not banner
    /// as a success, a failure, or a crash, so it needs its own flag.
    func testCancelledPromptIsReportedAsCancelled() {
        let stub = writeStub("echo 'carabiner → instagram'; echo '  cancelled.'; exit 0")
        let result = GrabRunner(executable: stub).run(url: "https://x/y")
        XCTAssertFalse(result.ok)
        XCTAssertTrue(result.cancelled)
    }

    /// Exit 0 with nothing announced and no cancel line is still not a success — but it
    /// isn't a cancel either, so it must keep bannering as a failure.
    func testExitZeroWithoutMarkerIsNotSuccess() {
        let stub = writeStub("echo 'carabiner → instagram'; exit 0")
        let result = GrabRunner(executable: stub).run(url: "https://x/y")
        XCTAssertFalse(result.ok)
        XCTAssertFalse(result.cancelled)
        XCTAssertEqual(result.message, "Nothing saved")
    }

    /// yt-dlp reports progress with carriage returns, so the whole download can land as
    /// one `\r`-separated blob. Splitting on `\n` alone would hide the ✓ inside it.
    func testCarriageReturnProgressStillYieldsTheMarker() {
        let stub = writeStub(#"printf '[dl]  10%%\r[dl] 100%%\r  ✓ saved to ~/Downloads\n'; exit 0"#)
        let result = GrabRunner(executable: stub).run(url: "https://x/y")
        XCTAssertTrue(result.ok)
        XCTAssertEqual(result.message, "saved to ~/Downloads")
    }

    /// `carabiner` asks the carousel question with `read` when stdin is a TTY. Run the app
    /// from a terminal and an inherited TTY would block it forever, so stdin is /dev/null.
    func testChildStdinIsNotATTY() {
        let stub = writeStub("if [ -t 0 ]; then echo '  ✓ tty'; else echo '  ✓ notty'; fi; exit 0")
        XCTAssertEqual(GrabRunner(executable: stub).run(url: "https://x/y").message, "notty")
    }

    /// A "✗ " that isn't leading is part of the message, not decoration.
    func testOnlyLeadingFailureMarkerIsStripped() {
        let stub = writeStub(#"echo '✗ bad ✗ marker' 1>&2; exit 1"#)
        XCTAssertEqual(GrabRunner(executable: stub).run(url: "https://x/y").message, "bad ✗ marker")
    }

    func testFailureReportsLastLine() {
        let stub = writeStub("echo 'trying'; echo '✗ not logged in' 1>&2; exit 1")
        let result = GrabRunner(executable: stub).run(url: "https://x/y")
        XCTAssertFalse(result.ok)
        XCTAssertTrue(result.message.contains("not logged in"))
    }

    /// Regression guard: `carabiner` shells out to yt-dlp/ffmpeg, which are very chatty on
    /// stderr. Draining stdout to EOF before touching stderr deadlocks once the child fills
    /// stderr's ~64KB pipe buffer. This stub writes ~250KB to *each* stream, so an
    /// implementation that drains sequentially will hang and blow the expectation timeout
    /// instead of hanging the whole suite.
    func testLargeInterleavedOutputDoesNotDeadlock() {
        let stub = writeStub("""
        line=$(printf 'x%.0s' {1..200})
        for i in $(seq 1 1200); do
          echo "err $i $line" 1>&2
          echo "out $i $line"
        done
        echo '✗ giving up' 1>&2
        exit 1
        """)
        let box = ResultBox()
        let done = expectation(description: "GrabRunner.run returns instead of deadlocking")
        DispatchQueue.global(qos: .userInitiated).async {
            box.set(GrabRunner(executable: stub).run(url: "https://x/y"))
            done.fulfill()
        }
        wait(for: [done], timeout: 30)

        let result = box.get()
        XCTAssertEqual(result?.ok, false)
        XCTAssertEqual(result?.message, "giving up")
    }

    /// The app must hand the script its private bin directory. Without this the script
    /// falls back to Homebrew, which is exactly the silent-shadowing failure Phase 2 exists
    /// to remove — and it would look like bundling worked on any dev machine.
    func testPassesCarabinerBinWhenBundleHasOne() {
        let binDir = NSTemporaryDirectory() + "carabiner-bin-\(UUID().uuidString)"
        try! FileManager.default.createDirectory(atPath: binDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: binDir) }

        let stub = writeStub("echo \"  ✓ ${CARABINER_BIN:-UNSET}\"; exit 0")
        var runner = GrabRunner(executable: stub)
        runner.binDirectory = binDir
        let result = runner.run(url: "https://x/y")

        XCTAssertTrue(result.ok)
        XCTAssertEqual(result.message, binDir)
    }

    /// With no bundled bin directory the variable must be absent, not empty: an empty
    /// entry in PATH means the current directory, so the script would run whatever
    /// ./yt-dlp happened to be in the folder the hotkey fired from.
    func testOmitsCarabinerBinWhenNoneBundled() {
        let stub = writeStub("echo \"  ✓ ${CARABINER_BIN-ABSENT}\"; exit 0")
        var runner = GrabRunner(executable: stub)
        runner.binDirectory = nil
        let result = runner.run(url: "https://x/y")

        XCTAssertEqual(result.message, "ABSENT")
    }

    /// Thread-safe collector: onProgress fires on GrabRunner's own background queue.
    private final class EventBox {
        private let lock = NSLock()
        private var events: [ProgressEvent] = []
        func add(_ e: ProgressEvent) { lock.lock(); events.append(e); lock.unlock() }
        func all() -> [ProgressEvent] { lock.lock(); defer { lock.unlock() }; return events }
    }

    func testProgressEventsAreReportedInOrder() {
        let stub = writeStub("""
        echo '::progress:probe' 1>&2
        echo '::progress:download:  50.0%' 1>&2
        echo '::progress:save' 1>&2
        echo '  ✓ ABC_fixed.mp4'
        exit 0
        """)
        let box = EventBox()
        var runner = GrabRunner(executable: stub)
        runner.onProgress = { box.add($0) }
        let result = runner.run(url: "https://x/y")

        XCTAssertTrue(result.ok)
        XCTAssertEqual(box.all(), [.probe, .download(percent: 50), .save])
    }

    /// `ig_video`'s hard-failure path ends in `echo "$log" >&2`, and that captured log holds
    /// every `::progress:` line that already went through `tee` — so a failed grab reports
    /// its whole download a second time. This pins *when* that replay lands: entirely before
    /// `run` returns the outcome, because `run` only returns once stderr has hit EOF. The
    /// ring is therefore told "failed" strictly after the last replayed marker, never during
    /// the ending. Anything that let stderr delivery outlive the outcome would put a dead
    /// grab's markers into a ring that has already begun to fade.
    func testFailureDumpMarkersArriveBeforeTheOutcome() {
        let stub = writeStub("""
        echo '::progress:download:  20.0%' 1>&2
        echo '::progress:download:  60.0%' 1>&2
        echo '::progress:download:  20.0%' 1>&2
        echo '::progress:download:  60.0%' 1>&2
        echo '✗ HTTP Error 403: Forbidden' 1>&2
        exit 1
        """)
        let box = EventBox()
        var runner = GrabRunner(executable: stub)
        runner.onProgress = { box.add($0) }
        let result = runner.run(url: "https://x/y")
        let atReturn = box.all()

        XCTAssertFalse(result.ok)
        XCTAssertEqual(result.message, "HTTP Error 403: Forbidden")
        // All four — the replay reaches the app rather than being filtered out. If this ever
        // drops to two, the premise above is gone and so is the reason for the assertion below.
        XCTAssertEqual(atReturn.count, 4, "the failure dump's replayed markers should reach onProgress")
        Thread.sleep(forTimeInterval: 0.2)
        XCTAssertEqual(box.all().count, atReturn.count, "a progress event arrived after run() returned")
    }

    /// The failure reason is the last stderr line. Progress markers are stderr too, so
    /// without filtering a failed grab would banner "::progress:download:87.1" instead of
    /// what gallery-dl actually said — destroying the diagnostics that exist precisely
    /// because a notification is the one place you cannot go and read the terminal.
    func testProgressLineIsNeverTheFailureReason() {
        let stub = writeStub("""
        echo '✗ login required — cookies expired?' 1>&2
        echo '::progress:download:  87.1%' 1>&2
        exit 1
        """)
        let result = GrabRunner(executable: stub).run(url: "https://x/y")
        XCTAssertFalse(result.ok)
        XCTAssertEqual(result.message, "login required — cookies expired?")
    }

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

    /// The multi-file return is a *separate* `GrabResult(...)` construction from the
    /// single-file one — `testFromMarkerIsCapturedAsUser` only exercises the latter, so it
    /// cannot catch a `user: user` that goes missing from just this branch. A carousel is
    /// exactly the case that hits this path in practice.
    func testFromMarkerSurvivesTheMultiFileSummary() {
        let stub = writeStub("""
        echo '::progress:from:@offpiste.mcg' 1>&2
        echo '  ✓ ABC_s1.jpg'
        echo '  ✓ ABC_s2.jpg'
        exit 0
        """)
        let result = GrabRunner(executable: stub).run(url: "https://x/y")
        XCTAssertTrue(result.ok)
        XCTAssertEqual(result.message, "2 files")
        XCTAssertEqual(result.user, "@offpiste.mcg")
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

    // MARK: - isCookieReadFailure (pure)
    //
    // The measured, real yt-dlp error (2026-08-13, Safari cookies, Full Disk Access denied):
    //   ERROR: [Errno 1] Operation not permitted:
    //     '~/Library/Containers/com.apple.Safari/Data/Library/Cookies/Cookies.binarycookies'

    func testRecognisesTheMeasuredSafariCookieError() {
        let log = "ERROR: [Errno 1] Operation not permitted:\n" +
                  "  '~/Library/Containers/com.apple.Safari/Data/Library/Cookies/Cookies.binarycookies'"
        XCTAssertTrue(isCookieReadFailure(inRawLog: log))
    }

    /// A permission error on some OTHER file (the output directory, say) must not be
    /// mistaken for a cookie problem — only the specific cookie file name counts.
    func testUnrelatedPermissionErrorIsNotACookieFailure() {
        let log = "ERROR: [Errno 1] Operation not permitted: '/Users/x/Downloads/out.mp4'"
        XCTAssertFalse(isCookieReadFailure(inRawLog: log))
    }

    /// A failure that mentions cookies but isn't a permission error (expired login) must
    /// not be mistaken for the FDA case — retrying with Chrome wouldn't fix a stale session.
    func testExpiredCookiesWithoutPermissionErrorIsNotACookieReadFailure() {
        XCTAssertFalse(isCookieReadFailure(inRawLog: "ERROR: login required — cookies expired?"))
    }

    // MARK: - shouldRetryWithChrome (pure)

    func testRetriesOnlySafariAndOnlyACookieReadFailure() {
        let cookieFailure = GrabResult(ok: false, message: "download failed.", cookieReadFailure: true)
        XCTAssertTrue(shouldRetryWithChrome(browser: .safari, result: cookieFailure))
    }

    /// The post being deleted (or private, or any other real failure) must NOT be retried —
    /// silently re-trying against a different browser's session would hide a genuine error
    /// behind what looks like a random extra delay, or worse, mask it if Chrome happens to
    /// also fail for an unrelated reason.
    func testNonCookieFailureIsNotRetried() {
        let deletedPost = GrabResult(ok: false, message: "download failed.", cookieReadFailure: false)
        XCTAssertFalse(shouldRetryWithChrome(browser: .safari, result: deletedPost))
    }

    /// Chrome's cookie jar is plain-readable — there is nothing this retry could fix for
    /// Chrome, so it must never fire there even if `cookieReadFailure` were somehow true.
    func testChromeIsNeverRetried() {
        let result = GrabResult(ok: false, message: "download failed.", cookieReadFailure: true)
        XCTAssertFalse(shouldRetryWithChrome(browser: .chrome, result: result))
    }

    func testSuccessIsNeverRetried() {
        let result = GrabResult(ok: true, message: "ABC_fixed.mp4", cookieReadFailure: true)
        XCTAssertFalse(shouldRetryWithChrome(browser: .safari, result: result))
    }

    func testFullDiskAccessDeniedResultNamesTheRealGrant() {
        let result = fullDiskAccessDeniedResult()
        XCTAssertFalse(result.ok)
        XCTAssertTrue(result.message.contains("Full Disk Access"))
    }

    // MARK: - the retry wired end-to-end through run(url:)
    //
    // These exercise the actual GrabRunner.run(url:) retry, not just the pure decision —
    // the policy function alone can't catch a wiring bug (wrong browser copied into the
    // retry, retry never actually invoked, etc).

    /// The stub only succeeds when it sees `CARABINER_BROWSER=chrome`; it fails with the
    /// exact measured cookie error otherwise. Starting the runner on `.safari` must still
    /// end in success, because `run(url:)` retries with Chrome transparently.
    private func writeCookieAwareStub() -> String {
        writeStub("""
        if [ "${CARABINER_BROWSER:-}" = "chrome" ]; then
          echo '  ✓ ABC_fixed.mp4'
          exit 0
        fi
        echo "ERROR: [Errno 1] Operation not permitted:" 1>&2
        echo "  '~/Library/Containers/com.apple.Safari/Data/Library/Cookies/Cookies.binarycookies'" 1>&2
        echo '✗ download failed.' 1>&2
        exit 1
        """)
    }

    func testSafariCookieFailureTransparentlyRetriesAndSucceedsWithChrome() {
        let stub = writeCookieAwareStub()
        let result = GrabRunner(executable: stub, browser: .safari).run(url: "https://x/y")
        XCTAssertTrue(result.ok)
        XCTAssertEqual(result.message, "ABC_fixed.mp4")
    }

    /// Starting on Chrome must never retry — the stub only succeeds for `chrome`, so if this
    /// somehow retried it would still pass; a marker file is how the test proves it did NOT.
    func testChromeCookieFailureIsNotRetried() {
        let stub = writeStub("""
        echo '✗ private account' 1>&2
        exit 1
        """)
        let result = GrabRunner(executable: stub, browser: .chrome).run(url: "https://x/y")
        XCTAssertFalse(result.ok)
        XCTAssertEqual(result.message, "private account")
    }

    /// A Safari failure that is NOT a cookie-read problem (a deleted post, say) must reach
    /// the user as-is — not retried, not reworded.
    func testSafariNonCookieFailureIsSurfacedUnchanged() {
        let stub = writeStub("""
        echo '✗ this post is no longer available' 1>&2
        exit 1
        """)
        let result = GrabRunner(executable: stub, browser: .safari).run(url: "https://x/y")
        XCTAssertFalse(result.ok)
        XCTAssertEqual(result.message, "this post is no longer available")
    }

    /// If even the Chrome retry fails, the user must see "Full Disk Access" — never the raw
    /// "Operation not permitted" on a path nobody recognises.
    func testWhenChromeRetryAlsoFailsTheMessageNamesFullDiskAccess() {
        let stub = writeStub("""
        echo "ERROR: [Errno 1] Operation not permitted:" 1>&2
        echo "  '~/Library/Containers/com.apple.Safari/Data/Library/Cookies/Cookies.binarycookies'" 1>&2
        echo '✗ download failed.' 1>&2
        exit 1
        """)
        let result = GrabRunner(executable: stub, browser: .safari).run(url: "https://x/y")
        XCTAssertFalse(result.ok)
        XCTAssertTrue(result.message.contains("Full Disk Access"), "got: \(result.message)")
    }

    // MARK: - usedFallbackBrowser (Finding 4, review fix round 1)
    //
    // A silent fallback is an honesty problem: the caller needs to know a DIFFERENT
    // browser's session actually produced the result, because it can mean a different
    // Instagram account.

    func testSuccessfulRetryFlagsTheFallbackBrowser() {
        let stub = writeCookieAwareStub()
        let result = GrabRunner(executable: stub, browser: .safari).run(url: "https://x/y")
        XCTAssertTrue(result.ok)
        XCTAssertEqual(result.usedFallbackBrowser, .chrome)
    }

    /// The common case — no retry ever happened — must not claim one did.
    func testOrdinarySuccessDoesNotFlagAFallbackBrowser() {
        let stub = writeStub("echo '  ✓ ABC_fixed.mp4'; exit 0")
        let result = GrabRunner(executable: stub, browser: .chrome).run(url: "https://x/y")
        XCTAssertTrue(result.ok)
        XCTAssertNil(result.usedFallbackBrowser)
    }

    /// A Safari grab that succeeds on its OWN cookies (no retry needed) must not be
    /// mislabelled as having used a fallback.
    func testSafariSuccessWithoutRetryDoesNotFlagAFallbackBrowser() {
        let stub = writeStub("echo '  ✓ ABC_fixed.mp4'; exit 0")
        let result = GrabRunner(executable: stub, browser: .safari).run(url: "https://x/y")
        XCTAssertTrue(result.ok)
        XCTAssertNil(result.usedFallbackBrowser)
    }

    // MARK: - watchdogPaused(after:previouslyPaused:) / watchdogHasExpired (pure, Finding 1)

    func testPromptPausesFromUnpaused() {
        XCTAssertTrue(watchdogPaused(after: .prompt, previouslyPaused: false))
    }

    func testPromptStaysPausedWhenAlreadyPaused() {
        XCTAssertTrue(watchdogPaused(after: .prompt, previouslyPaused: true))
    }

    /// Every non-prompt event resumes the ordinary clock — the human answered the dialog,
    /// whatever the engine reports next. Mirrors GrabServerTests'
    /// testEveryNonPromptEventResumesWhenOnTheBackstop for the exact same reason: this
    /// reuses that same decision function.
    func testAnyOtherEventResumesFromPaused() {
        let events: [ProgressEvent] = [.probe, .download(percent: 50), .item(index: 1, total: 3), .convert(.remux), .save]
        for event in events {
            XCTAssertFalse(watchdogPaused(after: event, previouslyPaused: true),
                           "\(event) must resume the ordinary clock")
        }
    }

    /// Raw stderr bytes that didn't parse as a marker (`nil`) are still activity, but they
    /// must not themselves change the paused/unpaused regime — only a real `.prompt` or a
    /// real non-prompt event does that.
    func testRawOutputWithNoEventLeavesPausedStateUnchanged() {
        XCTAssertFalse(watchdogPaused(after: nil, previouslyPaused: false))
        XCTAssertTrue(watchdogPaused(after: nil, previouslyPaused: true))
    }

    func testHasExpiredUsesTheShortBoundWhenNotPaused() {
        XCTAssertFalse(watchdogHasExpired(secondsSinceActivity: 9, paused: false, inactivityBound: 10, promptBound: 100))
        XCTAssertTrue(watchdogHasExpired(secondsSinceActivity: 10, paused: false, inactivityBound: 10, promptBound: 100))
    }

    /// The exact property Finding 1 asks to be pinned: `.prompt` does not start the SHORT
    /// clock. 9.5s of silence would have expired the ordinary 10s bound, but paused=true
    /// selects the much longer prompt bound instead, so it must still read as alive.
    func testHasExpiredUsesTheLongBoundWhenPaused() {
        XCTAssertFalse(watchdogHasExpired(secondsSinceActivity: 9.5, paused: true, inactivityBound: 10, promptBound: 100))
        XCTAssertTrue(watchdogHasExpired(secondsSinceActivity: 100, paused: true, inactivityBound: 10, promptBound: 100))
    }

    // MARK: - the watchdog wired end-to-end through run(url:) (Finding 1)
    //
    // Real Process, real timer, tiny (but not TOO tiny) bounds — the defaults are minutes
    // (GrabServer's own battle-tested numbers, see the doc comment on
    // watchdogInactivityBound) so these run fast without weakening what they prove. Every
    // bound below is kept comfortably above two real sources of jitter: the watchdog's
    // own fixed 0.25s poll interval (a bound smaller than that risks tripping on the
    // FIRST tick before the child has even had a chance to produce its first byte), and
    // real process-launch latency under load — `testPromptSuspendsTheShortBoundWhileWaitingOnTheDialog`
    // measured flaky at 0.2s/0.5s when the full suite ran under load and passed every time
    // in isolation; these margins are what fixed it, not a fluke worth re-tightening.

    /// A stream of progress markers, each well inside the bound, must keep the grab alive
    /// for a total duration that comfortably EXCEEDS the bound — proving this is an
    /// inactivity clock that resets on each event, not a total-duration cap.
    func testStreamOfProgressKeepsTheGrabAlive() {
        let stub = writeStub("""
        for i in 1 2 3 4 5; do
          echo "::progress:download:  ${i}0.0%" 1>&2
          sleep 0.15
        done
        echo '  ✓ ABC_fixed.mp4'
        exit 0
        """)
        var runner = GrabRunner(executable: stub)
        runner.watchdogInactivityBound = 0.6   // total run time (~0.75s) exceeds this
        runner.watchdogPromptBound = 0.6
        let result = runner.run(url: "https://x/y")
        XCTAssertTrue(result.ok, "got: \(result.message)")
    }

    /// A child that goes completely silent (no markers, no output at all) past the
    /// inactivity bound is killed and reported as a plain failure — not left to hang.
    /// `wait(timeout:)` is generous, but the point of the assertion is that this returns
    /// well before the 10s sleep finishes, not anywhere near that timeout — proving the
    /// child was actually terminated, not merely outlasted.
    func testSilentChildIsKilledAndReportedAsFailure() {
        let stub = writeStub("sleep 10; echo '  ✓ should never be seen'; exit 0")
        var runner = GrabRunner(executable: stub)
        runner.watchdogInactivityBound = 0.6
        runner.watchdogPromptBound = 0.6

        let box = ResultBox()
        let done = expectation(description: "watchdog kills the hung child")
        let start = Date()
        DispatchQueue.global(qos: .userInitiated).async {
            box.set(runner.run(url: "https://x/y"))
            done.fulfill()
        }
        wait(for: [done], timeout: 8)

        XCTAssertLessThan(Date().timeIntervalSince(start), 5, "the watchdog should have killed the child well before the 10s sleep finished")
        let result = box.get()
        XCTAssertEqual(result?.ok, false)
        XCTAssertEqual(result?.message, "Carabiner stopped responding and the grab was cancelled")
    }

    /// The exact scenario Finding 1 names: `.prompt` fires, then the child goes quiet for
    /// LONGER than the ordinary inactivity bound but still well under the (generous, for
    /// this test) prompt bound — a human reading the carousel dialog, not a stalled grab.
    /// Proves `.prompt` swaps in the long bound rather than merely resetting the clock on
    /// the short one (which a gap this long would still fail).
    func testPromptSuspendsTheShortBoundWhileWaitingOnTheDialog() {
        let stub = writeStub("""
        echo '::progress:prompt' 1>&2
        sleep 1.2
        echo '  ✓ ABC_fixed.mp4'
        exit 0
        """)
        var runner = GrabRunner(executable: stub)
        runner.watchdogInactivityBound = 0.6   // the 1.2s prompt-wait alone would trip this
        runner.watchdogPromptBound = 10.0      // ...but not this
        let result = runner.run(url: "https://x/y")
        XCTAssertTrue(result.ok, "got: \(result.message)")
    }

    /// The prompt bound is generous, not infinite: a child that hangs on/after the dialog
    /// and never says anything else again still eventually loses its process, exactly as
    /// GrabServer's own `pausedTimeout` backstop is finite (never `.infinity`) rather than
    /// an unbounded pause.
    func testPromptBackstopIsFiniteNotUnbounded() {
        let stub = writeStub("""
        echo '::progress:prompt' 1>&2
        sleep 10
        echo '  ✓ should never be seen'
        exit 0
        """)
        var runner = GrabRunner(executable: stub)
        runner.watchdogInactivityBound = 0.6
        runner.watchdogPromptBound = 1.2

        let box = ResultBox()
        let done = expectation(description: "the prompt backstop still eventually fires")
        DispatchQueue.global(qos: .userInitiated).async {
            box.set(runner.run(url: "https://x/y"))
            done.fulfill()
        }
        wait(for: [done], timeout: 8)

        XCTAssertEqual(box.get()?.ok, false)
        XCTAssertEqual(box.get()?.message, "Carabiner stopped responding and the grab was cancelled")
    }

    /// A grab whose watchdog fired must not be mistaken for a cookie problem — it has its
    /// own distinct message and `cookieReadFailure` defaults to false, so
    /// `shouldRetryWithChrome` never fires a pointless Chrome retry against a child that
    /// is already dead.
    func testWatchdogFailureIsNeverTreatedAsACookieFailure() {
        let stub = writeStub("sleep 10; exit 0")
        var runner = GrabRunner(executable: stub, browser: .safari)
        runner.watchdogInactivityBound = 0.6
        runner.watchdogPromptBound = 0.6

        let box = ResultBox()
        let done = expectation(description: "watchdog result carries no cookie-failure flag")
        DispatchQueue.global(qos: .userInitiated).async {
            box.set(runner.run(url: "https://x/y"))
            done.fulfill()
        }
        wait(for: [done], timeout: 8)
        XCTAssertEqual(box.get()?.cookieReadFailure, false)
    }
}
