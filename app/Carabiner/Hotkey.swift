import KeyboardShortcuts

extension KeyboardShortcuts.Name {
    static let grab = Self("grab", default: .init(.v, modifiers: [.control, .option, .command]))
}

enum Hotkey {
    static func onGrab(_ handler: @escaping () -> Void) {
        KeyboardShortcuts.onKeyUp(for: .grab) { handler() }
    }
}
