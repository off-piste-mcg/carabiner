import XCTest
@testable import Carabiner

final class TabReaderTests: XCTestCase {
    let r = TabReader(browser: .chrome)

    func testIsURL() {
        XCTAssertTrue(r.isURL("https://www.instagram.com/reel/x/"))
        XCTAssertTrue(r.isURL("http://localhost:3000"))
        XCTAssertFalse(r.isURL("not a url"))
        XCTAssertFalse(r.isURL(""))
    }

    func testResolvePrefersArgument() {
        let out = r.resolveURL(argument: "https://a.com/x",
                               tabURL: { "https://tab.com/y" },
                               clipboard: { "https://clip.com/z" })
        XCTAssertEqual(out, "https://a.com/x")
    }

    func testResolveFallsBackToTabThenClipboard() {
        XCTAssertEqual(r.resolveURL(argument: nil, tabURL: { "https://tab.com/y" }, clipboard: { "https://clip.com/z" }), "https://tab.com/y")
        XCTAssertEqual(r.resolveURL(argument: nil, tabURL: { nil }, clipboard: { "https://clip.com/z" }), "https://clip.com/z")
        XCTAssertNil(r.resolveURL(argument: nil, tabURL: { "junk" }, clipboard: { nil }))
    }
}
