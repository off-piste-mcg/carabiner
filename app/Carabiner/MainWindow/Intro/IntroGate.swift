import Foundation

/// Whether this person has seen the first-run explainer.
///
/// Takes a `UserDefaults` instance rather than reaching for `.standard`, so the real
/// functions are testable against a scratch suite instead of being tested around.
///
/// The key is deliberately NOT `onboardingShown`: that one means "has been offered
/// setup" and is already true on every 0.1.x and 0.2.0 install, so reusing it would hide
/// the intro from every upgrading teammate — the people the in-page Instagram button is
/// newest to.
enum IntroGate {
    static let shownDefaultsKey = "introShown"

    static func shouldShow(_ defaults: UserDefaults) -> Bool {
        !defaults.bool(forKey: shownDefaultsKey)
    }

    static func markSeen(_ defaults: UserDefaults) {
        defaults.set(true, forKey: shownDefaultsKey)
    }
}
