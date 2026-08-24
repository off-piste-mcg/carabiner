import SwiftUI

/// The brand canvas: gradient artwork edge to edge, the link bar center, corner
/// furniture around. Renders model state and forwards actions — every decision stays
/// in MainViewModel. RECENT GRABS and SETTINGS live behind the left rail (SideRail,
/// own file) since the 2026-08-24 revision.
struct MainView: View {
    @ObservedObject var model: MainViewModel
    @ObservedObject var history: GrabHistoryStore
    @ObservedObject var settings: OnboardingViewModel

    /// Pointer over GRAB. Only drives the spring scale — on macOS 26 the lensing and
    /// specular sweep come from `Glass.interactive()`, which the system animates itself.
    @State private var hoveringGrab = false

    init(model: MainViewModel, settings: OnboardingViewModel) {
        self.model = model
        self.history = model.history
        self.settings = settings
    }

    var body: some View {
        ZStack(alignment: .leading) {
            background
                .contentShape(Rectangle())
                .onTapGesture { if model.panel != nil { model.collapsePanel() } }
            content
            furniture
            SideRail(model: model, history: history, settings: settings)
        }
        .animation(.easeOut(duration: 0.2), value: model.panel)
        .onExitCommand { if model.panel != nil { model.collapsePanel() } }
        .frame(minWidth: 640, minHeight: 420)
        .ignoresSafeArea()   // under the transparent titlebar
        // A URL dragged anywhere onto the canvas submits — same path as typing it.
        .onDrop(of: [.url, .plainText], isTargeted: nil) { providers in
            loadDroppedURL(from: providers) { dropped in
                model.urlField = dropped
                model.submit()
            }
            return true
        }
    }

    // MARK: - canvas

    @ViewBuilder
    private var background: some View {
        GeometryReader { geo in
            if let image = Brand.backgroundImage {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: geo.size.width, height: geo.size.height)
                    .clipped()
            } else {
                // Checkout without the asset: approximate, never a white void.
                LinearGradient(colors: [Color(red: 0.64, green: 0.69, blue: 0.76),
                                        Color(red: 0.86, green: 0.87, blue: 0.88)],
                               startPoint: .top, endPoint: .bottom)
            }
        }
        .ignoresSafeArea()
    }

    private var content: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 60)
            linkBar
            statusLine
                .padding(.top, 12)
            Spacer(minLength: 24)
        }
        // Center in the canvas the rail leaves free, not the full window: the
        // collapsed rail (48 + 14 margin) clips the bar at the 640pt minimum,
        // and the expanded card (300 + 14) covers its whole left edge.
        .padding(.leading, model.panel == nil ? 62 : 314)
        .padding(.horizontal, model.panel == nil ? 56 : 24)
        .frame(maxWidth: .infinity)
    }

    private var linkBar: some View {
        HStack(spacing: 6) {
            TextField("", text: $model.urlField,
                      prompt: Text("PASTE YOUR LINK").font(Brand.mono(12)))
                .textFieldStyle(.plain)
                .font(Brand.mono(12))
                .padding(.horizontal, 18)
                .frame(height: 34)
                .background {
                    if #available(macOS 26.0, *) {
                        Color.clear.glassEffect(.clear, in: Capsule())
                    } else {
                        Capsule().fill(.white.opacity(0.55))
                    }
                }
                .onSubmit { model.submit() }
            Button { model.submit() } label: {
                Text("GRAB")
                    .font(Brand.mono(12)).kerning(1)
                    .foregroundStyle(.black)
                    .padding(.horizontal, 24)
                    .frame(height: 34)
                    .background {
                        // Tinted interactive glass on Tahoe: the hover lensing, the
                        // specular sweep and the press springiness are the system's,
                        // not ours. 13–15 keeps the flat capsule and the scale below.
                        if #available(macOS 26.0, *) {
                            Color.clear.glassEffect(
                                .regular.tint(Brand.yellow).interactive(), in: Capsule())
                        } else {
                            Capsule().fill(Brand.yellow)
                        }
                    }
                    .scaleEffect(hoveringGrab ? 1.04 : 1)
                    .animation(.spring(response: 0.3, dampingFraction: 0.6), value: hoveringGrab)
            }
            .buttonStyle(.plain)
            // A disabled button must not react to the pointer, and a grab that starts
            // under the cursor must drop the hover state rather than stay swollen.
            .onHover { hoveringGrab = $0 && !model.grabbing }
            .onChange(of: model.grabbing) { if $0 { hoveringGrab = false } }
            .keyboardShortcut(.defaultAction)
            .disabled(model.grabbing)
        }
        .frame(maxWidth: 560)
    }

    @ViewBuilder
    private var statusLine: some View {
        if let stage = model.stage {
            HStack(spacing: 8) {
                PulsingDot()
                Text(stage.uppercased()).font(Brand.mono(10)).kerning(1)
                    .foregroundStyle(.black.opacity(0.6))
            }
        } else if let feedback = model.feedback {
            Text(feedback.uppercased()).font(Brand.mono(10)).kerning(1)
                .foregroundStyle(.black.opacity(0.6))
                .multilineTextAlignment(.center)
        }
    }

    // MARK: - corner furniture

    private var furniture: some View {
        ZStack {
            // Right edge, rotated: the version.
            HStack { Spacer()
                Text("V. \(Brand.shortVersion)")
                    .font(Brand.mono(9)).kerning(2)
                    .foregroundStyle(.black.opacity(0.4))
                    .fixedSize()
                    .rotationEffect(.degrees(90))
                    .frame(width: 14)
            }
            .padding(.trailing, 10)

            // Bottom-right: the wordmark alone. The hotkey hint and the clock sat
            // beside it until 2026-08-24 and were dropped — neither earns its place
            // on the canvas, and the corner reads quieter without them.
            VStack { Spacer()
                HStack {
                    Spacer()
                    Image("Wordmark")
                        .resizable().scaledToFit().frame(height: 11)
                }
            }
            .padding(16)
        }
    }

    /// First provider that yields a URL or a URL-shaped string wins. Completion is called
    /// on the main queue (the providers call back on arbitrary queues).
    private func loadDroppedURL(from providers: [NSItemProvider], _ done: @escaping (String) -> Void) {
        guard let provider = providers.first(where: {
            $0.canLoadObject(ofClass: URL.self) || $0.canLoadObject(ofClass: NSString.self)
        }) else { return }
        if provider.canLoadObject(ofClass: URL.self) {
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                if let url { DispatchQueue.main.async { done(url.absoluteString) } }
            }
        } else {
            _ = provider.loadObject(ofClass: NSString.self) { string, _ in
                if let string = string as? String { DispatchQueue.main.async { done(string) } }
            }
        }
    }
}

/// The yellow activity dot beside the stage text — a quiet pulse, not a spinner.
private struct PulsingDot: View {
    @State private var dim = false

    var body: some View {
        Circle()
            .fill(Brand.yellow)
            .frame(width: 6, height: 6)
            .opacity(dim ? 0.3 : 1)
            .animation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true), value: dim)
            .onAppear { dim = true }
    }
}

