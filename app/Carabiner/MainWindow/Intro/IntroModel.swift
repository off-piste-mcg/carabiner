import Foundation

/// Which explainer card is showing. Paging only — it knows nothing about UserDefaults,
/// the window, or what happens when the intro ends. Main thread only, like every model
/// in this app.
final class IntroModel: ObservableObject {
    @Published private(set) var index = 0
    let cards: [IntroCard]

    /// Cards are injectable so the bounds tests don't depend on the shipped copy count.
    init(cards: [IntroCard] = IntroCard.all) {
        self.cards = cards
    }

    var card: IntroCard { cards[index] }
    var isLast: Bool { index >= cards.count - 1 }

    func next() { if !isLast { index += 1 } }
    func back() { if index > 0 { index -= 1 } }

    /// A step dot. Out-of-range is ignored rather than clamped: a dot that cannot exist
    /// was not clicked, and silently landing somewhere else would be worse than nothing.
    func go(to target: Int) {
        guard cards.indices.contains(target) else { return }
        index = target
    }
}
