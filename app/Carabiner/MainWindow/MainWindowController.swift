import AppKit
import SwiftUI

/// The main window: grab box + recent grabs. Owns the AppKit window; every decision
/// lives in MainViewModel. Same construction pattern as OnboardingWindowController.
final class MainWindowController: NSWindowController {
    let model: MainViewModel

    init(model: MainViewModel) {
        self.model = model
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
        window.contentViewController = NSHostingController(rootView: MainView(model: model))
        window.setContentSize(NSSize(width: 720, height: 460))
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
