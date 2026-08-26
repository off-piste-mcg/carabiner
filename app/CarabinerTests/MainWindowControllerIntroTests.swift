import XCTest
@testable import Carabiner

/// Regression guard for the intro/settings WIRING in MainWindowController — not the pure
/// model helpers MainViewModelIntroTests already pins perfectly, but the call sites that
/// are supposed to use them. Gotcha #34: a helper can be 100% tested while its call site
/// is reverted underneath it, and nothing here catches that unless the test exercises the
/// real controller. Each test below was checked to actually go red on the regression it
/// guards — see the fix report for the close-exit mutation evidence.
@MainActor
final class MainWindowControllerIntroTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!
    private var controller: MainWindowController!

    override func setUp() {
        super.setUp()
        // A scratch suite, not .standard: these tests must not read or write the real
        // app's introShown/onboardingShown keys, and must not leak state into each other.
        suiteName = "carabiner-mwc-intro-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        controller?.close()
        controller = nil
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    /// Built the way MenuBarController.showMainWindow() builds the real thing, wired to
    /// the scratch defaults suite instead of .standard.
    private func makeController() -> MainWindowController {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("carabiner-mwc-intro-\(UUID().uuidString)")
        let model = MainViewModel(history: GrabHistoryStore(directory: directory))
        // OnboardingViewModel is @MainActor; this whole test class already runs on the
        // main actor, so the wrapper is just satisfying the compiler, same as the real
        // call site.
        let settingsModel = MainActor.assumeIsolated {
            OnboardingViewModel(checker: LivePermissionChecker(browser: .chrome))
        }
        return MainWindowController(
            model: model,
            settingsModel: settingsModel,
            hotkeyIntercept: { _ in },
            clearIntercept: {},
            defaults: defaults)
    }

    // MARK: - the close exit (Finding 2)

    /// windowWillClose must call dismissIntro(), not skipIntro() — reverting that one
    /// line is this project's gotcha #34 sitting on the branch's most consequential line,
    /// and MainViewModelIntroTests alone cannot see it because it never touches the
    /// controller. This test was verified to go red on that exact reversion (see the fix
    /// report).
    func testWindowCloseLeavesIntroSeenAndOnboardingUnset() {
        controller = makeController()
        controller.model.showIntro()
        XCTAssertNotNil(controller.model.intro)

        controller.windowWillClose(Notification(name: NSWindow.willCloseNotification))

        XCTAssertNil(controller.model.intro)
        XCTAssertFalse(IntroGate.shouldShow(defaults),
                       "the close exit must mark the intro seen")
        XCTAssertFalse(defaults.bool(forKey: MainWindowController.settingsShownDefaultsKey),
                       "the close exit must NOT fall through to onboardingShown — a fresh " +
                       "install must still get the first-launch settings panel next launch")
    }

    // MARK: - the skip fallthrough

    func testSkipOpensSettingsWhenOnboardingNeverShown() {
        controller = makeController()
        controller.model.showIntro()

        controller.model.skipIntro()

        XCTAssertEqual(controller.model.panel, .settings,
                       "SKIP must fall through to settings on a fresh install")
    }

    func testSkipDoesNotOpenSettingsWhenOnboardingAlreadyShown() {
        defaults.set(true, forKey: MainWindowController.settingsShownDefaultsKey)
        controller = makeController()
        controller.model.showIntro()

        controller.model.skipIntro()

        XCTAssertNil(controller.model.panel,
                     "SKIP must not reopen settings once onboarding has already run")
    }

    // MARK: - Finding 1: ⌘, / "Settings…" during the intro

    /// Before the fix, showSettings() set panel = .settings without clearing model.intro
    /// — a silent no-op, since MainView renders the intro INSTEAD of the panel. This pins
    /// the fix: dismissIntro() runs first.
    func testShowSettingsClearsTheIntroAndOpensThePanel() {
        controller = makeController()
        controller.model.showIntro()
        XCTAssertNotNil(controller.model.intro)

        controller.showSettings()

        XCTAssertNil(controller.model.intro, "showSettings must dismiss the intro takeover")
        XCTAssertEqual(controller.model.panel, .settings)
    }
}
