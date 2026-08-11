import Foundation
import SwiftUI

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
    /// truth is, which may be exactly where it started. See toggleAction.
    func setEnabled(_ desired: Bool, for row: PermissionRow) {
        checker.status(for: row) { [weak self] status in
            guard let self else { return }
            switch toggleAction(desired: desired, status: status) {
            case .request:
                self.checker.request(row) { [weak self] _ in self?.refresh(row) }
            case .openSystemSettings:
                self.checker.openSystemSettings(for: row)
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
