import XCTest
@testable import Carabiner

final class IntroCardTests: XCTestCase {
    func testThereAreExactlyThreeCards() {
        XCTAssertEqual(IntroCard.all.count, 3)
    }

    func testEveryCardHasATitleAndAtLeastOneLine() {
        for card in IntroCard.all {
            XCTAssertFalse(card.title.isEmpty, "a card has no title")
            XCTAssertFalse(card.lines.isEmpty, "\(card.title) has no body")
            for line in card.lines {
                XCTAssertFalse(line.text.isEmpty, "\(card.title) has an empty line")
                // A lead-in is optional, but an empty one is a formatting bug: it would
                // render as a bold gap before the sentence.
                XCTAssertNotEqual(line.lead, "", "\(card.title) has an empty lead-in")
            }
        }
    }

    /// The second card is the only reason a user learns the in-page button exists, and
    /// the third is the only place "nothing is uploaded" is ever said. Pin both so a
    /// copy edit that drops them fails loudly rather than quietly.
    func testTheLoadBearingCopyIsPresent() {
        let all = IntroCard.all.flatMap(\.lines).map(\.text).joined(separator: " ")
        XCTAssertTrue(all.contains("beside Save"), "card 2 no longer says where the button is")
        XCTAssertTrue(all.contains("⌃⌥⌘V"), "card 2 no longer names the hotkey")
        XCTAssertTrue(all.contains("nothing is uploaded"), "card 3 no longer says it stays local")
    }
}
