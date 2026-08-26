import XCTest
@testable import Carabiner

final class IntroModelTests: XCTestCase {
    func testStartsOnTheFirstCard() {
        let model = IntroModel()
        XCTAssertEqual(model.index, 0)
        XCTAssertEqual(model.card, IntroCard.all[0])
        XCTAssertFalse(model.isLast)
    }

    func testNextPagesForwardAndStopsAtTheEnd() {
        let model = IntroModel()
        model.next()
        XCTAssertEqual(model.index, 1)
        model.next()
        XCTAssertEqual(model.index, 2)
        XCTAssertTrue(model.isLast)
        model.next()
        XCTAssertEqual(model.index, 2, "next() past the last card must be a no-op")
    }

    func testBackPagesAndStopsAtZero() {
        let model = IntroModel()
        model.next()
        model.back()
        XCTAssertEqual(model.index, 0)
        model.back()
        XCTAssertEqual(model.index, 0, "back() before the first card must be a no-op")
    }

    func testGoToJumpsAndIgnoresOutOfRange() {
        let model = IntroModel()
        model.go(to: 2)
        XCTAssertEqual(model.index, 2)
        model.go(to: 7)
        XCTAssertEqual(model.index, 2, "an out-of-range dot must not move the intro")
        model.go(to: -1)
        XCTAssertEqual(model.index, 2)
    }

    func testIsLastTracksTheInjectedCardCount() {
        let model = IntroModel(cards: [IntroCard.all[0]])
        XCTAssertTrue(model.isLast, "a one-card intro is on its last card immediately")
    }
}
