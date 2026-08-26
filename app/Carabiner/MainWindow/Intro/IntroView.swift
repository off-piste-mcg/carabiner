import SwiftUI

/// The first-run explainer: one card at a time over the brand canvas. Presentation only
/// — the copy is IntroCard, the paging is IntroModel, "have they seen it" is IntroGate,
/// and what happens on exit is MainViewModel's.
///
/// It draws no background of its own: MainView keeps the canvas behind it, so the
/// artwork is the same one the app opens on afterwards.
struct IntroView: View {
    @ObservedObject var intro: IntroModel
    let onSkip: () -> Void
    let onFinish: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            topRow
            Spacer(minLength: 20)
            Text(intro.card.title)
                .font(Brand.mono(24)).kerning(1)
                .foregroundStyle(.black.opacity(0.85))
                .fixedSize(horizontal: false, vertical: true)
                .padding(.bottom, 20)
            VStack(alignment: .leading, spacing: 12) {
                ForEach(Array(intro.card.lines.enumerated()), id: \.offset) { _, line in
                    lineView(line)
                }
            }
            Spacer(minLength: 20)
            bottomRow
        }
        .frame(maxWidth: 540, alignment: .leading)
        .padding(.horizontal, 44)
        // Clear of the traffic lights the transparent titlebar draws over the canvas —
        // the same 48pt SideRail uses.
        .padding(.top, 48)
        .padding(.bottom, 28)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .focusable()
        .onMoveCommand { direction in
            switch direction {
            case .right: intro.next()
            case .left:  intro.back()
            default:     break
            }
        }
        .onExitCommand { onSkip() }
    }

    /// Dots left, SKIP right.
    private var topRow: some View {
        HStack {
            HStack(spacing: 7) {
                ForEach(intro.cards.indices, id: \.self) { i in
                    Button { intro.go(to: i) } label: {
                        Circle()
                            .fill(i == intro.index ? Color.black.opacity(0.55)
                                                   : Color.black.opacity(0.18))
                            .frame(width: 6, height: 6)
                    }
                    .buttonStyle(.plain)
                    .help("Step \(i + 1)")
                }
            }
            Spacer()
            Button(action: onSkip) {
                Text("SKIP").font(Brand.mono(10)).kerning(1)
                    .foregroundStyle(.black.opacity(0.4))
            }
            .buttonStyle(.plain)
            .help("Skip the introduction")
        }
    }

    /// The primary button: NEXT until the last card, then the handoff to setup.
    private var bottomRow: some View {
        HStack {
            Spacer()
            Button(action: { intro.isLast ? onFinish() : intro.next() }) {
                Text(intro.isLast ? "SET UP PERMISSIONS →" : "NEXT")
                    .font(Brand.mono(12)).kerning(1)
                    .foregroundStyle(.black)
                    .padding(.horizontal, 24)
                    .frame(height: 34)
                    .background(Capsule().fill(Brand.yellow))
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.defaultAction)
        }
    }

    @ViewBuilder
    private func lineView(_ line: IntroCard.Line) -> some View {
        if let lead = line.lead {
            // `foregroundColor` is deprecated but REQUIRED here: Text.foregroundStyle is
            // macOS 14+, and this app's floor is 13. "Modernising" this line breaks the
            // build outright. The concatenation itself is load-bearing too — a bold lead
            // and a wrapping sentence must share one text run, which an HStack cannot do.
            (Text(lead + " — ").font(Brand.mono(12)).foregroundColor(.black.opacity(0.75))
             + Text(line.text).font(Brand.mono(12)).foregroundColor(.black.opacity(0.55)))
                .fixedSize(horizontal: false, vertical: true)
        } else {
            Text(line.text)
                .font(Brand.mono(12))
                .foregroundStyle(.black.opacity(0.6))
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
