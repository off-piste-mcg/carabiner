import AppKit

@main
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var menuBar: MenuBarController?

    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory) // menu-bar only
        app.run()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        menuBar = MenuBarController()
    }
}
