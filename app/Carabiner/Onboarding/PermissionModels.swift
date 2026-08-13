import Foundation
import UserNotifications

/// The four states a permission row can be in. `targetNotRunning` exists because the
/// Automation prompt (and even the passive check) needs the target app alive — a closed
/// Chrome is indistinguishable from "never asked", so it presents as pending, not broken.
enum PermissionStatus: Equatable {
    case notDetermined, granted, denied, targetNotRunning
}

/// The permission rows of the setup window. The hotkey test is NOT one of these — it has
/// its own state machine (HotkeyTestModel); nothing about it is a TCC permission.
///
/// `fullDiskAccess` is unlike the other four: macOS provides no API to grant it and — unlike
/// Automation — no way to even *prompt* for it. It exists purely so Safari users have a
/// discoverable, live-status row to fix the thing that otherwise makes the button silently
/// decorative for them (Safari's cookie jar lives in a TCC-protected container; see
/// GrabRunner's shouldRetryWithChrome for the Chrome-cookie fallback this row is the
/// permanent fix for).
enum PermissionRow: CaseIterable {
    case notifications, browserAccess, carouselDialog, browserButton, fullDiskAccess

    enum Tick { case pending, ok, cross }
    enum Action: Equatable { case request, openSystemSettings, none }

    var title: String {
        switch self {
        case .notifications:  return "Notifications"
        case .browserAccess:  return "Browser access"
        case .carouselDialog: return "Carousel dialog"
        case .browserButton:  return "Instagram button"
        case .fullDiskAccess: return "Full Disk Access"
        }
    }

    var why: String {
        switch self {
        case .notifications:  return "So you see when a grab finishes — or why it didn't."
        case .browserAccess:  return "To read the address of the post you're looking at."
        case .carouselDialog: return "So Carabiner can ask 'this slide or the whole set?'."
        case .browserButton:  return "So you can save a post straight from your feed."
        case .fullDiskAccess: return "Safari keeps its cookies in a protected folder — Carabiner needs this to read them."
        }
    }

    /// Whether the Automation prompt needs its target app alive before we ask.
    ///
    /// AEDeterminePermissionToAutomateTarget returns procNotFound (-600) and shows NOTHING
    /// when the target is not running, even with ask: true — so asking without launching
    /// first is a silent no-op that leaves the row exactly where it was.
    ///
    /// This used to be true only for the browser: System Events was assumed to be an
    /// "always-available agent" needing no launch. It is not — it is an on-demand agent
    /// that quits when idle, so the carousel row could never be turned on (measured
    /// 2026-08-11: -600 with it stopped, 0 once launched). The rule is a property of the
    /// row now rather than a comment in one branch.
    var requiresRunningTarget: Bool {
        switch self {
        case .notifications, .browserButton, .fullDiskAccess: return false
        case .browserAccess, .carouselDialog:                 return true
        }
    }

    /// Whether we may start the target during a PASSIVE status check, not just when the
    /// user asks for the grant.
    ///
    /// This matters because a stopped target is indistinguishable from a refused one:
    /// both come back procNotFound, so the row renders as off even when the permission is
    /// granted. System Events idles out within about a minute, so the carousel row would
    /// spontaneously read off for most of the app's life.
    ///
    /// Only true for System Events — a faceless system agent macOS starts constantly, so
    /// starting it to answer a question costs nothing and is invisible. Never true for the
    /// browser: launching Chrome because someone opened a settings window would be
    /// obnoxious, and there the honest "Chrome will open first" note covers it instead.
    var mayLaunchTargetForStatusCheck: Bool { self == .carouselDialog }

    /// What to warn while the target is not yet running, named per row — telling the
    /// carousel row that "Chrome will open first" was simply false.
    var targetLaunchNote: String? {
        switch self {
        case .notifications, .browserButton, .fullDiskAccess: return nil
        case .browserAccess:                                  return "Chrome will open first"
        case .carouselDialog:                                 return "System Events will start first"
        }
    }

    func presentation(for status: PermissionStatus) -> RowPresentation {
        switch status {
        case .granted:
            return RowPresentation(tick: .ok, buttonTitle: nil, action: .none, detail: nil)
        case .denied:
            return RowPresentation(tick: .cross, buttonTitle: "Open System Settings",
                                   action: .openSystemSettings, detail: nil)
        case .notDetermined:
            return RowPresentation(tick: .pending, buttonTitle: "Allow", action: .request, detail: nil)
        case .targetNotRunning:
            return RowPresentation(tick: .pending, buttonTitle: "Allow", action: .request,
                                   detail: targetLaunchNote)
        }
    }
}

