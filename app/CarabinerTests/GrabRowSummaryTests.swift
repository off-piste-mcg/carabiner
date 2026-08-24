import XCTest
@testable import Carabiner

final class GrabRowSummaryTests: XCTestCase {
    func testMixedCarousel() {
        XCTAssertEqual(GrabRowSummary.text(files: ["a_s1.jpg", "b_s2.jpg", "c_fixed.mp4"]),
                       "2 IMAGES, 1 VIDEO")
    }
    func testSingularImage() {
        XCTAssertEqual(GrabRowSummary.text(files: ["a.jpg"]), "1 IMAGE")
    }
    func testPluralVideosOnly() {
        XCTAssertEqual(GrabRowSummary.text(files: ["a.mp4", "b.mov"]), "2 VIDEOS")
    }
    func testUnparsableFallsBack() {
        XCTAssertEqual(GrabRowSummary.text(files: ["saved to ~/Downloads"]),
                       "SAVED TO DOWNLOADS")
    }
    func testCaseInsensitiveExtensions() {
        XCTAssertEqual(GrabRowSummary.text(files: ["A.JPG", "B.MP4"]), "1 IMAGE, 1 VIDEO")
    }
}
