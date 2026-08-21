import AppKit
import SwiftUI

/// The setup & diagnostics window. Owns everything AppKit-shaped — the window, the
/// hotkey-test timer, and the intercept lifecycle — and hands rendering to SwiftUI.
/// All decisions still live in PermissionRow.presentation(for:) and HotkeyTestModel.
final class OnboardingWindowController: NSWindowController, NSWindowDelegate {
    private let hotkeyIntercept: (@escaping () -> Void) -> Void
    private let clearIntercept: () -> Void

    private var hotkeyModel = HotkeyTestModel()
    private var hotkeyTimer: Timer?
    private let model: OnboardingViewModel

    static let shownDefaultsKey = "onboardingShown"

    init(checker: PermissionChecking,
         hotkeyIntercept: @escaping (@escaping () -> Void) -> Void,
         clearIntercept: @escaping () -> Void) {
        self.hotkeyIntercept = hotkeyIntercept
        self.clearIntercept = clearIntercept
        self.model = OnboardingViewModel(checker: checker)

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 480),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Carabiner Setup"
        window.isReleasedWhenClosed = false
        super.init(window: window)

        window.delegate = self
        // The SwiftUI body is width-pinned and vertically self-sizing, so let the hosting
        // controller drive the window's height rather than the 480 above.
        window.contentViewController = NSHostingController(rootView: OnboardingView(model: model))
        model.onBeginHotkeyTest = { [weak self] in self?.beginHotkeyTest() }
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    func show() {
        UserDefaults.standard.set(true, forKey: Self.shownDefaultsKey)
        model.refreshAll()
        NSApp.activate(ignoringOtherApps: true)
        // A Dock-tile click routes here for an already-open window too (bring to front);
        // re-centering would yank a window the user has positioned.
        if window?.isVisible != true { window?.center() }
        window?.makeKeyAndOrderFront(nil)
    }

    // MARK: - hotkey test

    private func beginHotkeyTest() {
        hotkeyModel.beginTest()
        model.hotkey = hotkeyModel.presentation
        hotkeyIntercept { [weak self] in
            guard let self else { return }
            self.hotkeyTimer?.invalidate()
            self.hotkeyModel.hotkeyFired()
            self.model.hotkey = self.hotkeyModel.presentation
        }
        hotkeyTimer?.invalidate()
        hotkeyTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: false) { [weak self] _ in
            guard let self else { return }
            self.clearIntercept()
            self.hotkeyModel.timeout()
            self.model.hotkey = self.hotkeyModel.presentation
        }
    }

    // MARK: - NSWindowDelegate

    func windowDidBecomeKey(_ notification: Notification) { model.refreshAll() }

    func windowWillClose(_ notification: Notification) {
        hotkeyTimer?.invalidate()
        clearIntercept()
        hotkeyModel.cancel()
        model.hotkey = hotkeyModel.presentation
    }
}
