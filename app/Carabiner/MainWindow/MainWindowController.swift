import AppKit
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
        model.settingsShown = true
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

    // MARK: - NSWindowDelegate

    func windowDidBecomeKey(_ notification: Notification) { settingsModel.refreshAll() }

    func windowWillClose(_ notification: Notification) {
        hotkeyTimer?.invalidate()
        clearIntercept()
        hotkeyModel.cancel()
        settingsModel.hotkey = hotkeyModel.presentation
    }
}
