import AppKit
import UserNotifications

/// The seam between the setup window and the OS. Everything behind it is a thin
/// wrapper over TCC/UNUserNotificationCenter — deliberately untested (the OS owns the
/// behaviour); everything in front of it is pure and tested.
///
/// Threading contract (review fix round 1, "ALSO FIX" — this was previously undocumented):
/// `status`/`request` may be CALLED from any thread, but the completion is guaranteed to
/// land on the main queue. That is the only guarantee — it says nothing about what happens
/// on the calling thread before a given implementation hops to main. `LivePermissionChecker`
/// relies on this for `.browserButton`: it reads `lastSeen()` synchronously, on whichever
/// thread `status(for:)` was called on, before dispatching the completion to main. That is
/// correct only because every caller today (`OnboardingViewModel`, `@MainActor`) happens to
/// call in from main already, which is what makes `GrabServer.lastSeen`'s own main-queue
/// confinement safe to read there. A future caller off the main queue would break that
/// silently — if `status`/`request` ever need to be called from a background queue, this
/// protocol needs an explicit "callable from any thread, including reads before the main
/// hop" contract enforced by every conforming type, not just relied upon by convention.
protocol PermissionChecking {
    /// Passive: never shows a prompt. Completion on the main queue.
    func status(for row: PermissionRow, completion: @escaping (PermissionStatus) -> Void)
    /// Active: shows the OS prompt (launching the browser first when it must be
    /// running for the prompt to appear). Completion on the main queue.
    func request(_ row: PermissionRow, completion: @escaping (PermissionStatus) -> Void)
    func openSystemSettings(for row: PermissionRow)
}

final class LivePermissionChecker: PermissionChecking {
    private let browser: Browser
    private static let systemEventsId = "com.apple.systemevents"
    /// How the browserButton row learns whether an extension has genuinely reached the app.
    /// Read fresh on every status check, never cached — a browser that stops checking in
    /// (or never started) has to fall back to notDetermined on its own, not stay stuck on
    /// whatever the last read happened to be. Defaults to an empty dictionary so nothing
    /// that never touches `.browserButton` (every existing call site, every existing test)
    /// has to know this parameter exists.
    private let lastSeen: () -> [String: Date]

    /// The extension server's own bind outcome (Finding 2, final review) — read fresh on
    /// every status check, same discipline as `lastSeen` and for the same reason: a server
    /// that fails to bind AFTER this checker already exists must not keep reporting
    /// whatever it last saw. Defaults to `.listening` (nothing wrong) so every existing
    /// call site and test, none of which exercised this path, is unaffected.
    private let serverState: () -> GrabServer.State

    init(browser: Browser, lastSeen: @escaping () -> [String: Date] = { [:] },
         serverState: @escaping () -> GrabServer.State = { .listening }) {
        self.browser = browser
        self.lastSeen = lastSeen
        self.serverState = serverState
    }

    /// The exact read a Safari-cookie grab makes. Existence alone proves nothing (a denied
    /// process can often still `stat` a protected file); only a real, successful `open()`
    /// counts as granted — matching the project's "a green tick means a real check" rule.
    private static let safariCookiesPath = NSHomeDirectory()
        + "/Library/Containers/com.apple.Safari/Data/Library/Cookies/Cookies.binarycookies"

    /// The untested OS-facing wrapper: makes the real syscall, hands the outcome to the
    /// pure `fullDiskAccessStatus(fd:errno:)` (PermissionModels.swift) where the
    /// EPERM/ENOENT/success split actually lives and is tested.
    private static func detectFullDiskAccessStatus() -> PermissionStatus {
        let fd = open(safariCookiesPath, O_RDONLY)
        if fd >= 0 { close(fd) }
        return fullDiskAccessStatus(fd: fd, errno: errno)
    }

    func status(for row: PermissionRow, completion: @escaping (PermissionStatus) -> Void) {
        switch row {
        case .notifications:
            UNUserNotificationCenter.current().getNotificationSettings { settings in
                let s = notificationStatus(authorization: settings.authorizationStatus,
                                           alert: settings.alertSetting)
                DispatchQueue.main.async { completion(s) }
            }
        case .browserAccess:
            automation(bundleId: browser.bundleId, ask: false, completion: completion)
        case .carouselDialog:
            // Start System Events before asking, or a granted permission reads as off:
            // the API cannot distinguish "target stopped" from "refused", and System
            // Events idles out within about a minute. See mayLaunchTargetForStatusCheck.
            ensureRunning(bundleId: Self.systemEventsId) { running in
                guard running else { completion(.targetNotRunning); return }
                self.automation(bundleId: Self.systemEventsId, ask: false, completion: completion)
            }
        case .browserButton:
            // ANY known browser counts (Finding 1) — reading only the single browser
            // MenuBarController happens to have configured for cookies would silently
            // orphan every other browser's check-ins, Safari's included. `serverState()`
            // (Finding 2, final review) is what actually turns a port collision into a
            // visible row instead of a button that silently does nothing.
            let s = browserButtonStatus(lastSeen: mostRecentBrowserCheckIn(lastSeen()), now: Date(),
                                        serverState: serverState())
            DispatchQueue.main.async { completion(s) }
        case .fullDiskAccess:
            // Off-main, matching `automation(bundleId:ask:)` — `open()` on a TCC-protected
            // path is a tccd round-trip, the same class of "not free" work that rule
            // exists for (review fix round 1, "ALSO FIX").
            DispatchQueue.global(qos: .userInitiated).async {
                let s = Self.detectFullDiskAccessStatus()
                DispatchQueue.main.async { completion(s) }
            }
        }
    }

