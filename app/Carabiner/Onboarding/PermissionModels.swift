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
enum PermissionRow: CaseIterable {
    case notifications, browserAccess, carouselDialog

    enum Tick { case pending, ok, cross }
    enum Action: Equatable { case request, openSystemSettings, none }

    var title: String {
        switch self {
        case .notifications:  return "Notifications"
        case .browserAccess:  return "Browser access"
        case .carouselDialog: return "Carousel dialog"
        }
    }

    var why: String {
        switch self {
        case .notifications:  return "So you see when a grab finishes — or why it didn't."
        case .browserAccess:  return "To read the address of the post you're looking at."
        case .carouselDialog: return "So Carabiner can ask 'this slide or the whole set?'."
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
                                   detail: "Chrome will open first")
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
