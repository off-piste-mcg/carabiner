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
            button.image = NSImage(named: "AppIcon")
            button.image?.size = NSSize(width: 18, height: 18)
            // Not a template image: templates render as a flat monochrome silhouette,
            // which would throw away the full-colour OFF-PISTE logo.
            button.image?.isTemplate = false
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
        guard !busy else { return }
        let url: String
        switch tabReader.resolve() {
        case .url(let u):
            url = u
        case .notAuthorized:
            notifier.show(GrabResult(ok: false, message: "Allow Carabiner to control \(Self.browser.appName) under System Settings → Privacy & Security → Automation, then try again"))
            return
        case .nothing:
            notifier.show(GrabResult(ok: false, message: "No link in your browser tab or clipboard"))
            return
        }
        busy = true
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let result = self.runner.run(url: url)
            DispatchQueue.main.async {
                self.notifier.show(result)
                self.busy = false
            }
        }
    }
}
