import SwiftUI
import AppKit

/// The OFF-PISTE brand, in one place. Every view asks Brand; nothing else names a
/// hex, a font name, or a resource path.
enum Brand {
    /// #FAFA78 — sampled from the approved mockup's GRAB pill. Lives in the asset
    /// catalog so this is the only mention.
    static let yellow = Color("BrandYellow")

    /// ABC Diatype Mono when the licensed .otf is present (registered at launch via
    /// ATSApplicationFontsPath), system monospaced otherwise. The fallback is what
    /// lets the public repo build without shipping the font.
    static func mono(_ size: CGFloat) -> Font {
        if NSFont(name: "ABCDiatypeMono-Regular", size: size) != nil {
            return .custom("ABCDiatypeMono-Regular", size: size)
        }
        return .system(size: size, design: .monospaced)
    }

    /// The gradient canvas. nil on a checkout without the asset — the view draws a
    /// plain gradient fallback rather than a white void.
    static let backgroundImage: NSImage? = {
        guard let url = Bundle.main.url(forResource: "bg", withExtension: "jpg",
                                        subdirectory: "BrandAssets") else { return nil }
        return NSImage(contentsOf: url)
    }()

    /// "0.1.2" — the right-edge furniture renders it as "V. 0.1.2".
    static var shortVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
    }

    /// Mockup-style footer clock: "09:32AM". Locale pinned to en_US_POSIX so a 24h
    /// system preference can't reshape brand furniture; timeZone injectable for tests.
    static func clockText(_ date: Date, timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "hh:mma"
        return formatter.string(from: date)
    }
}
