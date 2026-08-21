import AppKit

@main
final class AppDelegate: NSObject, NSApplicationDelegate {
    // NSApplication.delegate is `weak`. A local `let` would be the only
    // strong reference, and ARC is free to release it right after the
    // assignment (before `app.run()` starts pumping the run loop) in an
    // optimized Release build — the delegate deallocates,
    // applicationDidFinishLaunching never fires, and the app runs with no
    // status item. Hold the strong reference on the type instead.
    private static let delegate = AppDelegate()

    private var menuBar: MenuBarController?
    private var grabServer: GrabServer?

    static func main() {
        let app = NSApplication.shared
        app.delegate = delegate
        app.setActivationPolicy(.regular) // Dock tile + menu bar item, like any app
        // A regular app owns the top menu bar when frontmost. Without a main menu that
        // bar is empty — no Quit, and no Edit actions in the setup window's text fields.
        app.mainMenu = mainMenu()
        app.run()
    }

    private static func mainMenu() -> NSMenu {
        let main = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(NSMenuItem(title: "About Carabiner",
                                   action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
                                   keyEquivalent: ""))
        appMenu.addItem(.separator())
        appMenu.addItem(NSMenuItem(title: "Quit Carabiner",
                                   action: #selector(NSApplication.terminate(_:)),
                                   keyEquivalent: "q"))
        appItem.submenu = appMenu
        main.addItem(appItem)

        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(NSMenuItem(title: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x"))
        editMenu.addItem(NSMenuItem(title: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c"))
        editMenu.addItem(NSMenuItem(title: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v"))
        editMenu.addItem(NSMenuItem(title: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"))
        editItem.submenu = editMenu
        main.addItem(editItem)

        return main
    }

    /// Clicking the Dock tile (or the pinned icon of the already-running app) sends a
    /// reopen event. That must open Setup & Permissions — a Dock icon that does nothing
    /// when clicked is this project's worst failure shape.
    /// `hasVisibleWindows` is deliberately ignored: the status item is backed by a
    /// window, so it reads true while nothing is on screen (measured — gating on it left
    /// the reopen doing nothing). showOnboarding() is right in both real cases anyway:
    /// it opens the window, or brings the open one to front.
    /// Launch at login sends no reopen, so login launches still start quietly.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        menuBar?.showOnboarding()
        return false
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let controller = MenuBarController()
        menuBar = controller
        Hotkey.onGrab { [weak controller] in controller?.hotkeyFired() }
        // Ship the socket before the grab route (task 7): a failure here is unambiguous —
        // it shows up in onboarding rather than as a button that silently does nothing.
        let server = GrabServer(controller: controller)
        server.start()
        grabServer = server
        controller.grabServer = server
        // No unconditional notification request any more: on a fresh install the setup
        // window is the only thing that triggers permission prompts, so every prompt
        // appears next to its explanation instead of naked at first launch.
        if !UserDefaults.standard.bool(forKey: OnboardingWindowController.shownDefaultsKey) {
            controller.showOnboarding()
        }
    }

    /// The extension opens `carabiner://launch` purely to start the app when it isn't
    /// running; the real request then arrives over HTTP. There is nothing to do here —
    /// being launched IS the effect.
    func application(_ application: NSApplication, open urls: [URL]) {
        NSLog("Carabiner: launched via URL scheme (%@)", urls.first?.absoluteString ?? "?")
    }
}
