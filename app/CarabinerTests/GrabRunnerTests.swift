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

    /// Cancelling the carousel prompt makes `carabiner` exit 0 having saved nothing
    /// (`cancel) info "  cancelled."; exit 0`). That must not banner as a success — nor
    /// read like a crash.
    func testExitZeroWithoutMarkerIsNotSuccess() {
        let stub = writeStub("echo 'carabiner → instagram'; echo '  cancelled.'; exit 0")
        let result = GrabRunner(executable: stub).run(url: "https://x/y")
        XCTAssertFalse(result.ok)
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

    /// stdout is the ✓ channel, and a marker has no business on it. If one ever leaks there —
    /// a stray `echo` in the script, a tool writing to the wrong stream — it must not be
    /// counted as a saved file. The stub therefore writes a marker to stdout *deliberately*,
    /// alongside two real saves: the expected answer is "2 files", and an implementation that
    /// counted the marker would say "3 files".
    ///
    /// The previous version of this test wrote the marker to stderr, which meant it asserted
    /// nothing this task changed and would have passed with the whole feature removed.
    func testStdoutMarkerIsNotCountedAsASave() {
        let stub = writeStub("""
        echo '  ✓ ABC_s1.jpg'
        echo '::progress:download:  10.0%'
        echo '  ✓ ABC_s2.jpg'
        exit 0
        """)
        let result = GrabRunner(executable: stub).run(url: "https://x/y")
        XCTAssertTrue(result.ok)
        XCTAssertEqual(result.message, "2 files")
    }
}
