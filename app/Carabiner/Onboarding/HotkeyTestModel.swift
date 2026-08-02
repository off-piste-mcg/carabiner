import Foundation

struct HotkeyTestPresentation: Equatable {
    let tick: PermissionRow.Tick
    let buttonTitle: String?
    let detail: String?
}

/// The hotkey row's state machine. Listening is the only honest check there is:
/// RegisterEventHotKey fails silently when another owner holds the chord (gotcha #14),
/// so the app can never *know* it lost the hotkey — it can only notice nothing arrived.
struct HotkeyTestModel {
    enum State: Equatable { case idle, listening, confirmed, timedOut }

    static let hint = "Nothing arrived. If you installed the Carabiner Shortcut before, "
        + "remove its keyboard shortcut in the Shortcuts app — a hotkey has exactly one owner."

    private(set) var state: State = .idle

    mutating func beginTest() { state = .listening }

    mutating func hotkeyFired() {
        guard state == .listening else { return }
        state = .confirmed
    }

    mutating func timeout() {
        guard state == .listening else { return }
        state = .timedOut
    }

    /// The window closed mid-listen: the intercept is being cleared, so listening no
    /// longer means anything. Back to idle so a reopened window offers Test again.
    mutating func cancel() {
        guard state == .listening else { return }
        state = .idle
    }

    var presentation: HotkeyTestPresentation {
        switch state {
        case .idle:
            return HotkeyTestPresentation(tick: .pending, buttonTitle: "Test",
                                          detail: "Press ⌃⌥⌘V when asked.")
        case .listening:
            return HotkeyTestPresentation(tick: .pending, buttonTitle: nil,
                                          detail: "Press ⌃⌥⌘V now…")
        case .confirmed:
            return HotkeyTestPresentation(tick: .ok, buttonTitle: nil, detail: nil)
        case .timedOut:
            return HotkeyTestPresentation(tick: .cross, buttonTitle: "Test again",
                                          detail: Self.hint)
        }
    }
}
