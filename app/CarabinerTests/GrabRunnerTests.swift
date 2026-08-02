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
}
