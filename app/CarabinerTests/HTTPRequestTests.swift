import XCTest
@testable import Carabiner

/// `HTTPRequest.parse` is a pure `Data` → `HTTPRequestParseResult` function over bytes an
/// attacker (or just a buggy extension) fully controls, sitting next to `GrabGateTests`
/// and `BannerPlannerTests` in a project whose convention is that the pure layer gets
/// tested precisely because the I/O layer (`GrabServer`'s `NWListener` plumbing) cannot
/// be exercised by a unit test.
final class HTTPRequestTests: XCTestCase {
    private func data(_ s: String) -> Data { Data(s.utf8) }

    // --- the happy path ---
    func testWellFormedRequestParses() {
        let raw = "GET /health?browser=chrome HTTP/1.1\r\nOrigin: chrome-extension://abc\r\n\r\n"
        guard case .complete(let r) = HTTPRequest.parse(data(raw)) else {
            return XCTFail("a well-formed request must parse")
        }
        XCTAssertEqual(r.method, "GET")
        XCTAssertEqual(r.path, "/health")
        XCTAssertEqual(r.query["browser"], "chrome")
        XCTAssertEqual(r.origin, "chrome-extension://abc")
        XCTAssertEqual(r.body, "")
    }

    // The head/body boundary is the FIRST "\r\n\r\n" in the whole buffer. A body that
    // itself contains that four-byte sequence must not confuse the split — everything
    // after the first occurrence is body, verbatim, however many more "\r\n\r\n"s it
    // contains, because header lines can never legally contain one.
    func testBodyContainingCRLFCRLF() {
        let body = "part1\r\n\r\npart2"
        let raw = "POST /grab HTTP/1.1\r\nContent-Length: \(body.utf8.count)\r\n\r\n\(body)"
        guard case .complete(let r) = HTTPRequest.parse(data(raw)) else {
            return XCTFail("a body containing \\r\\n\\r\\n must still parse")
        }
        XCTAssertEqual(r.body, body)
    }

    // --- Content-Length: the boundary between "keep reading" and "truncate" ---
    func testContentLengthLargerThanBodyStaysIncomplete() {
        let raw = "POST /grab HTTP/1.1\r\nContent-Length: 100\r\n\r\nshort"
        guard case .incomplete = HTTPRequest.parse(data(raw)) else {
            return XCTFail("fewer body bytes than declared must stay incomplete, not truncate short")
        }
    }

    func testContentLengthSmallerThanBodyTruncates() {
        // Minor fix: the body must be cut to EXACTLY the declared length — trailing bytes
        // (there should be none under Connection: close, but a client could still send
        // extra) must not reach whatever JSON-decodes this body in task 7.
        let raw = "POST /grab HTTP/1.1\r\nContent-Length: 5\r\n\r\nhelloEXTRA"
        guard case .complete(let r) = HTTPRequest.parse(data(raw)) else {
            return XCTFail("a body at least as long as declared must complete")
        }
        XCTAssertEqual(r.body, "hello")
    }

    func testNonNumericContentLengthIsMalformed() {
        let raw = "POST /grab HTTP/1.1\r\nContent-Length: not-a-number\r\n\r\nbody"
        guard case .malformed(let reason) = HTTPRequest.parse(data(raw)) else {
            return XCTFail("a non-numeric Content-Length must be malformed, not guessed at")
        }
        XCTAssertEqual(reason, "bad content-length")
    }

    func testNegativeContentLengthIsMalformed() {
        let raw = "POST /grab HTTP/1.1\r\nContent-Length: -1\r\n\r\nbody"
        guard case .malformed = HTTPRequest.parse(data(raw)) else {
            return XCTFail("a negative Content-Length must be malformed")
        }
    }

    // Duplicate header: pinned as "last line wins", a deliberate simplification (see the
    // comment on the parser) rather than RFC 7230's comma-combining, which this server
    // has no need of for either header it reads.
    func testDuplicateContentLengthLastWins() {
        let raw = "POST /grab HTTP/1.1\r\nContent-Length: 999\r\nContent-Length: 3\r\n\r\nabc"
        guard case .complete(let r) = HTTPRequest.parse(data(raw)) else {
            return XCTFail("the last Content-Length (3, satisfied by the 3-byte body) must win")
        }
        XCTAssertEqual(r.body, "abc")
    }

