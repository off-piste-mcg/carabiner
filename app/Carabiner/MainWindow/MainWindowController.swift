import AppKit
import Combine
import SwiftUI

/// The main window: the brand canvas plus the in-window settings panel. Owns everything
/// AppKit-shaped — the window, the hotkey-test timer, the intercept lifecycle (moved
/// verbatim from the retired OnboardingWindowController). Decisions live in
/// MainViewModel, OnboardingViewModel and HotkeyTestModel.
final class MainWindowController: NSWindowController, NSWindowDelegate {
    let model: MainViewModel
    let settingsModel: OnboardingViewModel

    private let hotkeyIntercept: (@escaping () -> Void) -> Void
    private let clearIntercept: () -> Void
    private var hotkeyModel = HotkeyTestModel()
    private var hotkeyTimer: Timer?
    private var panelCancellable: AnyCancellable?

    /// Same string as the retired onboarding window's shownDefaultsKey — existing
    /// installs must not re-run first-launch.
    static let settingsShownDefaultsKey = "onboardingShown"

    init(model: MainViewModel,
         settingsModel: OnboardingViewModel,
         hotkeyIntercept: @escaping (@escaping () -> Void) -> Void,
         clearIntercept: @escaping () -> Void) {
        self.model = model
        self.settingsModel = settingsModel
        self.hotkeyIntercept = hotkeyIntercept
        self.clearIntercept = clearIntercept
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 460),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable,
                                          .fullSizeContentView],
                              backing: .buffered, defer: false)
        // The brand canvas is the window: transparent titlebar, no title text, content
        // bleeding under the traffic lights (which stay — native close/minimize).
        window.title = "Carabiner"              // window menu / accessibility name only
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        // The artwork is light and has no dark variant; pin the appearance so native
        // sub-controls (context menus, text caret) never go dark-on-pale.
        window.appearance = NSAppearance(named: .aqua)
        window.isMovableByWindowBackground = true
        window.minSize = NSSize(width: 640, height: 420)
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        window.contentViewController = NSHostingController(
            rootView: MainView(model: model, settings: settingsModel))
        window.setContentSize(NSSize(width: 720, height: 460))
        settingsModel.onBeginHotkeyTest = { [weak self] in self?.beginHotkeyTest() }
        // Everything that touches UserDefaults lives here, not in the view: the model
        // gets closures, so a model built in a test writes nothing.
        model.markIntroSeen = { IntroGate.markSeen(.standard) }
        model.onIntroFinished = { [weak self] in self?.showSettings() }
        // SKIP still lands a fresh install on the permissions panel — the 0.2.0
        // first-launch rule, unchanged. Skipping the explainer must not be a way to end
        // up with a silently non-working app.
        model.onIntroSkipped = { [weak self] in
            guard let self else { return }
            if !UserDefaults.standard.bool(forKey: Self.settingsShownDefaultsKey) {
                self.showSettings()
            }
        }
        // Closing the panel (Esc/✕/canvas click) sets panel = nil directly in MainView,
        // bypassing windowWillClose — without this, a hotkey test left running keeps
        // the global intercept armed for up to 10s after the panel is gone. Cancelling
        // here is safe even when no test is running: cancelHotkeyTest below is
        // idempotent (HotkeyTestModel.cancel() only acts in .listening).
        panelCancellable = model.$panel.sink { [weak self] panel in
            if panel != .settings { self?.cancelHotkeyTest() }
        }
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    func show() {
        NSApp.activate(ignoringOtherApps: true)
        // A Dock click on an already-open window brings it forward, and must not
        // re-center a window the user has positioned.
        if window?.isVisible != true { window?.center() }
        window?.makeKeyAndOrderFront(nil)
    }

    /// ⌘,, the status-menu item and first launch land here: the window with the
    /// settings panel already open.
    func showSettings() {
        UserDefaults.standard.set(true, forKey: Self.settingsShownDefaultsKey)
        settingsModel.refreshAll()
        model.panel = .settings
        show()
    }

    /// First launch and the "How Carabiner works" menu item: the window with the
    /// explainer over the canvas. Always starts at card 1 (showIntro builds a fresh
    /// IntroModel), and does not touch introShown — dismissing it does that.
    func showIntro() {
        model.showIntro()
        show()
    }

    // MARK: - hotkey test (moved verbatim from OnboardingWindowController)

    private func beginHotkeyTest() {
        hotkeyModel.beginTest()
        settingsModel.hotkey = hotkeyModel.presentation
        hotkeyIntercept { [weak self] in
            guard let self else { return }
            self.hotkeyTimer?.invalidate()
            self.hotkeyModel.hotkeyFired()
            self.settingsModel.hotkey = self.hotkeyModel.presentation
        }
        hotkeyTimer?.invalidate()
        hotkeyTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: false) { [weak self] _ in
            guard let self else { return }
            self.clearIntercept()
            self.hotkeyModel.timeout()
            self.settingsModel.hotkey = self.hotkeyModel.presentation
        }
    }

    /// Tears down an in-flight hotkey test: invalidate the timeout timer, release the
    /// global hotkey intercept, and reset the row's own state. Idempotent — safe to call
    /// whether or not a test is actually running (HotkeyTestModel.cancel() only acts in
    /// .listening; invalidate()/clearIntercept() are no-ops otherwise).
    private func cancelHotkeyTest() {
        hotkeyTimer?.invalidate()
        clearIntercept()
        hotkeyModel.cancel()
        settingsModel.hotkey = hotkeyModel.presentation
    }

    // MARK: - NSWindowDelegate

    func windowDidBecomeKey(_ notification: Notification) { settingsModel.refreshAll() }

    func windowWillClose(_ notification: Notification) {
        // Closing the window is the third way out of the explainer. Mark it seen, or it
        // reappears next launch for anyone who leaves by that door.
        model.skipIntro()
        cancelHotkeyTest()
        // A Dock click after closing with the panel open must reopen onto the plain
        // canvas, never the panel — this is what makes that true.
        model.collapsePanel()
    }
}
