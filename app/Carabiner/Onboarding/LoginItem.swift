import Foundation
import ServiceManagement

/// Mirrors `SMAppService.Status`, so everything in front of this seam can be tested without
/// touching the real login-item database. Same split as `LivePermissionChecker`: the OS call
/// is thin and untested, the judgement about what it MEANS is pure and tested.
enum LoginItemStatus: Equatable {
    case enabled
    case notRegistered
    case requiresApproval
    case notFound
}

protocol LoginItemControlling {
    var status: LoginItemStatus { get }
    /// Both of these throw. Callers must not assume success — see LivePermissionChecker,
    /// which logs the error and then reads the REAL status back, so a failed toggle reads
    /// off rather than presenting as a switch that moved and did nothing (gotcha #37).
    func register() throws
    func unregister() throws
}

/// The real thing. Deliberately has no logic worth testing: if this file ever grows a
/// decision, that decision belongs on the other side of the seam.
final class LiveLoginItemController: LoginItemControlling {
    var status: LoginItemStatus {
        switch SMAppService.mainApp.status {
        case .enabled:          return .enabled
        case .notRegistered:    return .notRegistered
        case .requiresApproval: return .requiresApproval
        case .notFound:         return .notFound
        @unknown default:       return .notFound
        }
    }

    func register() throws { try SMAppService.mainApp.register() }
    func unregister() throws { try SMAppService.mainApp.unregister() }
}
