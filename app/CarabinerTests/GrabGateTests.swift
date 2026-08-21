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
        guard case .rejected(let status, let reason) = GrabGate.check(origin: "https://evil.example/chrome-extension://x", url: post)
        else { return XCTFail("scheme must be a prefix, not a substring") }
        XCTAssertEqual(status, 403)
        XCTAssertEqual(reason, "origin not an extension")
    }

    // A CRLF-injected origin must not pass the prefix check just because it starts with
    // an allowed scheme: `chrome-extension://a\r\nAccess-Control-Allow-Credentials: true`
    // would, if accepted, hand the listener a value it could echo straight into an
    // `Access-Control-Allow-Origin` response header. The character-set check rejects it
    // on the CR (and independently on the LF, and independently on the space) — any one
    // of those alone would be enough, so this single string exercises the whole class of
    // disallowed characters (control chars AND whitespace) in one hostile input.
    func testRejectsOriginWithControlCharacters() {
        guard case .rejected(let status, let reason) = GrabGate.check(
            origin: "chrome-extension://a\r\nAccess-Control-Allow-Credentials: true", url: post)
        else { return XCTFail("an origin with CR/LF/whitespace must be rejected") }
        XCTAssertEqual(status, 403)
        XCTAssertEqual(reason, "origin not an extension")
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
        guard case .rejected(let status, let reason) = GrabGate.check(origin: "chrome-extension://a",
                                              url: "https://instagram.com.evil.example/p/C1/")
        else { return XCTFail("host must match on a domain boundary") }
        XCTAssertEqual(status, 400)
        XCTAssertEqual(reason, "host not allowed")
    }
    func testRejectsNonHttpScheme() {
        guard case .rejected(let status, let reason) = GrabGate.check(origin: "chrome-extension://a", url: "file:///etc/passwd")
        else { return XCTFail("non-http(s) must be rejected") }
        XCTAssertEqual(status, 400)
        XCTAssertEqual(reason, "unusable url")
    }
    func testRejectsMissingUrl() {
        guard case .rejected(let status, _) = GrabGate.check(origin: "chrome-extension://a", url: nil)
        else { return XCTFail("a missing url must be rejected") }
        XCTAssertEqual(status, 400)
    }

    // Plain http is deliberately not allowed: an extension only ever originates these
    // four hosts over https, and http would widen the redirect seam (see the doc comment
    // on GrabGate: the gate cannot see where a redirect goes) to any on-path attacker.
    func testRejectsPlainHttp() {
        guard case .rejected(let status, let reason) = GrabGate.check(origin: "chrome-extension://a",
                                              url: "http://www.instagram.com/p/C1a2b3c4d5e/")
        else { return XCTFail("plain http must be rejected even for an allowed host") }
        XCTAssertEqual(status, 400)
        XCTAssertEqual(reason, "unusable url")
    }

    // --- extra hostile inputs not in the brief ---

    // Classic host-spoofing trick: everything before '@' is userinfo, not host. A gate
    // that scanned the string for "instagram.com" rather than parsing it properly would
    // be fooled into thinking this points at Instagram; it actually points at evil.example.
    func testRejectsUserinfoHostSpoof() {
        guard case .rejected(let status, let reason) = GrabGate.check(origin: "chrome-extension://a",
                                              url: "https://instagram.com@evil.example/p/C1/")
        else { return XCTFail("host must come from the URL's host component, not credentials before @") }
        XCTAssertEqual(status, 400)
        XCTAssertEqual(reason, "host not allowed")
    }

    // Scheme comparison must be case-insensitive on both sides of the gate. NOTE: this
    // pins the value empirically observed from `URL(string:).absoluteString` on this
    // Foundation/SDK version (macOS SDK 26.5, Swift 6.3.2) rather than an assumption —
    // verified with a standalone script before writing this assertion. Foundation does
    // NOT lower-case the scheme when re-serialising: "HTTPS://..." round-trips as
    // "HTTPS://...", not "https://...". Re-verify this if the deployment target's
    // Foundation ever changes, per gotcha #23's lesson about pinning claims to the real
    // behaviour rather than to what seems like it should be true.
    func testAcceptsUppercaseScheme() {
        let u = "HTTPS://www.instagram.com/p/C1a2b3c4d5e/"
        XCTAssertEqual(GrabGate.check(origin: "chrome-extension://a", url: u), .ok(url: u))
    }

    // FINDING 1 fix, pinned with a test: the gate must return what URL parsed and
    // re-serialised, not the caller's raw bytes — otherwise a CRLF survives untouched and
    // becomes header injection the moment the listener echoes an accepted value into a
    // response header. `URL.absoluteString` always percent-encodes what it can't hold
    // literally, so the returned value carries `%0D%0A`, never a literal CR/LF. Foundation
    // version matters here (pre-WHATWG parsers returned nil for inputs like this), which is
    // exactly why this is pinned by a real test rather than asserted from documentation.
    func testAcceptedUrlIsTheParsedFormNotTheRawBytes() {
        let raw = "https://www.instagram.com/p/C1/\r\nX-Injected: 1"
        XCTAssertEqual(GrabGate.check(origin: "chrome-extension://a", url: raw),
                       .ok(url: "https://www.instagram.com/p/C1/%0D%0AX-Injected:%201"))
    }

    // FINDING 2 fix, replacing the deleted testAcceptsOriginWithTrailingPath (that test
    // enshrined behaviour no real browser produces, and widened rather than narrowed the
    // gate). A real Origin header is scheme + host [+ port], never a path — reject one
    // that has a path component the same way a CRLF-bearing origin is rejected: outside
    // the allowed character set.
    func testRejectsOriginWithPath() {
        guard case .rejected(let status, let reason) = GrabGate.check(
            origin: "chrome-extension://abcdefghijklmnop/background.html", url: post)
        else { return XCTFail("an origin with a path must be rejected — Origin never has one") }
        XCTAssertEqual(status, 403)
        XCTAssertEqual(reason, "origin not an extension")
    }

    // --- checkOrigin, the single source of truth Finding 1 introduced ---
    // GrabServer's OPTIONS preflight used to re-implement half of this check by hand (a
    // bare scheme-prefix test with none of isWellFormedOrigin's character-set
    // validation) and echo the result straight into a response header. These pin that
    // `checkOrigin` — now the ONLY thing either call site consults — agrees with `check`
    // in both directions, including the exact injection shapes the preflight path used
    // to let through.
    func testCheckOriginAcceptsExtension() {
        XCTAssertEqual(GrabGate.checkOrigin("chrome-extension://abcdefghijklmnop"),
                       "chrome-extension://abcdefghijklmnop")
        XCTAssertEqual(GrabGate.checkOrigin("safari-web-extension://1E7A-UUID"),
                       "safari-web-extension://1E7A-UUID")
    }
    func testCheckOriginRejectsWebPage() {
        XCTAssertNil(GrabGate.checkOrigin("https://www.instagram.com"))
    }
    func testCheckOriginRejectsMissing() {
        XCTAssertNil(GrabGate.checkOrigin(nil))
    }
    // A bare CR with no matching LF: the preflight path's old hand-rolled check
    // (`origin.hasPrefix(scheme)`) would have passed this straight through to be echoed
    // into `Access-Control-Allow-Origin` — CR alone is outside `originHostCharacters`,
    // so `checkOrigin` (routing through `isWellFormedOrigin`) rejects it.
    func testCheckOriginRejectsBareCR() {
        XCTAssertNil(GrabGate.checkOrigin("chrome-extension://a\rinjected"))
    }
    // Same shape, bare LF: the two characters that together form the CRLF a response
    // header is terminated by — each alone must already be enough to reject, not just
    // the pair.
    func testCheckOriginRejectsBareLF() {
        XCTAssertNil(GrabGate.checkOrigin("chrome-extension://a\ninjected"))
    }

    // `checkURL` is `check`'s URL half, extracted because the main window's Grab button
    // and the Dock drop now consult it without an Origin in sight. These pin it directly
    // — the origin-free surfaces must enforce exactly the rules `check`'s own tests
    // already pin through the combined path.
    func testCheckURLAcceptsAllowlistedHTTPS() {
        XCTAssertEqual(GrabGate.checkURL("https://www.instagram.com/p/ABC/"),
                       .ok(url: "https://www.instagram.com/p/ABC/"))
    }
    func testCheckURLRejectsPlainHTTP() {
        XCTAssertEqual(GrabGate.checkURL("http://www.instagram.com/p/ABC/"),
                       .rejected(status: 400, reason: "unusable url"))
    }
    func testCheckURLRejectsOffAllowlistAndLookalike() {
        XCTAssertEqual(GrabGate.checkURL("https://example.com/x"),
                       .rejected(status: 400, reason: "host not allowed"))
        XCTAssertEqual(GrabGate.checkURL("https://instagram.com.evil.example/p/A/"),
                       .rejected(status: 400, reason: "host not allowed"))
    }
    func testCheckURLRejectsNilAndJunk() {
        XCTAssertEqual(GrabGate.checkURL(nil),
                       .rejected(status: 400, reason: "unusable url"))
        XCTAssertEqual(GrabGate.checkURL("not a url"),
                       .rejected(status: 400, reason: "unusable url"))
    }
}