    func request(_ row: PermissionRow, completion: @escaping (PermissionStatus) -> Void) {
        switch row {
        case .notifications:
            // The `granted` flag is deliberately ignored. It reports what the prompt
            // returned, not what the system ended up with — on 2026-08-11 a user allowed
            // the prompt and still had "Allow notifications" switched off, so the row went
            // green while nothing was ever delivered. Ask the OS what is actually true.
            UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, error in
                if let error { NSLog("Carabiner: notification authorization failed: %@", error.localizedDescription) }
                UNUserNotificationCenter.current().getNotificationSettings { settings in
                    let s = notificationStatus(authorization: settings.authorizationStatus,
                                               alert: settings.alertSetting)
                    DispatchQueue.main.async { completion(s) }
                }
            }
        case .browserAccess, .carouselDialog:
            // Both Automation rows take the same path: the prompt only appears while the
            // target is running, and the OS returns procNotFound with no prompt otherwise.
            // System Events used to skip this on the belief it was always available — it
            // is an on-demand agent that quits when idle, so the carousel switch could
            // never be turned on. See PermissionRow.requiresRunningTarget.
            let bundleId = row == .browserAccess ? browser.bundleId : Self.systemEventsId
            ensureRunning(bundleId: bundleId) { running in
                guard running else { completion(.targetNotRunning); return }
                self.automation(bundleId: bundleId, ask: true, completion: completion)
            }
        case .browserButton:
            // Unreachable in practice: OnboardingViewModel.setEnabled intercepts
            // `.browserButton` before it ever calls `request` — installing/managing the
            // extension is opening a web page or Safari's extension prefs, neither of
            // which is a TCC permission this seam exists to wrap. Kept only so the switch
            // stays exhaustive; report the real status rather than guessing if it ever
            // does fire.
            status(for: row, completion: completion)
        case .fullDiskAccess:
            // Unreachable via PermissionRow.intent (canBePrompted is false, so `desired:
            // true` never produces `.request`). Fall back to the one real action —
            // deep-link — so an exhaustive switch doesn't have to mean "does nothing".
            openSystemSettings(for: row)
            status(for: row, completion: completion)
        }
    }

    func openSystemSettings(for row: PermissionRow) {
        let url: String
        switch row {
        case .notifications:
            url = "x-apple.systempreferences:com.apple.preference.notifications"
        case .browserAccess, .carouselDialog:
            url = "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation"
        case .browserButton:
            // Handled by OnboardingViewModel.installBrowserButton() before this is reached
            // (see the `.request` comment above) — there is no System Settings pane for an
            // extension the user can also just uninstall from the browser itself.
            return
        case .fullDiskAccess:
            url = fullDiskAccessSettingsURL
        }
        if let u = URL(string: url) { NSWorkspace.shared.open(u) }
    }

    /// AEDeterminePermissionToAutomateTarget blocks (with ask=true, for as long as the
    /// prompt is up), so it always runs off the main thread.
    private func automation(bundleId: String, ask: Bool,
                            completion: @escaping (PermissionStatus) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let target = NSAppleEventDescriptor(bundleIdentifier: bundleId)
            let err = AEDeterminePermissionToAutomateTarget(target.aeDesc, typeWildCard, typeWildCard, ask)
            let s: PermissionStatus
            switch Int(err) {
            case Int(noErr):          s = .granted
            case -1744:               s = .notDetermined   // errAEEventWouldRequireUserConsent
            case Int(procNotFound):   s = .targetNotRunning // -600: target not running — TCC can't even report
            default:                  s = .denied           // -1743 errAEEventNotPermitted et al
            }
            DispatchQueue.main.async { completion(s) }
        }
    }

    private func ensureRunning(bundleId: String, then: @escaping (Bool) -> Void) {
        if !NSRunningApplication.runningApplications(withBundleIdentifier: bundleId).isEmpty {
            DispatchQueue.main.async { then(true) }; return
        }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) else {
            DispatchQueue.main.async { then(false) }; return
        }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration()) { app, _ in
            DispatchQueue.main.async { then(app != nil) }
        }
    }
}