    func testDuplicateOriginLastWins() {
        let raw = "GET /health HTTP/1.1\r\nOrigin: chrome-extension://first\r\nOrigin: chrome-extension://second\r\n\r\n"
        guard case .complete(let r) = HTTPRequest.parse(data(raw)) else {
            return XCTFail("a request with a duplicate Origin header must still parse")
        }
        XCTAssertEqual(r.origin, "chrome-extension://second")
    }

    // --- headers ---
    func testHeaderNameCaseVariations() {
        let raw = "GET /health HTTP/1.1\r\nORIGIN: chrome-extension://abc\r\n\r\n"
        guard case .complete(let r) = HTTPRequest.parse(data(raw)) else {
            return XCTFail("a request must parse regardless of header name case")
        }
        // Header names are stored lower-cased, so `.origin` (which reads "origin") finds
        // a header the client sent as "ORIGIN".
        XCTAssertEqual(r.origin, "chrome-extension://abc")
    }

    func testHeaderLineWithNoColonIsSkipped() {
        let raw = "GET /health HTTP/1.1\r\nThisLineHasNoColon\r\nOrigin: chrome-extension://abc\r\n\r\n"
        guard case .complete(let r) = HTTPRequest.parse(data(raw)) else {
            return XCTFail("a malformed header line must be skipped, not fail the whole request")
        }
        XCTAssertEqual(r.origin, "chrome-extension://abc")
    }

    // --- query string ---
    // Minor fix: splitting on every "=" (rather than the first) used to lose the value
    // entirely — "browser=a=b".components(separatedBy: "=") produces THREE parts, which
    // never matched the old `kv.count == 2` check, so the pair was dropped outright.
    func testQueryValueContainingEquals() {
        let raw = "GET /health?browser=a=b HTTP/1.1\r\n\r\n"
        guard case .complete(let r) = HTTPRequest.parse(data(raw)) else {
            return XCTFail("a request must parse")
        }
        XCTAssertEqual(r.query["browser"], "a=b")
    }

    // Minor fix: splitting the whole target on every "?" (rather than just the first)
    // used to silently drop everything after a second "?" — "path?a=1?b=2" produced
    // ["path", "a=1", "b=2"], and only the middle part was ever read.
    func testQueryValueContainingQuestionMark() {
        let raw = "GET /health?a=1?b=2 HTTP/1.1\r\n\r\n"
        guard case .complete(let r) = HTTPRequest.parse(data(raw)) else {
            return XCTFail("a request must parse")
        }
        XCTAssertEqual(r.path, "/health")
        // "?" has no special meaning once the query string has started — only "&"
        // separates pairs and "=" separates key from value — so everything after the
        // first "?" up to (there being no "&") the end is one pair's value.
        XCTAssertEqual(r.query["a"], "1?b=2")
    }

    func testRepeatedQueryKeyLastWins() {
        let raw = "GET /health?browser=chrome&browser=safari HTTP/1.1\r\n\r\n"
        guard case .complete(let r) = HTTPRequest.parse(data(raw)) else {
            return XCTFail("a request must parse")
        }
        XCTAssertEqual(r.query["browser"], "safari")
    }

    // A decoded query value becomes a `lastSeen` dictionary key that task 11's onboarding
    // UI renders directly — control characters must not survive into it.
    func testQueryValueControlCharactersAreStripped() {
        let raw = "GET /health?browser=chrome%0D%0Ainjected HTTP/1.1\r\n\r\n"
        guard case .complete(let r) = HTTPRequest.parse(data(raw)) else {
            return XCTFail("a request must parse")
        }
        XCTAssertEqual(r.query["browser"], "chromeinjected")
    }

    // --- size ---
    // The parser itself imposes no size cap — that is GrabServer's job (the 64 KB check
    // in receiveRequest, before HTTPRequest.parse is ever called), not the parser's. This
    // pins that division of responsibility: an oversized-but-fully-declared body must
    // still parse cleanly rather than the parser silently rejecting or crashing on it.
    func testParserHasNoSizeCapOfItsOwn() {
        let body = String(repeating: "x", count: 70_000) // over GrabServer's 64 KB cap
        let raw = "POST /grab HTTP/1.1\r\nContent-Length: \(body.utf8.count)\r\n\r\n\(body)"
        guard case .complete(let r) = HTTPRequest.parse(data(raw)) else {
            return XCTFail("the parser must not impose its own size limit — GrabServer's 64 KB guard runs before parse() is ever called")
        }
        XCTAssertEqual(r.body.utf8.count, 70_000)
    }
}
