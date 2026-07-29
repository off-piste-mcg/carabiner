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
}
