import XCTest
@testable import Carabiner

final class IntroGateTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        // A scratch suite, not .standard: these tests must not read or write the real
        // app's key, and must not leak state into each other.
        suiteName = "carabiner-intro-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    func testShowsWhenNeverSeen() {
        XCTAssertTrue(IntroGate.shouldShow(defaults))
    }

    func testDoesNotShowOnceSeen() {
        IntroGate.markSeen(defaults)
        XCTAssertFalse(IntroGate.shouldShow(defaults))
    }

    func testSeenSurvivesAFreshRead() {
        IntroGate.markSeen(defaults)
        let reread = UserDefaults(suiteName: suiteName)!
        XCTAssertFalse(IntroGate.shouldShow(reread), "markSeen did not persist")
    }

    /// The intro key must be its own. onboardingShown is already true on every 0.1.x and
    /// 0.2.0 install; reusing it would silently exclude exactly the upgraders this
    /// explainer is for.
    func testDoesNotReadTheOnboardingKey() {
        defaults.set(true, forKey: MainWindowController.settingsShownDefaultsKey)
        XCTAssertTrue(IntroGate.shouldShow(defaults),
                      "the intro gate is reading onboardingShown")
    }
}
