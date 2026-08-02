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

    static func main() {
        let app = NSApplication.shared
        app.delegate = delegate
        app.setActivationPolicy(.accessory) // menu-bar only
        app.run()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let controller = MenuBarController()
        menuBar = controller
        Hotkey.onGrab { [weak controller] in controller?.grab() }
        // No unconditional notification request any more: on a fresh install the setup
        // window is the only thing that triggers permission prompts, so every prompt
        // appears next to its explanation instead of naked at first launch.
        if !UserDefaults.standard.bool(forKey: OnboardingWindowController.shownDefaultsKey) {
            controller.showOnboarding()
        }
    }
}
