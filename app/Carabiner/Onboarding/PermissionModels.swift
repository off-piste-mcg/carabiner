import Foundation
import UserNotifications

/// The states a permission row can be in. `targetNotRunning` exists because the
/// Automation prompt (and even the passive check) needs the target app alive — a closed
/// Chrome is indistinguishable from "never asked", so it presents as pending, not broken.
///
/// `notApplicable` is narrower: today it exists only for `.fullDiskAccess`, for the user
/// who has never run Safari at all — Safari's cookie file (the thing that read is
/// actually checking) does not exist yet, which proves nothing about the grant either way
/// and is a fundamentally different situation from "denied" or "haven't asked yet". A
/// Chrome-only user should not be told they are missing something they will never need
/// (review fix round 1, Finding 3).
enum PermissionStatus: Equatable {
    case notDetermined, granted, denied, targetNotRunning, notApplicable
    /// The extension server (`GrabServer`) failed to bind its port — Finding 2, final
    /// review. Distinct from `.denied`: there is no OS prompt and no System Settings pane
    /// that can fix a port collision, so a row in this state must not offer either. The
    /// associated string is the listener's own failure reason (`NWError.localizedDescription`),
    /// surfaced verbatim so a real port squatter is diagnosable from the row instead of a
    /// button that silently does nothing.
    case serverUnavailable(String)
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
    case notifications, browserAccess, carouselDialog, browserButton, fullDiskAccess, launchAtLogin

    enum Tick { case pending, ok, cross }
    enum Action: Equatable { case request, openSystemSettings, none }

    var title: String {
        switch self {
        case .notifications:  return "Notifications"
        case .browserAccess:  return "Browser access"
        case .carouselDialog: return "Carousel dialog"
        case .browserButton:  return "Instagram button"
        case .fullDiskAccess: return "Full Disk Access"
        case .launchAtLogin:  return "Launch at login"
        }
    }

