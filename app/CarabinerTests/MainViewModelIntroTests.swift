import XCTest
@testable import Carabiner

final class MainViewModelIntroTests: XCTestCase {
    private func makeModel() -> MainViewModel {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("carabiner-intro-vm-\(UUID().uuidString)")
        return MainViewModel(history: GrabHistoryStore(directory: directory))
    }

    func testShowIntroStartsOnTheFirstCard() {
        let model = makeModel()
        model.showIntro()
        XCTAssertNotNil(model.intro)
        XCTAssertEqual(model.intro?.index, 0)
    }

    func testShowIntroAlwaysRestartsAtTheFirstCard() {
        let model = makeModel()
        model.showIntro()
        model.intro?.next()
        model.showIntro()
        XCTAssertEqual(model.intro?.index, 0, "reopening must not resume mid-explainer")
    }

    func testSkipMarksSeenClearsTheIntroAndFiresTheSkipHook() {
        let model = makeModel()
        var seen = 0, skipped = 0, finished = 0
        model.markIntroSeen = { seen += 1 }
        model.onIntroSkipped = { skipped += 1 }
        model.onIntroFinished = { finished += 1 }
        model.showIntro()
        model.skipIntro()
        XCTAssertNil(model.intro)
        XCTAssertEqual(seen, 1)
        XCTAssertEqual(skipped, 1)
        XCTAssertEqual(finished, 0, "skip must not run the settings handoff")
    }

    func testFinishMarksSeenClearsTheIntroAndFiresTheFinishHook() {
        let model = makeModel()
        var seen = 0, skipped = 0, finished = 0
        model.markIntroSeen = { seen += 1 }
        model.onIntroSkipped = { skipped += 1 }
        model.onIntroFinished = { finished += 1 }
        model.showIntro()
        model.finishIntro()
        XCTAssertNil(model.intro)
        XCTAssertEqual(seen, 1)
        XCTAssertEqual(finished, 1)
        XCTAssertEqual(skipped, 0, "finish must not also run the skip fallthrough")
    }

    func testSkipIsSafeToCallWithNoIntroShowing() {
        let model = makeModel()
        var seen = 0
        model.markIntroSeen = { seen += 1 }
        model.skipIntro()
        XCTAssertNil(model.intro)
        XCTAssertEqual(seen, 0, "nothing to mark seen when no intro was showing")
    }

    /// The window-close exit. It must mark the explainer seen (so it doesn't reappear),
    /// but must NOT run either the SKIP or FINISH hook — there is no window to show a
    /// settings panel in, and firing onIntroSkipped here would set onboardingShown too,
    /// which is the bug this test guards: it would silently deny a fresh install its
    /// first-launch permissions panel on every later launch.
    func testDismissMarksSeenClearsTheIntroAndFiresNoHook() {
        let model = makeModel()
        var seen = 0, skipped = 0, finished = 0
        model.markIntroSeen = { seen += 1 }
        model.onIntroSkipped = { skipped += 1 }
        model.onIntroFinished = { finished += 1 }
        model.showIntro()
        model.dismissIntro()
        XCTAssertNil(model.intro)
        XCTAssertEqual(seen, 1)
        XCTAssertEqual(skipped, 0, "closing the window must not run the skip fallthrough")
        XCTAssertEqual(finished, 0, "closing the window must not run the settings handoff")
    }

    /// Closing the window while the intro is up is a third exit. It must mark seen too,
    /// or the explainer reappears every launch for anyone who leaves by that door.
    ///
    /// Safe to call with no intro showing — an ordinary window close (e.g. from the
    /// settings panel) must not mark anything.
    func testDismissIsSafeToCallWithNoIntroShowing() {
        let model = makeModel()
        var seen = 0
        model.markIntroSeen = { seen += 1 }
        model.dismissIntro()
        XCTAssertNil(model.intro)
        XCTAssertEqual(seen, 0, "nothing to mark seen when no intro was showing")
    }
}
