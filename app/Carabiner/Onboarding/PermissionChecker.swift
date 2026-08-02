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
                let s: PermissionStatus
                switch settings.authorizationStatus {
                case .authorized, .provisional: s = .granted
                case .denied:                   s = .denied
                default:                        s = .notDetermined
                }
                DispatchQueue.main.async { completion(s) }
            }
        case .browserAccess:
            automation(bundleId: browser.bundleId, ask: false, completion: completion)
        case .carouselDialog:
            automation(bundleId: Self.systemEventsId, ask: false, completion: completion)
        }
    }

    func request(_ row: PermissionRow, completion: @escaping (PermissionStatus) -> Void) {
        switch row {
        case .notifications:
            UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, error in
                if let error { NSLog("Carabiner: notification authorization failed: %@", error.localizedDescription) }
                DispatchQueue.main.async { completion(granted ? .granted : .denied) }
            }
        case .browserAccess:
            // The Automation prompt only appears while the target is running.
            ensureRunning(bundleId: browser.bundleId) { [browser] running in
                guard running else { completion(.targetNotRunning); return }
                self.automation(bundleId: browser.bundleId, ask: true, completion: completion)
            }
        case .carouselDialog:
            // System Events is an always-available agent; no launch dance needed.
            automation(bundleId: Self.systemEventsId, ask: true, completion: completion)
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
