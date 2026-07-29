import Foundation
import KeyboardShortcuts

extension KeyboardShortcuts.Name {
    static let grab = Self("grab", default: .init(.v, modifiers: [.control, .option, .command]))
}

enum Hotkey {
    /// A global hotkey is exclusive: if another app already owns the chord (a macOS
    /// Shortcut bound to the same keys, say), every press goes there instead and this app
    /// never hears about it. Nothing in the API reports that, so log both the chord we
    /// registered and each time it actually fires — otherwise a stolen hotkey is
    /// indistinguishable from a broken app.
    static func onGrab(_ handler: @escaping () -> Void) {
        KeyboardShortcuts.onKeyUp(for: .grab) {
            NSLog("Carabiner: grab hotkey fired")
            handler()
        }
        if let shortcut = KeyboardShortcuts.getShortcut(for: .grab) {
            NSLog("Carabiner: grab hotkey registered as %@", "\(shortcut)")
        } else {
            NSLog("Carabiner: grab hotkey has no chord assigned — it will never fire")
        }
    }
}
