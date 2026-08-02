import AppKit

final class MenuBarController: NSObject {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let notifier = Notifier()
    /// One browser for the whole flow. The tab we read the URL from has to be the same
    /// one `carabiner` pulls cookies from, so both sides are built from this constant.
    /// Phase 2 turns it into a picker.
    private static let browser: Browser = .chrome
    private let tabReader = TabReader(browser: MenuBarController.browser)
    private var runner = GrabRunner(browser: MenuBarController.browser)
    private var busy = false
    private var ring: RingAnimator!
    /// Whether this grab's ring has begun. The ring only exists once real work is
    /// happening (see the comment in `grab()`); reset per grab.
    private var ringStarted = false
    /// One-shot: set by the setup window's hotkey test. When present, the next hotkey
    /// fire is a test, not a grab — consumed before anything else in grab().
    var hotkeyTestHandler: (() -> Void)?
    private var onboarding: OnboardingWindowController?

    override init() {
        super.init()
        let renderer = StatusIconRenderer(mark: NSImage(named: "StatusIcon"))
        // A missing asset would leave a blank, unexplained gap in the menu bar, so say so.
        if renderer.mark == nil { NSLog("Carabiner: StatusIcon asset missing — status item has no image") }
        ring = RingAnimator(button: statusItem.button, renderer: renderer)
        let menu = NSMenu()
        let grabItem = NSMenuItem(title: "Grab current tab", action: #selector(grab), keyEquivalent: "")
        grabItem.target = self
        menu.addItem(grabItem)
        let setupItem = NSMenuItem(title: "Setup & Permissions…", action: #selector(showOnboarding), keyEquivalent: "")
        setupItem.target = self
        menu.addItem(setupItem)
        menu.addItem(.separator())
        // No explicit target: lets this route up the responder chain to NSApp, which
        // implements terminate:. MenuBarController itself does not, so an explicit
        // target here would leave AppKit's autoenablesItems disabling the item.
        menu.addItem(NSMenuItem(title: "Quit Carabiner", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        statusItem.menu = menu
    }

    @objc func showOnboarding() {
        if onboarding == nil {
            onboarding = OnboardingWindowController(
                checker: LivePermissionChecker(browser: Self.browser),
                hotkeyIntercept: { [weak self] handler in self?.hotkeyTestHandler = handler },
                clearIntercept: { [weak self] in self?.hotkeyTestHandler = nil })
        }
        onboarding?.show()
    }

    @objc func grab() {
        if let test = hotkeyTestHandler {
            hotkeyTestHandler = nil
            test()
            return
        }
        // Every outcome below is reported by notification, so if notifications are
        // unavailable the app has no voice at all — a failed grab looks exactly like a
        // dead hotkey. Log each outcome too, so the app stays diagnosable without it.
        guard !busy else {
            NSLog("Carabiner: grab ignored — a grab is already running")
            return
        }
        // The ring does NOT begin here. It reads as "downloading", so it waits for the
        // first progress event that is actual work (`beginsActivity` — download, item or
        // convert): starting it at the hotkey meant it crept through the carousel probe
        // and sat frozen beside the dialog, both of which read as a download that had
        // already begun. Immediate feedback is the working banner's job (grabStarted(),
        // next line); the failure paths below call ring.finish() unconditionally, which
        // is a no-op on a ring that never began.
        ringStarted = false
        // Before reading the tab, not after: resolve() drives AppleScript on this thread
        // and is itself part of the delay the user is waiting through. Any outcome below
        // takes this banner down and posts its own, so an early failure still shows
        // exactly one notification.
        notifier.grabStarted()
        let url: String
        switch tabReader.resolve() {
        case .url(let u):
            url = u
        case .notAuthorized:
            NSLog("Carabiner: grab aborted — not authorised to control %@", Self.browser.appName)
            notifier.finished(GrabResult(ok: false, message: "Allow Carabiner to control \(Self.browser.appName) under System Settings → Privacy & Security → Automation, then try again"))
            ring.finish(success: false)
            return
        case .nothing:
            NSLog("Carabiner: grab aborted — no URL in the front tab or the clipboard")
            notifier.finished(GrabResult(ok: false, message: "No link in your browser tab or clipboard"))
            ring.finish(success: false)
            return
        }
        NSLog("Carabiner: grabbing %@", url)
        busy = true
        runner.onProgress = { [weak self] event in
            // onProgress arrives on GrabRunner's background queue; the ring and the
            // notifier's planner state are both main-only.
            DispatchQueue.main.async {
                guard let self else { return }
                if !self.ringStarted, event.beginsActivity {
                    self.ringStarted = true
                    self.ring.begin()
                }
                // Events before the ring exists (probe, prompt) are the notifier's story
                // only — feeding them to a never-begun ring would be harmless today, but
                // the gate keeps "no ring" and "ring ignores this" from blurring.
                if self.ringStarted { self.ring.handle(event) }
                self.notifier.handle(event)
            }
        }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let result = self.runner.run(url: url)
            DispatchQueue.main.async {
                NSLog("Carabiner: grab %@ — %@",
                      result.ok ? "succeeded" : (result.cancelled ? "cancelled" : "failed"),
                      result.message)
                self.ring.finish(success: result.ok)
                self.notifier.finished(result)
                self.busy = false
            }
        }
    }
}
