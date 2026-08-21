import Foundation

enum GateVerdict: Equatable {
    case ok(url: String)
    case rejected(status: Int, reason: String)
}

/// Pure. The listener does I/O; this decides. Kept separate for the same reason
/// `BannerPlanner` is: the I/O layer can't be unit-tested, so the decision must be.
///
/// Scope limit, stated honestly rather than implied: this gate constrains the URL it is
/// *given*, not the address ultimately fetched. yt-dlp/gallery-dl follow HTTP redirects
/// without re-consulting this gate, so a URL that legitimately matches the host allowlist
/// here (e.g. `https://l.instagram.com/?u=...`) can still redirect off-allowlist once the
/// downloader starts fetching. Closing that seam is a downloader-configuration concern,
/// not something a single pre-fetch string can decide — don't read `.ok` as a guarantee
/// about where the bytes eventually come from, only about what was submitted.
///
/// Safari caveat (unverified as of 2026-08-12): accepting `safari-web-extension://`
/// assumes Safari sends an `Origin` header on the request this gate ever sees. That is
/// not yet confirmed — a human is verifying it separately. If Safari turns out not to
/// send one, this gate will need a pairing-token path for Safari specifically; the origin
/// logic already correctly governs Chrome either way and needs no change for that.
enum GrabGate {
    /// A web page can never have one of these schemes, and the browser — not the page —
    /// sets the Origin header, so this cannot be forged from a page. Exact extension IDs
    /// are deliberately NOT allowlisted: Safari's origin is a random per-install UUID.
    static let allowedOriginSchemes = ["chrome-extension://", "safari-web-extension://"]

    /// Characters allowed in the host component of a serialised origin. A real `Origin`
    /// header (Fetch spec) is `scheme "://" host [":" port]` and NEVER a path — restricting
    /// to this set is what stops `chrome-extension://a\r\nX-Header: 1` (CR/LF/space are
    /// all outside it, same as `/`) from surviving prefix-matching as an "accepted" value
    /// that a naive downstream could later echo into a response header.
    private static let originHostCharacters = CharacterSet(charactersIn:
        "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-.")

    /// Host must match exactly or on a dot boundary, so `instagram.com.evil.example`
    /// cannot pass by suffix.
    private static let allowedHosts = [
        "instagram.com", "youtube.com", "youtu.be", "pinterest.com",
    ]

    /// Single source of truth for "is this Origin header value one we accept" — used by
    /// both `check` below (the POST /grab gate) and the listener's OPTIONS preflight
    /// (GrabServer.swift). Before this existed, the preflight path re-implemented half of
    /// this check by hand (the scheme-prefix test alone, without `isWellFormedOrigin`'s
    /// character-set validation) and echoed the raw result into a response header — so a
    /// bare CR or LF inside the Origin value could survive preflight and be written
    /// unencoded into `Access-Control-Allow-Origin`. Not reachable from a web page (the
    /// browser sets Origin, a page cannot forge it), but two origin checks that can
    /// disagree is exactly the drift that becomes a real hole later; now there is one.
    /// Returns the origin unchanged — nothing to re-serialise here, unlike the URL case
    /// below, because an accepted origin's host already contains only characters from
    /// `originHostCharacters`.
    static func checkOrigin(_ origin: String?) -> String? {
        guard let origin,
              let scheme = allowedOriginSchemes.first(where: { origin.hasPrefix($0) }),
              isWellFormedOrigin(origin, scheme: scheme)
        else { return nil }
        return origin
    }

    static func check(origin: String?, url: String?) -> GateVerdict {
        guard checkOrigin(origin) != nil else {
            return .rejected(status: 403, reason: "origin not an extension")
        }
        return checkURL(url)
    }

    /// The URL half of `check`, on its own because the extension is no longer the only
    /// caller: the main window's Grab button and a URL dropped on the Dock icon route
    /// through this same allowlist — one answer to "may Carabiner be pointed at this",
    /// whichever surface asked.
    static func checkURL(_ url: String?) -> GateVerdict {
        // https only: an extension only ever originates these four hosts over https, and
        // allowing plain http would widen the redirect seam described above to any
        // on-path attacker for zero legitimate benefit.
        guard let url, let parsed = URL(string: url),
              let urlScheme = parsed.scheme?.lowercased(), urlScheme == "https",
              let host = parsed.host?.lowercased()
        else {
            return .rejected(status: 400, reason: "unusable url")
        }
        let hostAllowed = allowedHosts.contains { host == $0 || host.hasSuffix("." + $0) }
        guard hostAllowed else { return .rejected(status: 400, reason: "host not allowed") }
        // Return what Foundation parsed and re-serialised, never the caller's raw bytes.
        // `absoluteString` is always a validly percent-encoded serialisation of a `URL`,
        // so a caller-supplied CR/LF (or anything else outside what a URL can hold)
        // cannot ride along into whatever the listener does with the accepted value —
        // the same header-injection concern the origin check above closes for `Origin`.
        return .ok(url: parsed.absoluteString)
    }

    /// Origin must be exactly `scheme://host` or `scheme://host:port`, each part
    /// restricted to its own safe character set. This is a character-set/shape check, not
    /// a parse of the string as a `URL` — an "origin" per Fetch is not itself a URL and
    /// should never be treated as tolerating a path.
    private static func isWellFormedOrigin(_ origin: String, scheme: String) -> Bool {
        let remainder = origin.dropFirst(scheme.count)
        guard !remainder.isEmpty else { return false }
        let parts = remainder.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        guard let host = parts.first, !host.isEmpty,
              host.unicodeScalars.allSatisfy({ originHostCharacters.contains($0) })
        else { return false }
        guard parts.count > 1 else { return true }
        let port = parts[1]
        return !port.isEmpty && port.unicodeScalars.allSatisfy { CharacterSet.decimalDigits.contains($0) }
    }
}
