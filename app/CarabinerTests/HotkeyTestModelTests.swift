import XCTest
@testable import Carabiner

final class HotkeyTestModelTests: XCTestCase {

    func testIdleOffersTest() {
        let m = HotkeyTestModel()
        XCTAssertEqual(m.state, .idle)
        XCTAssertEqual(m.presentation, HotkeyTestPresentation(
            tick: .pending, buttonTitle: "Test", detail: "Press ⌃⌥⌘V when asked."))
    }

    func testListeningPrompts() {
        var m = HotkeyTestModel()
        m.beginTest()
        XCTAssertEqual(m.state, .listening)
        XCTAssertEqual(m.presentation, HotkeyTestPresentation(
            tick: .pending, buttonTitle: nil, detail: "Press ⌃⌥⌘V now…"))
    }

    func testFireConfirms() {
        var m = HotkeyTestModel()
        m.beginTest()
        m.hotkeyFired()
        XCTAssertEqual(m.state, .confirmed)
        XCTAssertEqual(m.presentation.tick, .ok)
        XCTAssertNil(m.presentation.buttonTitle)
    }

    /// A silently-lost chord looks exactly like a broken app (gotcha #14) — the timeout
    /// text is the one place that failure mode gets explained, so it is pinned verbatim.
    func testTimeoutShowsTheShortcutHint() {
        var m = HotkeyTestModel()
        m.beginTest()
        m.timeout()
        XCTAssertEqual(m.state, .timedOut)
        XCTAssertEqual(m.presentation.tick, .cross)
        XCTAssertEqual(m.presentation.buttonTitle, "Test again")
        XCTAssertEqual(m.presentation.detail, HotkeyTestModel.hint)
    }

    /// A fire after the window stopped listening (timeout, or never started) is a real
    /// grab, not a test result — the model must not swallow it into a state change.
    func testFireOutsideListeningIsIgnored() {
        var m = HotkeyTestModel()
        m.hotkeyFired()
        XCTAssertEqual(m.state, .idle)
        m.beginTest()
        m.timeout()
        m.hotkeyFired()
        XCTAssertEqual(m.state, .timedOut)
    }

    /// Timeout arriving after a successful fire (the Timer raced the keystroke) must not
    /// downgrade a confirmed hotkey to a failure.
    func testLateTimeoutDoesNotUnconfirm() {
        var m = HotkeyTestModel()
        m.beginTest()
        m.hotkeyFired()
        m.timeout()
        XCTAssertEqual(m.state, .confirmed)
    }
}
