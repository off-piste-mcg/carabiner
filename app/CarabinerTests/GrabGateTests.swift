import XCTest
@testable import Carabiner

final class GrabGateTests: XCTestCase {
    let post = "https://www.instagram.com/p/C1a2b3c4d5e/"

    // --- origin, both directions ---
    func testAcceptsChromeExtensionOrigin() {
        XCTAssertEqual(GrabGate.check(origin: "chrome-extension://abcdefghijklmnop", url: post),
                       .ok(url: post))
    }
    func testAcceptsSafariExtensionOrigin() {
        XCTAssertEqual(GrabGate.check(origin: "safari-web-extension://1E7A-UUID", url: post),
                       .ok(url: post))
    }
    func testRejectsWebPageOrigin() {
        guard case .rejected(let status, _) = GrabGate.check(origin: "https://www.instagram.com", url: post)
        else { return XCTFail("a web page origin must be rejected") }
        XCTAssertEqual(status, 403)
    }
    func testRejectsMissingOrigin() {
        guard case .rejected(let status, _) = GrabGate.check(origin: nil, url: post)
        else { return XCTFail("a missing origin must be rejected") }
        XCTAssertEqual(status, 403)
    }
    func testRejectsOriginThatMerelyContainsTheScheme() {
        // https://evil.example/chrome-extension:// must not pass a substring check.
        guard case .rejected = GrabGate.check(origin: "https://evil.example/chrome-extension://x", url: post)
        else { return XCTFail("scheme must be a prefix, not a substring") }
    }

    // --- url allowlist, both directions ---
    func testAcceptsReelAndTv() {
        XCTAssertEqual(GrabGate.check(origin: "chrome-extension://a", url: "https://www.instagram.com/reel/C9/"),
                       .ok(url: "https://www.instagram.com/reel/C9/"))
        XCTAssertEqual(GrabGate.check(origin: "chrome-extension://a", url: "https://www.instagram.com/tv/C9/"),
                       .ok(url: "https://www.instagram.com/tv/C9/"))
    }
    func testAcceptsYouTubeAndPinterest() {
        for u in ["https://www.youtube.com/watch?v=abc", "https://youtu.be/abc",
                  "https://www.pinterest.com/pin/12345/"] {
            XCTAssertEqual(GrabGate.check(origin: "chrome-extension://a", url: u), .ok(url: u))
        }
    }
    func testRejectsArbitraryHost() {
        guard case .rejected(let status, _) = GrabGate.check(origin: "chrome-extension://a",
                                                            url: "https://evil.example/payload.mp4")
        else { return XCTFail("an arbitrary host must be rejected") }
        XCTAssertEqual(status, 400)
    }
    func testRejectsLookalikeHost() {
        guard case .rejected = GrabGate.check(origin: "chrome-extension://a",
                                              url: "https://instagram.com.evil.example/p/C1/")
        else { return XCTFail("host must match on a domain boundary") }
    }
    func testRejectsNonHttpScheme() {
        guard case .rejected = GrabGate.check(origin: "chrome-extension://a", url: "file:///etc/passwd")
        else { return XCTFail("non-http(s) must be rejected") }
    }
    func testRejectsMissingUrl() {
        guard case .rejected(let status, _) = GrabGate.check(origin: "chrome-extension://a", url: nil)
        else { return XCTFail("a missing url must be rejected") }
        XCTAssertEqual(status, 400)
    }

    // --- extra hostile inputs not in the brief ---

    // Classic host-spoofing trick: everything before '@' is userinfo, not host. A gate
    // that scanned the string for "instagram.com" rather than parsing it properly would
    // be fooled into thinking this points at Instagram; it actually points at evil.example.
    func testRejectsUserinfoHostSpoof() {
        guard case .rejected = GrabGate.check(origin: "chrome-extension://a",
                                              url: "https://instagram.com@evil.example/p/C1/")
        else { return XCTFail("host must come from the URL's host component, not credentials before @") }
    }

    // Scheme comparison must be case-insensitive on both sides of the gate.
    func testAcceptsUppercaseScheme() {
        let u = "HTTPS://www.instagram.com/p/C1a2b3c4d5e/"
        XCTAssertEqual(GrabGate.check(origin: "chrome-extension://a", url: u), .ok(url: u))
    }

    // An extension's origin is just scheme + host id; a path after it (e.g. from a
    // background page) must not break the prefix check.
    func testAcceptsOriginWithTrailingPath() {
        XCTAssertEqual(GrabGate.check(origin: "chrome-extension://abcdefghijklmnop/background.html", url: post),
                       .ok(url: post))
    }
}
