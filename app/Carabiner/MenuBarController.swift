import AppKit

final class MenuBarController: NSObject {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let notifier = Notifier()
    private let tabReader = TabReader(browser: .chrome)
    private let runner = GrabRunner()
    private var busy = false

    override init() {
        super.init()
        if let button = statusItem.button {
            button.image = NSImage(named: "AppIcon")
            button.image?.size = NSSize(width: 18, height: 18)
            button.image?.isTemplate = false
        }
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Grab current tab", action: #selector(grab), keyEquivalent: ""))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit Carabiner", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        menu.items.forEach { $0.target = self }
        statusItem.menu = menu
    }

    @objc func grab() {
        guard !busy else { return }
        guard let url = tabReader.resolve() else {
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
