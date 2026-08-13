import Foundation
import UserNotifications

/// Executes BannerPlanner's decisions against UNUserNotificationCenter. The policy lives
/// in the planner (pure, tested); this type only knows how to post, update and remove.
///
/// Main-thread only: the planner is mutable state, and every caller already hops to the
/// main queue for the ring.
final class Notifier {
    private var planner = BannerPlanner()
    /// The outcome banner still sitting in Notification Centre from the *previous* grab,
    /// removed when the next outcome posts so Carabiner never accumulates history there.
    private var lastOutcomeId: String?

    /// Immediate acknowledgement that the hotkey landed. A grab is not fast, and until
    /// something appears a slow grab and a hotkey that never fired are indistinguishable —
    /// which is exactly what a lost chord looks like (gotcha #14).
    func grabStarted() { execute(planner.grabStarted()) }

    /// Keeps the banner aligned with what the script says it is doing — including taking
    /// it *down* while the carousel dialog is waiting on the user.
    func handle(_ event: ProgressEvent) { execute(planner.handle(event)) }

    func finished(_ result: GrabResult) { execute(planner.finished(result)) }

    private func execute(_ actions: [BannerAction]) {
        let center = UNUserNotificationCenter.current()
        for action in actions {
            switch action {
            case .postWorking(let body):
                let content = UNMutableNotificationContent()
                content.title = "Carabiner"
                content.subtitle = "Grabbing…"
                content.body = body
                // One fixed identifier for the working banner: while it is on screen a
                // re-post updates it in place, and once it has scrolled off, stage updates
                // amend Notification Centre silently — right for progress, and exactly why
                // the OUTCOME must never reuse this identifier (see .postOutcome).
                add(content, id: Self.workingId, to: center)

            case .removeWorking:
                center.removeDeliveredNotifications(withIdentifiers: [Self.workingId])

            case .postOutcome(let ok, let message, let user, let usedFallbackBrowser):
                let content = UNMutableNotificationContent()
                content.title = "Carabiner"
                // Subtitle carries the verdict, body the detail the script actually
                // reported (a filename, a directory, a reason) — never each other's text.
                content.subtitle = Self.outcomeSubtitle(ok: ok, user: user,
                                                        usedFallbackBrowser: usedFallbackBrowser)
                content.body = message
                // A FRESH identifier every time, and this is load-bearing: posting with an
                // already-delivered identifier *replaces* that notification in Notification
                // Centre without presenting a new banner. The old same-id scheme therefore
                // showed "✓ Saved" only while "Grabbing…" was still on screen — fast single
                // grabs — and swallowed it for every carousel. Fresh id + explicit removal
                // of the stale banners gets both: a banner that always presents, and no
                // stacked leftovers.
                let id = UUID().uuidString
                var stale = [Self.workingId]
                if let lastOutcomeId { stale.append(lastOutcomeId) }
                center.removeDeliveredNotifications(withIdentifiers: stale)
                lastOutcomeId = id
                add(content, id: id, to: center)
            }
        }
    }

    private func add(_ content: UNMutableNotificationContent, id: String, to center: UNUserNotificationCenter) {
        center.add(UNNotificationRequest(identifier: id, content: content, trigger: nil)) { error in
            if let error {
                NSLog("Carabiner: couldn't post notification: %@", error.localizedDescription)
            }
        }
    }

    private static let workingId = "com.offpiste.carabiner.grab"

    /// The verdict line. Static and pure so the one piece of banner *copy* with logic in
    /// it is testable — UNUserNotificationCenter itself only works in a signed,
    /// LaunchServices-launched bundle. A failure never names the account: "Grab failed
    /// from @x" reads as blame, and the message line already says what went wrong.
    ///
    /// `usedFallbackBrowser` (Finding 4, review fix round 1): staying silent about a
    /// Safari grab actually having used Chrome's session is an honesty problem, not a
    /// cosmetic one — it can mean a different Instagram account, so what landed in
    /// Downloads might not be what the user was looking at. Hardcoded to "Chrome" rather
    /// than a per-browser name: `GrabRunner.shouldRetryWithChrome` only ever retries with
    /// `.chrome` today, so there is exactly one fallback browser this can ever name: if
    /// that ever changes, this needs a real name-mapping, not a guess.
    static func outcomeSubtitle(ok: Bool, user: String?, usedFallbackBrowser: Browser? = nil) -> String {
        guard ok else { return "✗ Grab failed" }
        var subtitle = user.map { "✓ Saved from \($0)" } ?? "✓ Saved"
        if usedFallbackBrowser != nil { subtitle += " — used Chrome's login" }
        return subtitle
    }
}
