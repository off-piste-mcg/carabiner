import AppKit
import SwiftUI

/// The main window: grab box + recent grabs. Owns the AppKit window; every decision
/// lives in MainViewModel. Same construction pattern as OnboardingWindowController.
final class MainWindowController: NSWindowController {
    let model: MainViewModel

    init(model: MainViewModel) {
        self.model = model
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 480),
                              styleMask: [.titled, .closable, .resizable],
                              backing: .buffered, defer: false)
        window.title = "Carabiner"
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.contentViewController = NSHostingController(rootView: MainView(model: model))
        window.setContentSize(NSSize(width: 460, height: 480))
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    func show() {
        NSApp.activate(ignoringOtherApps: true)
        // Same rule as the setup window: a Dock click on an already-open window brings it
        // forward, and must not re-center a window the user has positioned.
        if window?.isVisible != true { window?.center() }
        window?.makeKeyAndOrderFront(nil)
    }
}
