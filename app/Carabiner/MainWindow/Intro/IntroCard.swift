import Foundation

/// The first-run explainer's copy, as data. Deliberately not in the view: the words are
/// the feature, and keeping them here makes them testable and diffable on their own.
/// Wording is fixed by docs/superpowers/specs/2026-08-26-first-run-intro-design.md —
/// change it there first.
struct IntroCard: Equatable {
    /// One body line. `lead` is an optional bold opener ("On Instagram") followed by the
    /// sentence; cards 1 and 3 use plain lines with no lead.
    struct Line: Equatable {
        let lead: String?
        let text: String

        init(_ text: String) {
            self.lead = nil
            self.text = text
        }

        init(lead: String, _ text: String) {
            self.lead = lead
            self.text = text
        }
    }

    let title: String
    let lines: [Line]

    static let all: [IntroCard] = [
        IntroCard(
            title: "PASTE A LINK,\nGET THE FILE.",
            lines: [
                Line("An Instagram video or photo becomes a clean file in your Downloads "
                     + "— one that QuickTime actually opens."),
                Line("Carabiner does the awkward part: Instagram's videos aren't files, "
                     + "they're streams, and what you can save by hand usually won't play."),
            ]),
        IntroCard(
            title: "THREE WAYS TO ASK.",
            lines: [
                Line(lead: "On Instagram",
                     "a small Carabiner button sits beside Save on every post, in Chrome "
                     + "and Safari."),
                Line(lead: "From anywhere", "open a post and press ⌃⌥⌘V."),
                Line(lead: "Here", "paste a link into this window and hit GRAB."),
            ]),
        IntroCard(
            title: "WHAT TO EXPECT.",
            lines: [
                Line("Carousels ask first: this slide, or all of them. Files land in "
                     + "~/Downloads, named after the post. A banner tells you when it's done."),
                Line("It all runs on your Mac, using your own browser session — nothing "
                     + "is uploaded, and no account but yours is involved."),
            ]),
    ]
}
