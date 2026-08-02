import XCTest
@testable import Carabiner

/// Which events justify a ring in the menu bar at all. The ring reads as "downloading",
/// so it must not exist while the script is merely probing the post or waiting on the
/// carousel dialog — MenuBarController only calls `ring.begin()` on the first event for
/// which this is true.
final class ProgressEventTests: XCTestCase {

    func testDownloadItemAndConvertBeginActivity() {
        XCTAssertTrue(ProgressEvent.download(percent: nil).beginsActivity)
        XCTAssertTrue(ProgressEvent.download(percent: 42).beginsActivity)
        XCTAssertTrue(ProgressEvent.item(index: 1, total: 3).beginsActivity)
        XCTAssertTrue(ProgressEvent.convert(.remux).beginsActivity)
        XCTAssertTrue(ProgressEvent.convert(.encode).beginsActivity)
    }

    /// Probe and prompt are pre-work: nothing is being downloaded, and on the prompt the
    /// script is literally waiting on the user. A ring during either is the "download
    /// already started" misread this property exists to prevent.
    func testProbeAndPromptDoNot() {
        XCTAssertFalse(ProgressEvent.probe.beginsActivity)
        XCTAssertFalse(ProgressEvent.prompt.beginsActivity)
    }

    /// The YouTube/Pinterest/generic branches emit no markers until `save` (gotcha #23's
    /// scope note). A ring that first appears at save would be a completion flourish, not
    /// download feedback — those branches simply show no ring.
    func testSaveAloneDoesNotStartARing() {
        XCTAssertFalse(ProgressEvent.save.beginsActivity)
    }
}
