import AppKit
import UserNotifications

/// The seam between the setup window and the OS. Everything behind it is a thin
/// wrapper over TCC/UNUserNotificationCenter — deliberately untested (the OS owns the
/// behaviour); everything in front of it is pure and tested.
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

    init(browser: Browser) { self.browser = browser }

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
        }
    }

    func openSystemSettings(for row: PermissionRow) {
        let url: String
        switch row {
        case .notifications:
            url = "x-apple.systempreferences:com.apple.preference.notifications"
        case .browserAccess, .carouselDialog:
            url = "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation"
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
