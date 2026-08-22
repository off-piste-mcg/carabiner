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
    /// One-shot: set by the setup window's hotkey test. When present, the next REAL hotkey
    /// fire is a test, not a grab — consumed in hotkeyFired(), never by the menu item, so
    /// clicking "Grab current tab" can't fake a ✓.
    var hotkeyTestHandler: (() -> Void)?
    private var onboarding: OnboardingWindowController?
    /// Every successful app-driven grab lands here (recorded in the shared grab path's
    /// completion), and the main window renders it.
    private let history = GrabHistoryStore()
    private var mainWindow: MainWindowController?
    /// Set by App.swift once the listener starts. Weak: GrabServer's owner is App.swift,
    /// not this controller — this is read-only access for onboarding (task 9) to report
    /// the server's state, not a second owner.
    weak var grabServer: GrabServer?

    override init() {
        super.init()
        let renderer = StatusIconRenderer(mark: NSImage(named: "StatusIcon"))
        // A missing asset would leave a blank, unexplained gap in the menu bar, so say so.
        if renderer.mark == nil { NSLog("Carabiner: StatusIcon asset missing — status item has no image") }
        ring = RingAnimator(button: statusItem.button, renderer: renderer)
        let menu = NSMenu()
        // Disambiguated: grab() now has a same-named overload (grab(url:browser:...)) for
        // the explicit-URL path, so #selector needs the no-arg signature spelled out.
        let grabItem = NSMenuItem(title: "Grab current tab", action: #selector(grab as () -> Void), keyEquivalent: "")
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

    /// The Dock click's destination. Lazily built like onboarding; the model calls back
    /// into the shared grab path, so a window grab and a hotkey grab are the same grab.
    @objc func showMainWindow() {
        if mainWindow == nil {
            let model = MainViewModel(history: history)
            model.isBusyElsewhere = { [weak self] in self?.busy ?? false }
            model.onGrab = { [weak self] url in self?.grabFromWindow(url: url) }
            // OnboardingViewModel is @MainActor; wrap the construction site minimally.
            // This closure runs on the main queue (Dock click context).
            let settingsModel = MainActor.assumeIsolated {
                OnboardingViewModel(
                    checker: LivePermissionChecker(browser: Self.browser,
                                                   lastSeen: { [weak self] in self?.grabServer?.lastSeen ?? [:] },
                                                   serverState: { [weak self] in self?.grabServer?.state ?? .stopped },
                                                   loginItem: LiveLoginItemController()))
            }
            mainWindow = MainWindowController(model: model, settingsModel: settingsModel)
        }
        mainWindow?.show()
    }

    /// A grab the main window submitted. The model already validated the URL and set its
    /// own in-flight state; this posts the working banner (the window is a non-hotkey
    /// caller, so it goes through notifyGrabStarted like GrabServer does) and feeds
    /// progress and the outcome back to the model.
    private func grabFromWindow(url: String) {
        notifyGrabStarted()
        grab(url: url, browser: Self.browser,
             observer: { [weak self] event in self?.mainWindow?.model.handle(event) },
             completion: { [weak self] result in self?.mainWindow?.model.grabFinished(result) })
    }

    /// A grab arriving from outside any window — today a URL dropped on the Dock icon.
    /// Busy behaves like the hotkey path: log and drop (the working banner of the running
    /// grab is already up; a second banner about refusing would upstage it).
    func grabFromExternal(url: String) {
        guard !busy else {
            NSLog("Carabiner: dropped URL ignored — a grab is already running")
            return
        }
        notifyGrabStarted()
        grab(url: url, browser: Self.browser)
    }

    @objc func showOnboarding() {
        if onboarding == nil {
            onboarding = OnboardingWindowController(
                // `grabServer` is read fresh on every status check (see LivePermissionChecker's
                // `lastSeen` doc comment) rather than captured once here — a closure, not the
                // dictionary itself, is what keeps the browserButton row honest as new
                // requests land after the window is already open.
                checker: LivePermissionChecker(browser: Self.browser,
                                               lastSeen: { [weak self] in self?.grabServer?.lastSeen ?? [:] },
                                               // Finding 2, final review: a closure, not a
                                               // captured value, for the same reason
                                               // `lastSeen` above is one — a port failure
                                               // that happens AFTER this window opens must
                                               // still read live, not whatever `grabServer`
                                               // reported the moment the checker was built.
                                               serverState: { [weak self] in self?.grabServer?.state ?? .stopped },
                                               // Explicit rather than relying on the default,
                                               // so the one real construction site names every
                                               // seam it depends on.
                                               loginItem: LiveLoginItemController()),
                hotkeyIntercept: { [weak self] handler in self?.hotkeyTestHandler = handler },
                clearIntercept: { [weak self] in self?.hotkeyTestHandler = nil })
        }
        onboarding?.show()
    }

    /// The hotkey's entry point. Only a real hotkey fire may satisfy the setup window's
    /// test — the menu item routes straight to grab(), so clicking it during the 10s
    /// listen can't fake a ✓ for a chord that never arrived (the false positive the
    /// test exists to catch).
    @objc func hotkeyFired() {
        if let test = hotkeyTestHandler {
            hotkeyTestHandler = nil
            test()
            return
        }
        grab()
    }

    /// The server refuses a second concurrent grab rather than queueing it — see
    /// GrabServer's 409 path.
    var isBusy: Bool { busy }

    /// The hotkey posts this itself before the tab read; the browser button has no tab
    /// read, so its caller (GrabServer) posts it at the moment the request arrives —
    /// otherwise the user would see no feedback at all during the network round trip
    /// before `grab(url:browser:...)`'s own progress events start arriving.
    func notifyGrabStarted() { notifier.grabStarted() }

    @objc func grab() {
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
        // is a no-op on a ring whose timer was never started — that no-op is governed by
        // RingAnimator's own `timer` state, not by `ringStarted`, so resetting
        // `ringStarted` only in the shared grab(url:browser:...) below (rather than here
        // too) does not change what these early returns do.
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
        grab(url: url, browser: Self.browser)
    }

    /// The shared grab path. The hotkey reaches it after resolving the front tab; a
    /// future non-hotkey caller (the browser-extension server, a later task) will reach
    /// it with a URL the caller already had. Both share `busy`, the ring and the
    /// notifier — two independent paths would double-post banners.
    ///
    /// `grabStarted()` is NOT posted here: the hotkey path posts it itself, before the
    /// AppleScript tab read, because that read is itself part of the wait the working
    /// banner is covering. `notifier` is private, so no other caller can post it that
    /// way today — a future non-hotkey caller will need an internal helper on this class
    /// to post the working banner before calling this method. That helper does not exist
    /// yet and is out of scope here.
    ///
    /// Threading contract (on the caller, not enforced by this method): MUST be called
    /// on the main queue — it reads/writes `busy` and touches `ring` and `notifier`,
    /// none of which are thread-safe. `observer`, `userObserver` and `completion` are
    /// all invoked on the main queue in turn, so a caller on another queue (e.g. an HTTP
    /// server's request-handler queue) must hop to main before calling in, not assume
    /// this method will do it.
    func grab(url: String,
              browser: Browser,
              observer: ((ProgressEvent) -> Void)? = nil,
              userObserver: ((String) -> Void)? = nil,
              completion: ((GrabResult) -> Void)? = nil) {
        // Per-grab state. This is the one place both callers (the hotkey, after its own
        // tab-read failure paths return early, and any future direct caller) funnel
        // through before work begins, and `ringStarted` is read only inside the
        // onProgress closure installed below — so resetting it here, ahead of that
        // closure's installation, is sufficient. It no longer also lives in grab()'s
        // early lines; see the comment there for why removing it doesn't change that
        // method's early-return behaviour.
        ringStarted = false
        NSLog("Carabiner: grabbing %@ (cookies: %@)", url, browser.rawValue)
        busy = true
        // GrabRunner is a struct, so this copy — not a mutation of the shared `runner`
        // property — is what lets each grab set its own `browser` without one caller's
        // choice leaking into another's concurrent-looking-but-actually-serial grab.
        var runner = self.runner
        runner.browser = browser
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
                observer?(event)
            }
        }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let result = runner.run(url: url)
            DispatchQueue.main.async {
                NSLog("Carabiner: grab %@ — %@",
                      result.ok ? "succeeded" : (result.cancelled ? "cancelled" : "failed"),
                      result.message)
                if let user = result.user { userObserver?(user) }
                self.ring.finish(success: result.ok)
                self.notifier.finished(result)
                // The one recording point — hotkey, extension, window and Dock drop all
                // funnel through here. The store ignores failures and cancels itself.
                self.history.record(url: url, result: result)
                self.busy = false
                completion?(result)
            }
        }
    }
}
