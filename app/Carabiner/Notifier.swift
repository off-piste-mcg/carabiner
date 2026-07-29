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

    func show(_ result: GrabResult) {
        let content = UNMutableNotificationContent()
        content.title = "Carabiner"
        // Subtitle carries the verdict, body the detail the script actually reported
        // (a filename, a directory, a reason) — they must not repeat each other.
        content.subtitle = result.ok ? "✓ Saved" : "✗ Grab failed"
        content.body = result.message
        let req = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(req) { error in
            if let error {
                NSLog("Carabiner: couldn't post notification: %@", error.localizedDescription)
            }
        }
    }
}
