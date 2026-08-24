import XCTest
@testable import Carabiner

final class DockOpenActionTests: XCTestCase {
    func testCarabinerSchemeIsLaunchOnly() {
        XCTAssertEqual(dockOpenAction(for: URL(string: "carabiner://launch")!), .launchOnly)
        // Case-insensitive, like every scheme.
        XCTAssertEqual(dockOpenAction(for: URL(string: "CARABINER://launch")!), .launchOnly)
    }

    func testAllowlistedHTTPSStartsAGrab() {
        XCTAssertEqual(dockOpenAction(for: URL(string: "https://www.instagram.com/p/ABC123/")!),
                       .grab(url: "https://www.instagram.com/p/ABC123/"))
        XCTAssertEqual(dockOpenAction(for: URL(string: "https://youtu.be/xyz")!),
                       .grab(url: "https://youtu.be/xyz"))
    }

    func testPlainHTTPIsIgnored() {
        XCTAssertEqual(dockOpenAction(for: URL(string: "http://www.instagram.com/p/ABC123/")!), .ignore)
    }

    func testOffAllowlistHostIsIgnored() {
        XCTAssertEqual(dockOpenAction(for: URL(string: "https://example.com/x")!), .ignore)
        // The same lookalike GrabGate's own tests pin — the Dock drop must not widen it.
        XCTAssertEqual(dockOpenAction(for: URL(string: "https://instagram.com.evil.example/p/A/")!), .ignore)
    }

    func testFileURLIsIgnored() {
        XCTAssertEqual(dockOpenAction(for: URL(fileURLWithPath: "/tmp/x.mp4")), .ignore)
    }
}
