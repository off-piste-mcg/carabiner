import Foundation

/// What `application(_:open:)` should do with one incoming URL. Pure — the delegate does
/// the I/O, this decides, for the same reason GrabGate is split from GrabServer.
enum DockOpenAction: Equatable {
    /// `carabiner://` — the extension's cold-launch scheme. Being launched IS the effect;
    /// nothing further to do.
    case launchOnly
    /// A link the allowlist accepts (dropped on the Dock icon, or opened with the app):
    /// start a grab with this re-serialised URL.
    case grab(url: String)
    /// Anything else — a file, an off-allowlist site, plain http. Log and drop.
    case ignore
}

func dockOpenAction(for url: URL) -> DockOpenAction {
    if url.scheme?.lowercased() == "carabiner" { return .launchOnly }
    // Same gate as the extension and the main window's Grab button: https only, the
    // Instagram/YouTube/Pinterest host allowlist, and only the re-serialised URL survives.
    if case .ok(let accepted) = GrabGate.checkURL(url.absoluteString) { return .grab(url: accepted) }
    return .ignore
}
