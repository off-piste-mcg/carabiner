import XCTest
@testable import Carabiner

final class GrabEventTests: XCTestCase {
    private func decode(_ line: String) -> [String: Any] {
        XCTAssertTrue(line.hasSuffix("\n"), "every event must be newline-terminated")
        return (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any] ?? [:]
    }

    func testDownloadCarriesPercent() {
        let o = decode(GrabEvent.line(for: .download(percent: 42.5)))
        XCTAssertEqual(o["stage"] as? String, "download")
        XCTAssertEqual(o["pct"] as? Double, 42.5)
    }
    func testDownloadWithoutPercentOmitsIt() {
        let o = decode(GrabEvent.line(for: .download(percent: nil)))
        XCTAssertEqual(o["stage"] as? String, "download")
        XCTAssertNil(o["pct"])
    }
    func testItemCarriesIndexAndTotal() {
        let o = decode(GrabEvent.line(for: .item(index: 2, total: 5)))
        XCTAssertEqual(o["stage"] as? String, "item")
        XCTAssertEqual(o["index"] as? Int, 2)
        XCTAssertEqual(o["total"] as? Int, 5)
    }
    func testPromptIsItsOwnStage() {
        XCTAssertEqual(decode(GrabEvent.line(for: .prompt))["stage"] as? String, "prompt")
    }
    func testUserLine() {
        XCTAssertEqual(decode(GrabEvent.line(forUser: "@offpiste"))["from"] as? String, "@offpiste")
    }
    func testSuccessResult() {
        let o = decode(GrabEvent.line(for: GrabResult(ok: true, message: "C1_fixed.mp4", user: "@a")))
        XCTAssertEqual(o["result"] as? String, "ok")
        XCTAssertEqual(o["message"] as? String, "C1_fixed.mp4")
    }
    func testCancelledIsItsOwnResultNotAFailure() {
        // The button must show nothing special for a deliberate cancel — same rule as
        // the banner (gotcha #22).
        let o = decode(GrabEvent.line(for: GrabResult(ok: false, message: "Nothing saved", cancelled: true)))
        XCTAssertEqual(o["result"] as? String, "cancelled")
    }
    func testFailureResult() {
        let o = decode(GrabEvent.line(for: GrabResult(ok: false, message: "cookies expired")))
        XCTAssertEqual(o["result"] as? String, "error")
        XCTAssertEqual(o["message"] as? String, "cookies expired")
    }
    func testMessageWithQuotesIsEscaped() {
        let line = GrabEvent.line(for: GrabResult(ok: false, message: "he said \"no\"\nand left"))
        XCTAssertEqual(line.filter { $0 == "\n" }.count, 1, "a message newline must not split the event")
        XCTAssertEqual(decode(line)["message"] as? String, "he said \"no\"\nand left")
    }
}