    var why: String {
        switch self {
        case .notifications:  return "So you see when a grab finishes — or why it didn't."
        case .browserAccess:  return "To read the address of the post you're looking at."
        case .carouselDialog: return "So Carabiner can ask 'this slide or the whole set?'."
        case .browserButton:  return "So you can save a post straight from your feed."
        case .fullDiskAccess: return "Safari keeps its cookies in a protected folder — Carabiner needs this to read them."
        case .launchAtLogin:  return "So Carabiner is already running. Otherwise your browser asks 'Open Carabiner?' every time you use the button."
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
        case .notifications, .browserButton, .fullDiskAccess, .launchAtLogin: return false
        case .browserAccess, .carouselDialog:                                 return true
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
        case .notifications, .browserButton, .fullDiskAccess, .launchAtLogin: return nil
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
        case .notApplicable:
            // No button and no switch to flip — there is genuinely nothing to grant here
            // (review fix round 1, Finding 3). `.ok`-shaped rather than `.pending`: this is
            // a settled, fine state, not something still waiting on the user.
            return RowPresentation(tick: .ok, buttonTitle: nil, action: .none,
                                   detail: "Only needed if you use Safari")
        case .serverUnavailable(let reason):
            // Finding 2, final review: no action can fix a port collision from in here —
            // no OS prompt, no Settings pane. Offering "Allow" would be a dead button;
            // offering "Open System Settings" would send the user to a pane with nothing
            // relevant in it. State the failure and stop — `.cross`, because unlike
            // `.notApplicable` this genuinely is a problem worth flagging.
            return RowPresentation(tick: .cross, buttonTitle: nil, action: .none,
                                   detail: "Can't listen for the extension — \(reason)")
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
///
/// A FUTURE check-in is not proof either (review fix round 2, Finding 4). `lastSeen` is now
/// persisted (round 1, Finding 2), so this stopped being a theoretical edge case: a clock
/// that jumps backward, or a hand-edited/corrupted UserDefaults value, used to self-heal on
/// the next relaunch when the dictionary was in-memory only — persistence made a bad
/// timestamp durable. `elapsed < 0` means `lastSeen` is after `now`, which is never a
/// legitimate check-in.
///
/// `serverState` is checked FIRST, before `lastSeen` (Finding 2, final review): the design
/// doc promised a bind failure "surfaces the failure in the onboarding row ('port in
/// use')", but nothing read `GrabServer.state` to make that true — a port collision
/// presented as a button that silently did nothing, and worse, is what a local port
/// squatter looks like too (every extension POST would go to whatever else is holding
/// 51847 instead). A stale-but-fresh check-in from BEFORE the port was lost must not paper
/// over a server that cannot accept new connections right now, which is why this is
/// checked before, not after, the ordinary freshness logic. Defaults to `.listening` so
/// every pre-existing call site (this function predates GrabServer.State existing at all)
/// keeps its old behaviour unchanged.
func browserButtonStatus(lastSeen: Date?, now: Date, serverState: GrabServer.State = .listening,
                         freshness: TimeInterval = 60 * 60 * 24 * 14) -> PermissionStatus {
    if case .failed(let reason) = serverState { return .serverUnavailable(reason) }
    guard let lastSeen else { return .notDetermined }
    let elapsed = now.timeIntervalSince(lastSeen)
    guard elapsed >= 0, elapsed < freshness else { return .notDetermined }
    return .granted
}

/// Pure: which check-in (if any) counts as evidence the button is installed, out of every
/// browser that has ever pinged this app. Review fix round 1, Finding 1: the row used to
/// read `lastSeen[browser.rawValue]` for the single browser `MenuBarController` happens to
/// have configured for cookie-reading (hardcoded `.chrome`) — which has nothing to do with
/// which browser's *extension* the user actually installed, and silently orphaned every
/// Safari user's check-ins forever (this task's entire reason for existing). Any known
/// browser must count, so this takes the freshest timestamp across all of them.
func mostRecentBrowserCheckIn(_ lastSeen: [String: Date]) -> Date? {
    lastSeen.values.max()
}

/// The login-item row's verdict. Kept next to `browserButtonStatus` and `notificationStatus`
/// because it is the same shape of thing: an OS value a test runner cannot produce, judged
/// by a function a test runner can.
///
/// `.requiresApproval` means the user switched Carabiner off in System Settings → Login
/// Items & Extensions. Calling `register()` again does NOT override that, so offering
/// "Allow" would be a button that cannot work; `.denied` is what routes the row to the
/// Settings deep link instead.
///
/// `.notFound` should be unreachable for `SMAppService.mainApp`. It maps to `.denied` rather
/// than anything softer on purpose: a tick must mean a real, checked yes.
func loginItemStatus(_ status: LoginItemStatus) -> PermissionStatus {
    switch status {
    case .enabled:          return .granted
    case .notRegistered:    return .notDetermined
    case .requiresApproval: return .denied
    case .notFound:         return .denied
    }
}

/// Full Disk Access has no System Settings identifier of its own on the automation scheme —
/// this is the pane's real anchor, verified against System Settings' own deep-link scheme.
let fullDiskAccessSettingsURL = "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles"

/// Verified 2026-08-18 by opening it and reading the window title back via System Events,
/// which returned literally `Login Items & Extensions` — the same instrument gotcha #37
/// established for the Full Disk Access link, and for the same reason: a deep link that
/// opens the wrong pane is indistinguishable from a working one until a human looks.
let loginItemSettingsURL = "x-apple.systempreferences:com.apple.LoginItems-Settings.extension"

/// Pure: classifies the outcome of the real `open()` syscall against Safari's cookie file.
/// Factored out of `LivePermissionChecker.fullDiskAccessStatus()` (review fix round 1,
/// "ALSO FIX" — the riskiest new green tick in this task had zero coverage) so the
/// EPERM/ENOENT/success split is testable without a live denied machine. `fd`/`errno` are
/// exactly what a real `open()` call would leave behind; the caller is the untested
/// OS-facing wrapper that supplies them.
func fullDiskAccessStatus(fd: Int32, errno errnoValue: Int32) -> PermissionStatus {
    if fd >= 0 { return .granted }
    // EPERM is TCC's answer for "not authorised" on a protected container — the same errno
    // GrabRunner.isCookieReadFailure matches in yt-dlp/gallery-dl's own output.
    if errnoValue == EPERM { return .denied }
    // ENOENT — overwhelmingly "Safari has never run, or never saved cookies" — proves
    // nothing about the grant. Reporting it as denied would invite a Chrome-only user to
    // grant the broadest permission on macOS for a feature they will never use; reporting
    // it as granted would be a green tick with nothing behind it. Neither is honest.
    if errnoValue == ENOENT { return .notApplicable }
    // Anything else is a genuinely unexpected failure — no story to tell yet.
    return .notDetermined
}

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
    /// Undo the grant ourselves. Only legal where the app genuinely can: a login item is
    /// `unregister()`-able, unlike every TCC permission, where macOS offers no in-process
    /// revoke and `openSystemSettings` is the only truthful answer.
    case revoke
    /// Already in the requested state.
    case nothing
}

func toggleAction(desired: Bool, status: PermissionStatus) -> ToggleIntent {
    if desired {
        switch status {
        case .granted:                        return .nothing
        case .notDetermined, .targetNotRunning: return .request
        case .denied:                         return .openSystemSettings
        // Nothing to request — there is no permission missing to ask for; see
        // PermissionStatus.notApplicable.
        case .notApplicable:                  return .nothing
        // Nothing this app can do in-process OR via System Settings fixes a port
        // collision (Finding 2, final review) — see PermissionStatus.serverUnavailable.
        case .serverUnavailable:              return .nothing
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
    ///
    /// `.notApplicable` is the one status where even a non-promptable row has nothing to
    /// deep-link *for* — sending a Chrome-only user to the Privacy pane for a grant they
    /// will never use is the same false urgency `notApplicable` exists to remove (review
    /// fix round 1, Finding 3). `toggleAction` already resolves `.notApplicable` to
    /// `.nothing`, so this only needs to stop the blanket override from clobbering it.
    func intent(desired: Bool, status: PermissionStatus) -> ToggleIntent {
        // Before anything else: a row that can revoke itself must not be routed to System
        // Settings by the shared "off is never in-process" rule inside toggleAction.
        if !desired, canRevokeInProcess {
            return status == .granted ? .revoke : .nothing
        }
        guard desired else { return toggleAction(desired: desired, status: status) }
        guard canBePrompted else {
            return status == .notApplicable ? .nothing : .openSystemSettings
        }
        return toggleAction(desired: desired, status: status)
    }

    /// Whether turning this row OFF is something the app can do itself.
    ///
    /// False for every TCC permission: macOS provides no API to hand a grant back, which is
    /// why `toggleAction` resolves every "off" to `.openSystemSettings`. A login item is not
    /// a TCC permission — `SMAppService.unregister()` is a real revoke — so that blanket
    /// rule would send the user to Settings to do something we could have just done.
    var canRevokeInProcess: Bool { self == .launchAtLogin }

    var canBePrompted: Bool {
        switch self {
        case .notifications, .browserAccess, .carouselDialog, .browserButton, .launchAtLogin: return true
        case .fullDiskAccess:                                                                  return false
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
