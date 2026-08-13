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
                       [.postOutcome(ok: true, message: "ABC_fixed.mp4", user: nil, usedFallbackBrowser: nil)])
    }

    func testFailurePostsAFreshOutcome() {
        var planner = BannerPlanner()
        _ = planner.grabStarted()
        XCTAssertEqual(planner.finished(GrabResult(ok: false, message: "cookies expired")),
                       [.postOutcome(ok: false, message: "cookies expired", user: nil, usedFallbackBrowser: nil)])
    }

    /// The handle rides the outcome — the planner passes it through untouched so the
    /// subtitle policy stays in one place (Notifier.outcomeSubtitle).
    func testSuccessCarriesTheHandleThrough() {
        var planner = BannerPlanner()
        _ = planner.grabStarted()
        XCTAssertEqual(planner.finished(GrabResult(ok: true, message: "9 files", user: "@offpiste.mcg")),
                       [.postOutcome(ok: true, message: "9 files", user: "@offpiste.mcg", usedFallbackBrowser: nil)])
    }

    /// Finding 4, review fix round 1: `usedFallbackBrowser` must ride the outcome through
    /// exactly like `user` does — the planner isn't the place that decides what to say
    /// about it (that's `Notifier.outcomeSubtitle`), only the place that must not drop it.
    func testSuccessCarriesTheFallbackBrowserThrough() {
        var planner = BannerPlanner()
        _ = planner.grabStarted()
        let result = GrabResult(ok: true, message: "ABC_fixed.mp4", usedFallbackBrowser: .chrome)
        XCTAssertEqual(planner.finished(result),
                       [.postOutcome(ok: true, message: "ABC_fixed.mp4", user: nil, usedFallbackBrowser: .chrome)])
    }

    // MARK: - subtitle policy (pure, so it is testable outside a signed bundle)

    func testSubtitleNamesTheAccountOnSuccess() {
        XCTAssertEqual(Notifier.outcomeSubtitle(ok: true, user: "@offpiste.mcg"),
                       "✓ Saved from @offpiste.mcg")
    }

    func testSubtitleFallsBackWhenHandleUnknown() {
        XCTAssertEqual(Notifier.outcomeSubtitle(ok: true, user: nil), "✓ Saved")
    }

    /// A failure never names the account, even when the engine reported one before dying.
    func testFailureSubtitleIgnoresTheHandle() {
        XCTAssertEqual(Notifier.outcomeSubtitle(ok: false, user: "@offpiste.mcg"), "✗ Grab failed")
    }

    // MARK: - fallback-browser wording (Finding 4, review fix round 1)

    func testSubtitleNamesTheFallbackBrowserOnSuccess() {
        XCTAssertEqual(Notifier.outcomeSubtitle(ok: true, user: nil, usedFallbackBrowser: .chrome),
                       "✓ Saved — used Chrome's login")
    }

    /// The account and the fallback note are not mutually exclusive — knowing WHICH
    /// account it actually came from is exactly the information Finding 4 says a silent
    /// fallback was hiding.
    func testSubtitleCombinesTheAccountAndTheFallbackNote() {
        XCTAssertEqual(Notifier.outcomeSubtitle(ok: true, user: "@offpiste.mcg", usedFallbackBrowser: .chrome),
                       "✓ Saved from @offpiste.mcg — used Chrome's login")
    }

    /// A failed grab must not claim a fallback browser saved anything — there is nothing
    /// to name a login for.
    func testFailureSubtitleIgnoresTheFallbackBrowser() {
        XCTAssertEqual(Notifier.outcomeSubtitle(ok: false, user: nil, usedFallbackBrowser: .chrome),
                       "✗ Grab failed")
    }

    /// No fallback happened — the default omits the wording entirely rather than saying
    /// "used Chrome's login" for every ordinary Chrome grab.
    func testSubtitleOmitsTheFallbackNoteWhenNoFallbackHappened() {
        XCTAssertEqual(Notifier.outcomeSubtitle(ok: true, user: nil), "✓ Saved")
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
