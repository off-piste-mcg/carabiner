import XCTest
@testable import Carabiner

/// `GrabServer`'s I/O — accepting connections, scheduling/cancelling deadlines on a real
/// `NWConnection` — needs a live socket and isn't covered here (same limitation Task 6
/// noted for the original 5s deadline: verified indirectly, by requests completing
/// normally). What IS pure, and is worth pinning: the relative property the streaming
/// deadline must hold, and the full pause/resume decision that governs it around the
/// carousel dialog (Finding 2, fix round 1).
final class GrabServerTests: XCTestCase {
    // MARK: - deadline(forStreamingGrab:)

    func testStreamingDeadlineIsStrictlyLongerThanTheOrdinaryOne() {
        // The property that actually matters: whatever the two constants are tuned to
        // later, a streaming grab must never be held to the SHORTER bound — that would
        // silently reintroduce the mid-grab disconnect this task exists to fix. (The two
        // constants themselves are deliberately NOT pinned as separate tests — restating
        // "5" and "600" is a change-detector with no signal a retune wouldn't just break.)
        XCTAssertGreaterThan(GrabServer.deadline(forStreamingGrab: true),
                             GrabServer.deadline(forStreamingGrab: false))
    }

    // MARK: - deadlineAction(for:paused:) — Finding 2, fix round 1

    func testPromptPausesWhenNotAlreadyPaused() {
        XCTAssertEqual(GrabServer.deadlineAction(for: .prompt, paused: false), .pause)
    }

    func testPromptWhileAlreadyPausedDoesNothing() {
        // Defensive: the engine isn't expected to emit `.prompt` twice in a row, but if
        // it did, there is nothing further to pause.
        XCTAssertEqual(GrabServer.deadlineAction(for: .prompt, paused: true), .none)
    }

    func testEveryNonPromptEventResumesWhenPaused() {
        // The human answered the dialog — whatever machine-driven event comes next
        // (probe, download, item, convert, save) must resume the clock. Exercised across
        // every non-prompt case in ProgressEvent, not just one, since the decision is
        // "not .prompt", not "specifically .download".
        let events: [ProgressEvent] = [
            .probe,
            .download(percent: 50),
            .download(percent: nil),
            .item(index: 2, total: 5),
            .convert(.remux),
            .convert(.encode),
            .save,
        ]
        for event in events {
            XCTAssertEqual(GrabServer.deadlineAction(for: event, paused: true), .resume,
                           "\(event) while paused must resume the deadline")
        }
    }

    func testEveryNonPromptEventDoesNothingWhenNotPaused() {
        // Symmetric case: with no active pause, ordinary progress events must not touch
        // the deadline at all — only `.prompt` (pause) and "non-prompt while paused"
        // (resume) are meaningful transitions.
        let events: [ProgressEvent] = [
            .probe,
            .download(percent: 50),
            .item(index: 2, total: 5),
            .convert(.remux),
            .save,
        ]
        for event in events {
            XCTAssertEqual(GrabServer.deadlineAction(for: event, paused: false), .none,
                           "\(event) while not paused must leave the deadline alone")
        }
    }
}
