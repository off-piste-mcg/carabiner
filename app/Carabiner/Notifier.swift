import Foundation
import UserNotifications

struct Notifier {
    func requestAuthorization() {
        // Phase 1 builds are unsigned, and UNUserNotificationCenter is historically
        // unreliable for unsigned bundles. The banner *is* the feature, so a refusal
        // has to leave a trace — otherwise every grab just silently says nothing.
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, error in
            if let error {
                NSLog("Carabiner: notification authorization failed: %@", error.localizedDescription)
            } else {
                NSLog("Carabiner: notification authorization %@", granted ? "granted" : "denied")
            }
        }
    }

    /// Immediate acknowledgement that the hotkey landed.
    ///
    /// A grab is not fast: reading the browser tab, extracting its cookies, the download
    /// itself and sometimes a re-encode all happen before there is anything to report. With
    /// no banner until the end, a slow grab is indistinguishable from a hotkey that never
    /// fired — which is exactly what a lost chord looks like (gotcha #14), so the one
    /// failure we most need to be legible is the one this silence imitates.
    func showWorking() {
        let content = UNMutableNotificationContent()
        content.title = "Carabiner"
        content.subtitle = "Grabbing…"
        content.body = "Saving to Downloads"
        post(content)
    }

    func show(_ result: GrabResult) {
        let content = UNMutableNotificationContent()
        content.title = "Carabiner"
        // Subtitle carries the verdict, body the detail the script actually reported
        // (a filename, a directory, a reason) — they must not repeat each other.
        content.subtitle = result.ok ? "✓ Saved" : "✗ Grab failed"
        content.body = result.message
        post(content)
    }

    private func post(_ content: UNMutableNotificationContent) {
        // One identifier for every banner in a grab, deliberately. Re-using it makes the
        // outcome *replace* the "Grabbing…" banner in place; a fresh UUID each time would
        // leave both stacked in Notification Centre, so every grab would litter two
        // entries and the stale "Grabbing…" would outlive the thing it described.
        let req = UNNotificationRequest(identifier: Self.grabIdentifier, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(req) { error in
            if let error {
                NSLog("Carabiner: couldn't post notification: %@", error.localizedDescription)
            }
        }
    }

    private static let grabIdentifier = "com.offpiste.carabiner.grab"
}