struct RowPresentation: Equatable {
    let tick: PermissionRow.Tick
    let buttonTitle: String?
    let action: PermissionRow.Action
    let detail: String?
}

/// The notifications row's verdict, kept pure so it can be tested — the OS values it
/// judges come from APIs a test runner cannot drive.
///
/// Granted requires BOTH that we are authorized AND that alerts are actually visible.
/// Authorization can be on while the alert style is "None", in which case notifications
/// land silently in Notification Centre and never appear on screen. For Carabiner that is
/// indistinguishable from broken: the banner is the whole feature, and a grab that
/// finishes invisibly looks exactly like a hotkey that never fired (gotchas #14, #22).
///
/// Both failures return .denied rather than a new case, because the user's action is the
/// same either way — open System Settings and fix it.
func notificationStatus(authorization: UNAuthorizationStatus,
                        alert: UNNotificationSetting) -> PermissionStatus {
    switch authorization {
    case .authorized, .provisional:
        return alert == .enabled ? .granted : .denied
    case .denied:
        return .denied
    default:
        return .notDetermined
    }
}

/// Green means a browser's extension has genuinely reached the app — never a guess about
/// whether something is "probably installed". A stale check-in is not proof: two weeks
/// covers a normal gap between grabs without letting a browser that was uninstalled months
/// ago keep reading as connected forever.
func browserButtonStatus(lastSeen: Date?, now: Date,
                         freshness: TimeInterval = 60 * 60 * 24 * 14) -> PermissionStatus {
    guard let lastSeen, now.timeIntervalSince(lastSeen) < freshness else { return .notDetermined }
    return .granted
}

/// Full Disk Access has no System Settings identifier of its own on the automation scheme —
/// this is the pane's real anchor, verified against System Settings' own deep-link scheme.
let fullDiskAccessSettingsURL = "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles"

/// What flipping a row's switch should actually do.
///
/// macOS gives an app no way to revoke its own grants, and no way to grant one that was
/// already refused — `requestAuthorization` returns immediately once the user has decided,
/// without showing anything. So only one of these three transitions can be performed in
/// process; the rest hand off to System Settings, which is the sole place the user can
/// actually change their mind.
enum ToggleIntent: Equatable {
    /// Ask the OS to prompt. Only legal from an undecided state.
    case request
    /// Deep-link to the relevant System Settings pane — the switch will not move until
    /// the user changes it there, which is the honest outcome.
    case openSystemSettings
    /// Already in the requested state.
    case nothing
}

func toggleAction(desired: Bool, status: PermissionStatus) -> ToggleIntent {
    if desired {
        switch status {
        case .granted:                        return .nothing
        case .notDetermined, .targetNotRunning: return .request
        case .denied:                         return .openSystemSettings
        }
    } else {
        // Turning OFF is never something we can do ourselves, whatever the current state.
        return status == .granted ? .openSystemSettings : .nothing
    }
}

extension PermissionRow {
    /// Most rows can trigger their own OS prompt, so they defer to the shared rule.
    /// A row that macOS provides no way to prompt for can only deep-link — and that has to
    /// win even at `.notDetermined`, where every other row would ask `toggleAction` to
    /// `.request`. There is nothing to request: `fullDiskAccess` has no `requestAuthorization`
    /// equivalent, ever.
    func intent(desired: Bool, status: PermissionStatus) -> ToggleIntent {
        guard desired else { return toggleAction(desired: desired, status: status) }
        return canBePrompted ? toggleAction(desired: desired, status: status) : .openSystemSettings
    }

    var canBePrompted: Bool {
        switch self {
        case .notifications, .browserAccess, .carouselDialog, .browserButton: return true
        case .fullDiskAccess:                                                 return false
        }
    }
}

extension PermissionRow.Tick {
    /// Verified present on the macOS 13 floor by PermissionModelsTests.
    var symbolName: String {
        switch self {
        case .ok:      return "checkmark.circle.fill"
        case .cross:   return "exclamationmark.triangle.fill"
        case .pending: return "circle.dotted"
        }
    }

    /// Drives the row's tint. Only a cross is a problem the user must act on; pending is
    /// merely "not asked yet" and should not read as an error.
    var isFailure: Bool { self == .cross }
}
