import UserNotifications

struct Notifier {
    func requestAuthorization() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    func show(_ result: GrabResult) {
        let content = UNMutableNotificationContent()
        content.title = "Carabiner"
        content.subtitle = result.ok ? "✓ Saved to Downloads" : "✗ Grab failed"
        content.body = result.message
        let req = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(req)
    }
}
