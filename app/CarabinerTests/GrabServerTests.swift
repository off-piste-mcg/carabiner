import XCTest
@testable import Carabiner

/// `GrabServer`'s I/O — accepting connections, scheduling/cancelling deadlines on a real
/// `NWConnection` — needs a live socket and isn't covered here (same limitation Task 6
/// noted for the original 5s deadline: verified indirectly, by requests completing
/// normally). What IS pure, and is worth pinning: the relative properties the deadline
/// bounds must hold, and the full backstop/resume decision that governs the streaming
/// deadline around the carousel dialog (Finding 2, fix round 1; Finding 1, fix round 2).
final class GrabServerTests: XCTestCase {
    // MARK: - deadline(forStreamingGrab:) / pausedDeadline()

    func testStreamingDeadlineIsStrictlyLongerThanTheOrdinaryOne() {
        // The property that actually matters: whatever the two constants are tuned to
        // later, a streaming grab must never be held to the SHORTER bound — that would
        // silently reintroduce the mid-grab disconnect this task exists to fix. (The two
        // constants themselves are deliberately NOT pinned as separate tests — restating
        // "5" and "600" is a change-detector with no signal a retune wouldn't just break.)
        XCTAssertGreaterThan(GrabServer.deadline(forStreamingGrab: true),
                             GrabServer.deadline(forStreamingGrab: false))
    }

    func testPausedBackstopIsFiniteAndLongerThanTheStreamingDeadline() {
        // Fix round 2, Finding 1: pausing on the carousel dialog must NOT mean "no bound
        // at all" — round 1 cancelled the deadline outright on `.prompt`, which left a
        // connection whose child hangs on/after the dialog open for the life of the app
        // (the exact fd leak Task 6 closed, reinstated). This pins the two properties
        // that must hold regardless of exact tuning: the backstop is strictly more
        // generous than the ordinary streaming deadline (a human on a dialog should not
        // be worse off than a machine mid-download) AND it is finite (a future change
        // that quietly reverts to "cancel outright" — i.e. no real bound at all — fails
        // here rather than only being caught by someone leaving a dialog open for an
        // hour). Deliberately not a literal `== 3600` assertion, for the same
        // change-detector reason `streamingTimeout`/`connectionTimeout` aren't pinned by
        // value either.
        XCTAssertGreaterThan(GrabServer.pausedDeadline(), GrabServer.deadline(forStreamingGrab: true))
        XCTAssertLessThan(GrabServer.pausedDeadline(), .infinity)
    }

    // MARK: - deadlineAction(for:paused:) — Finding 2, fix round 1; Finding 1, fix round 2

    func testPromptArmsTheBackstopWhenNotAlreadyOnIt() {
        XCTAssertEqual(GrabServer.deadlineAction(for: .prompt, paused: false), .backstop)
    }

    func testPromptWhileAlreadyOnTheBackstopDoesNothing() {
        // Defensive: the engine isn't expected to emit `.prompt` twice in a row, but if
        // it did, there is nothing further to arm.
        XCTAssertEqual(GrabServer.deadlineAction(for: .prompt, paused: true), .none)
    }

    func testEveryNonPromptEventResumesWhenOnTheBackstop() {
        // The human answered the dialog — whatever machine-driven event comes next
        // (probe, download, item, convert, save) must resume the ordinary streaming
        // clock. Exercised across every non-prompt case in ProgressEvent, not just one,
        // since the decision is "not .prompt", not "specifically .download".
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
                           "\(event) on the backstop must resume the streaming deadline")
        }
    }

    func testEveryNonPromptEventDoesNothingWhenNotOnTheBackstop() {
        // Symmetric case: off the backstop, ordinary progress events must not touch the
        // deadline at all — only `.prompt` (arm the backstop) and "non-prompt while on
        // the backstop" (resume) are meaningful transitions.
        let events: [ProgressEvent] = [
            .probe,
            .download(percent: 50),
            .item(index: 2, total: 5),
            .convert(.remux),
            .save,
        ]
        for event in events {
            XCTAssertEqual(GrabServer.deadlineAction(for: event, paused: false), .none,
                           "\(event) off the backstop must leave the deadline alone")
        }
    }

    func testPromptThenSilenceStillTerminates() {
        // The exact sequence Finding 1 was about: `.prompt` fires and then nothing ever
        // arrives again (the child hangs on/after the dialog). This can't observe a real
        // NWConnection actually closing — that needs a live socket — but it pins the pure
        // half of the guarantee: after `.prompt`, the connection is ALWAYS on some finite
        // deadline, never on none. `deadlineAction` only ever returns `.none` here when
        // there is already a real timer running from a previous `.backstop`/`.resume`;
        // it is never the terminal state of "no timer will ever fire again."
        let action = GrabServer.deadlineAction(for: .prompt, paused: false)
        XCTAssertEqual(action, .backstop, "prompt must arm a real, finite backstop — never leave the connection unbounded")
        XCTAssertLessThan(GrabServer.pausedDeadline(), .infinity, "the backstop armed above must itself be finite")
    }
}
