import XCTest
@testable import Carabiner

/// `GrabServer`'s I/O — accepting connections, scheduling/cancelling deadlines on a real
/// `NWConnection` — needs a live socket and isn't covered here (same limitation Task 6
/// noted for the original 5s deadline: verified indirectly, by requests completing
/// normally). What IS pure, and is worth pinning, is the decision the streaming deadline
/// hinges on: which bound applies once a connection is known to be (or not be) a
/// legitimate, running `/grab`.
final class GrabServerTests: XCTestCase {
    func testOrdinaryRequestGetsTheShortDeadline() {
        XCTAssertEqual(GrabServer.deadline(forStreamingGrab: false), 5)
    }

    func testStreamingGrabGetsTheLongDeadline() {
        XCTAssertEqual(GrabServer.deadline(forStreamingGrab: true), 600)
    }

    func testStreamingDeadlineIsStrictlyLongerThanTheOrdinaryOne() {
        // The property that actually matters: whatever the two constants are tuned to
        // later, a streaming grab must never be held to the SHORTER bound — that would
        // silently reintroduce the mid-grab disconnect this task exists to fix.
        XCTAssertGreaterThan(GrabServer.deadline(forStreamingGrab: true),
                             GrabServer.deadline(forStreamingGrab: false))
    }
}
