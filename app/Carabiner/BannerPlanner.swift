import Foundation

/// One thing the notifier should do next. Pure data so the policy is unit-testable:
/// UNUserNotificationCenter only works inside a signed, LaunchServices-launched bundle,
/// which a test runner is not.
enum BannerAction: Equatable {
    /// Post or update the working banner (one fixed identifier for the whole grab).
    case postWorking(body: String)
    /// Take the working banner down — nothing is being worked on right now.
    case removeWorking
    /// Post the grab's outcome as a fresh banner.
    case postOutcome(ok: Bool, message: String)
}

/// Decides what the banners say, and when, from the same progress events that drive the
/// ring. The point is honesty: the working banner exists only while work is actually
/// happening, and its body names the stage — so the carousel dialog is never upstaged by
/// a banner claiming a download that hasn't started.
struct BannerPlanner {
    /// Body of the working banner currently up, `nil` when it has been removed. Doubles
    /// as the churn guard: yt-dlp reports percentages several times a second, and the
    /// banner is stage-level feedback, not a progress bar.
    private var currentBody: String?

    mutating func grabStarted() -> [BannerAction] {
        currentBody = nil
        return post("Reading the link…")
    }

    mutating func handle(_ event: ProgressEvent) -> [BannerAction] {
        switch event {
        case .probe:
            return post("Checking the post…")
        case .prompt:
            // The dialog is the UI while it is up; a "Grabbing…" banner beside a question
            // that is waiting on the user is exactly the misalignment this type removes.
            // Removing the banner also makes the re-post after the user's choice present
            // as a genuinely new banner instead of a silent replacement.
            currentBody = nil
            return [.removeWorking]
        case .download:
            return post("Saving to Downloads")
        case .item(let index, let total):
            // `item:1:1` is a single-slide grab through gallery-dl; "slide 1 of 1" would
            // read as a bug, and the download body already covers it.
            return post(total > 1 ? "Saving slide \(index) of \(total)…" : "Saving to Downloads")
        case .convert, .save:
            // Both are part of "saving" as far as a banner is concerned.
            return []
        }
    }

    mutating func finished(_ result: GrabResult) -> [BannerAction] {
        currentBody = nil
        // Cancelling the carousel dialog is a deliberate act, not an outcome to report.
        if result.cancelled { return [.removeWorking] }
        return [.postOutcome(ok: result.ok, message: result.message)]
    }

    private mutating func post(_ body: String) -> [BannerAction] {
        guard body != currentBody else { return [] }
        currentBody = body
        return [.postWorking(body: body)]
    }
}
