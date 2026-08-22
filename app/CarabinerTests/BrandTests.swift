import XCTest
@testable import Carabiner

final class BrandTests: XCTestCase {
    /// The footer clock renders mockup-style: zero-padded 12h, uppercase AM/PM,
    /// no space — "09:32AM". Locale-pinned so a machine's 24h preference can't
    /// change the brand furniture.
    func testClockTextFormatsMockupStyle() {
        var components = DateComponents()
        components.year = 2026; components.month = 8; components.day = 22
        components.hour = 9; components.minute = 32
        components.timeZone = TimeZone(identifier: "Europe/Amsterdam")
        let date = Calendar(identifier: .gregorian).date(from: components)!
        XCTAssertEqual(Brand.clockText(date, timeZone: TimeZone(identifier: "Europe/Amsterdam")!),
                       "09:32AM")
    }

    func testClockTextAfternoon() {
        var components = DateComponents()
        components.year = 2026; components.month = 8; components.day = 22
        components.hour = 14; components.minute = 5
        components.timeZone = TimeZone(identifier: "Europe/Amsterdam")
        let date = Calendar(identifier: .gregorian).date(from: components)!
        XCTAssertEqual(Brand.clockText(date, timeZone: TimeZone(identifier: "Europe/Amsterdam")!),
                       "02:05PM")
    }
}
