import XCTest
@testable import Carabiner

/// The banner policy is pure data-in, actions-out so it can be tested at all:
/// UNUserNotificationCenter refuses to work outside a signed, LaunchServices-launched
/// bundle, so the decisions have to live somewhere a unit test can reach.
final class BannerPlannerTests: XCTestCase {

    func testStartAnnouncesReadingTheLink() {
        var planner = BannerPlanner()
        XCTAssertEqual(planner.grabStarted(), [.postWorking(body: "Reading the link…")])
    }

    func testProbeUpdatesTheBody() {
        var planner = BannerPlanner()
        _ = planner.grabStarted()
        XCTAssertEqual(planner.handle(.probe), [.postWorking(body: "Checking the post…")])
    }

    /// The carousel dialog is the UI while it is up. A banner claiming work is being done
    /// next to a question that is waiting on the user is exactly the misalignment this
    /// type exists to remove.
    func testPromptTakesTheWorkingBannerDown() {
        var planner = BannerPlanner()
        _ = planner.grabStarted()
        _ = planner.handle(.probe)
        XCTAssertEqual(planner.handle(.prompt), [.removeWorking])
    }

    /// After the user answers the dialog the grab genuinely starts, and the working banner
    /// must come back — as a *new* presentation, which it is, because the prompt removed it.
    func testChoiceAfterPromptRepostsTheWorkingBanner() {
        var planner = BannerPlanner()
        _ = planner.grabStarted()
        _ = planner.handle(.probe)
        _ = planner.handle(.prompt)
        XCTAssertEqual(planner.handle(.download(percent: nil)),
                       [.postWorking(body: "Saving to Downloads")])
    }

    /// yt-dlp reports a percentage several times a second. The banner is stage-level
    /// feedback, not a progress bar — re-posting it per tick is pure churn.
    func testRepeatedDownloadTicksDoNotChurn() {
        var planner = BannerPlanner()
        _ = planner.grabStarted()
        _ = planner.handle(.download(percent: 10))
        XCTAssertEqual(planner.handle(.download(percent: 55)), [])
        XCTAssertEqual(planner.handle(.download(percent: 90)), [])
    }

    func testCarouselItemsAnnounceSlideProgress() {
        var planner = BannerPlanner()
        _ = planner.grabStarted()
        _ = planner.handle(.download(percent: nil))
        XCTAssertEqual(planner.handle(.item(index: 2, total: 12)),
                       [.postWorking(body: "Saving slide 2 of 12…")])
    }

    /// A single-slide grab through ig_gallery still emits `item:1:1`; "slide 1 of 1"
    /// would read as a bug, and the body is already "Saving to Downloads".
    func testSingleItemDoesNotSaySlideOneOfOne() {
        var planner = BannerPlanner()
        _ = planner.grabStarted()
        _ = planner.handle(.download(percent: nil))
        XCTAssertEqual(planner.handle(.item(index: 1, total: 1)), [])
    }

    /// Convert and save are part of "saving" as far as the banner is concerned.
    func testConvertAndSaveAreSilent() {
        var planner = BannerPlanner()
        _ = planner.grabStarted()
        _ = planner.handle(.download(percent: 40))
        XCTAssertEqual(planner.handle(.convert(.remux)), [])
        XCTAssertEqual(planner.handle(.save), [])
    }

    func testSuccessPostsAFreshOutcome() {
        var planner = BannerPlanner()
        _ = planner.grabStarted()
        _ = planner.handle(.download(percent: 100))
        XCTAssertEqual(planner.finished(GrabResult(ok: true, message: "ABC_fixed.mp4")),
                       [.postOutcome(ok: true, message: "ABC_fixed.mp4")])
    }

    func testFailurePostsAFreshOutcome() {
        var planner = BannerPlanner()
        _ = planner.grabStarted()
        XCTAssertEqual(planner.finished(GrabResult(ok: false, message: "cookies expired")),
                       [.postOutcome(ok: false, message: "cookies expired")])
    }

    /// Cancelling the carousel dialog is a deliberate act, not a failure. The only right
    /// response is to take the working banner down and say nothing.
    func testCancelRemovesTheBannerAndSaysNothing() {
        var planner = BannerPlanner()
        _ = planner.grabStarted()
        _ = planner.handle(.probe)
        _ = planner.handle(.prompt)
        XCTAssertEqual(planner.finished(GrabResult(ok: false, message: "Nothing saved", cancelled: true)),
                       [.removeWorking])
    }

    /// The prompt already removed the working banner; a cancel after it must not remove twice
    /// — harmless with UNUserNotificationCenter, but the action list is the contract.
    func testCancelAfterPromptStillEmitsExactlyOneRemove() {
        var planner = BannerPlanner()
        _ = planner.grabStarted()
        _ = planner.handle(.prompt)
        let actions = planner.finished(GrabResult(ok: false, message: "Nothing saved", cancelled: true))
        XCTAssertEqual(actions.filter { $0 == .removeWorking }.count, 1)
    }
}
