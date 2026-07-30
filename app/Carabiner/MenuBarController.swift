import AppKit

final class MenuBarController: NSObject {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let notifier = Notifier()
    /// One browser for the whole flow. The tab we read the URL from has to be the same
    /// one `carabiner` pulls cookies from, so both sides are built from this constant.
    /// Phase 2 turns it into a picker.
    private static let browser: Browser = .chrome
    private let tabReader = TabReader(browser: MenuBarController.browser)
    private let runner = GrabRunner(browser: MenuBarController.browser)
    private var busy = false

    override init() {
        super.init()
        if let button = statusItem.button {
            // Vector asset cropped to the mark's own bounds (496:388), so height sets the
            // size and width follows the aspect — 18pt would overflow a 22pt menu bar.
            let icon = NSImage(named: "StatusIcon")
            icon?.size = NSSize(width: 20.5, height: 16)
            // Template, unlike the full-colour AppIcon this replaced: the mark is a single
            // silhouette, so AppKit tints it to match the menu bar (dark on light, light on
            // dark) instead of it vanishing into a light bar. Notifications are unaffected —
            // UNUserNotificationCenter takes their icon from the bundle's AppIcon.
            icon?.isTemplate = true
            button.image = icon
            // A missing asset would leave a blank, unexplained gap in the menu bar, so say so.
            if icon == nil { NSLog("Carabiner: StatusIcon asset missing — status item has no image") }
        }
        let menu = NSMenu()
        let grabItem = NSMenuItem(title: "Grab current tab", action: #selector(grab), keyEquivalent: "")
        grabItem.target = self
        menu.addItem(grabItem)
        menu.addItem(.separator())
        // No explicit target: lets this route up the responder chain to NSApp, which
        // implements terminate:. MenuBarController itself does not, so an explicit
        // target here would leave AppKit's autoenablesItems disabling the item.
        menu.addItem(NSMenuItem(title: "Quit Carabiner", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        statusItem.menu = menu
    }

    @objc func grab() {
        // Every outcome below is reported by notification, so if notifications are
        // unavailable the app has no voice at all — a failed grab looks exactly like a
        // dead hotkey. Log each outcome too, so the app stays diagnosable without it.
        guard !busy else {
            NSLog("Carabiner: grab ignored — a grab is already running")
            return
        }
        // Before reading the tab, not after: resolve() drives AppleScript on this thread
        // and is itself part of the delay the user is waiting through. Any outcome below
        // replaces this banner rather than adding to it, so an early failure still shows
        // exactly one notification.
        notifier.showWorking()
        let url: String
        switch tabReader.resolve() {
        case .url(let u):
            url = u
        case .notAuthorized:
            NSLog("Carabiner: grab aborted — not authorised to control %@", Self.browser.appName)
            notifier.show(GrabResult(ok: false, message: "Allow Carabiner to control \(Self.browser.appName) under System Settings → Privacy & Security → Automation, then try again"))
            return
        case .nothing:
            NSLog("Carabiner: grab aborted — no URL in the front tab or the clipboard")
            notifier.show(GrabResult(ok: false, message: "No link in your browser tab or clipboard"))
            return
        }
        NSLog("Carabiner: grabbing %@", url)
        busy = true
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let result = self.runner.run(url: url)
            DispatchQueue.main.async {
                NSLog("Carabiner: grab %@ — %@", result.ok ? "succeeded" : "failed", result.message)
                self.notifier.show(result)
                self.busy = false
            }
        }
    }
}
