import Foundation

enum GateVerdict: Equatable {
    case ok(url: String)
    case rejected(status: Int, reason: String)
}

/// Pure. The listener does I/O; this decides. Kept separate for the same reason
/// `BannerPlanner` is: the I/O layer can't be unit-tested, so the decision must be.
enum GrabGate {
    /// A web page can never have one of these schemes, and the browser — not the page —
    /// sets the Origin header, so this cannot be forged from a page. Exact extension IDs
    /// are deliberately NOT allowlisted: Safari's origin is a random per-install UUID.
    static let allowedOriginSchemes = ["chrome-extension://", "safari-web-extension://"]

    /// Host must match exactly or on a dot boundary, so `instagram.com.evil.example`
    /// cannot pass by suffix.
    private static let allowedHosts = [
        "instagram.com", "youtube.com", "youtu.be", "pinterest.com",
    ]

    static func check(origin: String?, url: String?) -> GateVerdict {
        guard let origin, allowedOriginSchemes.contains(where: { origin.hasPrefix($0) }) else {
            return .rejected(status: 403, reason: "origin not an extension")
        }
        guard let url, let parsed = URL(string: url),
              let scheme = parsed.scheme?.lowercased(), scheme == "https" || scheme == "http",
              let host = parsed.host?.lowercased()
        else {
            return .rejected(status: 400, reason: "unusable url")
        }
        let hostAllowed = allowedHosts.contains { host == $0 || host.hasSuffix("." + $0) }
        guard hostAllowed else { return .rejected(status: 400, reason: "host not allowed") }
        return .ok(url: url)
    }
}
