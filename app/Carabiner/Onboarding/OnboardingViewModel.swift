import Foundation
import AppKit
import SwiftUI
import SafariServices

/// Bridges the OS-facing checker to SwiftUI. Holds no decisions of its own: every verdict
/// comes from PermissionRow.presentation(for:) or HotkeyTestModel, both of which are pure
/// and tested. This exists only because SwiftUI needs an ObservableObject to observe.
@MainActor
final class OnboardingViewModel: ObservableObject {
    @Published private(set) var statuses: [PermissionRow: PermissionStatus] = [:]
    @Published var hotkey: HotkeyTestPresentation = HotkeyTestModel().presentation

    /// The hotkey test needs a Timer and the app's hotkey intercept, both of which belong
    /// to the window controller. The view model just reports the button was pressed.
    var onBeginHotkeyTest: () -> Void = {}

    private let checker: PermissionChecking

    init(checker: PermissionChecking) { self.checker = checker }

    /// Unlisted Web Store listing — installable by direct link only. Replace with the
    /// real ID once the listing exists (Task 12).
    static let chromeWebStoreURL = "https://chromewebstore.google.com/detail/PLACEHOLDER_ID"

    private func isInstalled(_ bundleId: String) -> Bool {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) != nil
    }

    /// The `.browserButton` row's Allow action. Not a TCC permission — installing (or
    /// re-opening the management page for) a browser extension — so it never goes through
    /// `checker`, which exists specifically to wrap OS authorisation APIs. Opens whichever
    /// of the two the user actually has; if neither is installed this is a silent no-op,
    /// which is honest, since there is nowhere sensible to send them.
    func installBrowserButton() {
        if isInstalled("com.google.Chrome") {
            NSWorkspace.shared.open(URL(string: Self.chromeWebStoreURL)!)
        }
        if isInstalled("com.apple.Safari") {
            SFSafariApplication.showPreferencesForExtension(
                withIdentifier: "com.offpiste.carabiner.SafariExtension")
        }
    }

    func refreshAll() {
        for row in PermissionRow.allCases { refresh(row) }
    }

    func refresh(_ row: PermissionRow) {
        checker.status(for: row) { [weak self] status in
            self?.statuses[row] = status
        }
    }

    func presentation(for row: PermissionRow) -> RowPresentation {
        row.presentation(for: statuses[row] ?? .notDetermined)
    }

    func isOn(_ row: PermissionRow) -> Bool { statuses[row] == .granted }

    /// The switch reports an intent, not a new state. Where the OS lets us act we act;
    /// otherwise we open System Settings and re-read — so the switch lands wherever the
    /// truth is, which may be exactly where it started. `row.intent`, not the bare
    /// `toggleAction`, so a row macOS gives no prompt for (fullDiskAccess) can override
    /// that and deep-link instead — see PermissionRow.canBePrompted.
    func setEnabled(_ desired: Bool, for row: PermissionRow) {
        checker.status(for: row) { [weak self] status in
            guard let self else { return }
            switch row.intent(desired: desired, status: status) {
            case .request:
                // browserButton's "request" is opening an install page, not an OS prompt —
                // installBrowserButton() is a plain, synchronous, fire-and-forget action,
                // so refresh immediately rather than waiting on a completion that would
                // never arrive (the extension only checks in once actually used).
                if row == .browserButton {
                    self.installBrowserButton()
                    self.refresh(row)
                } else {
                    self.checker.request(row) { [weak self] _ in self?.refresh(row) }
                }
            case .openSystemSettings:
                if row == .browserButton {
                    self.installBrowserButton()
                } else {
                    self.checker.openSystemSettings(for: row)
                }
                self.refresh(row)
            case .nothing:
                self.refresh(row)
            }
        }
    }

    func act(on row: PermissionRow) {
        checker.status(for: row) { [weak self] status in
            guard let self else { return }
            switch row.presentation(for: status).action {
            case .request:
                self.checker.request(row) { [weak self] _ in self?.refresh(row) }
            case .openSystemSettings:
                self.checker.openSystemSettings(for: row)
            case .none:
                self.refresh(row)
            }
        }
    }
}
