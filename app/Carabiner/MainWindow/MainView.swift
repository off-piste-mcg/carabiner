import SwiftUI
import QuickLookThumbnailing

/// The brand canvas: gradient artwork edge to edge, the link bar center, RECENT below,
/// corner furniture around. Renders model state and forwards actions — every decision
/// stays in MainViewModel. Settings overlay arrives in SettingsPanel (own file).
struct MainView: View {
    @ObservedObject var model: MainViewModel
    @ObservedObject var history: GrabHistoryStore

    init(model: MainViewModel) {
        self.model = model
        self.history = model.history
    }

    var body: some View {
        ZStack {
            background
            content
            furniture
        }
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
            if !history.entries.isEmpty {
                recentSection
                    .padding(.bottom, 44)   // clears the footer furniture
            }
        }
        .padding(.horizontal, 56)
    }

    private var linkBar: some View {
        HStack(spacing: 10) {
            TextField("", text: $model.urlField,
                      prompt: Text("PASTE YOUR LINK").font(Brand.mono(12)))
                .textFieldStyle(.plain)
                .font(Brand.mono(12))
                .padding(.horizontal, 18)
                .frame(height: 34)
                .background(Capsule().fill(.white.opacity(0.55)))
                .onSubmit { model.submit() }
            Button { model.submit() } label: {
                Text("GRAB")
                    .font(Brand.mono(12)).kerning(1)
                    .foregroundStyle(.black)
                    .padding(.horizontal, 24)
                    .frame(height: 34)
                    .background(Capsule().fill(Brand.yellow))
            }
            .buttonStyle(.plain)
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

    private var recentSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("RECENT").font(Brand.mono(10)).kerning(2)
                .foregroundStyle(.black.opacity(0.45))
            ScrollView(showsIndicators: false) {
                LazyVStack(alignment: .leading, spacing: 6) {
                    ForEach(history.entries) { entry in
                        HistoryRow(entry: entry)
                    }
                }
            }
            .frame(maxHeight: 170)
        }
        .frame(maxWidth: 560)
    }

    // MARK: - corner furniture

    private var furniture: some View {
        ZStack {
            // Top-right: the settings pill.
            VStack { HStack { Spacer()
                Button { model.settingsShown = true } label: {
                    Capsule().fill(Brand.yellow).frame(width: 40, height: 12)
                }
                .buttonStyle(.plain)
                .help("Settings")
            }; Spacer() }
            .padding(14)

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

            // Bottom-left: the hotkey hint. Bottom-right: wordmark + clock.
            VStack { Spacer()
                HStack(alignment: .center) {
                    Text("⌃⌥⌘V").font(Brand.mono(10)).kerning(1)
                        .foregroundStyle(.black.opacity(0.4))
                    Spacer()
                    HStack(spacing: 8) {
                        Image("Wordmark")
                            .resizable().scaledToFit().frame(height: 11)
                        TimelineView(.everyMinute) { context in
                            Text(Brand.clockText(context.date))
                                .font(Brand.mono(10)).kerning(1)
                                .foregroundStyle(.black.opacity(0.55))
                        }
                    }
                }
            }
            .padding(16)
        }
        .allowsHitTesting(true)
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

/// One grab, brand-styled: 24px thumbnail, mono caps name, @user · relative time.
/// Behavior identical to the pre-brand row: double-click opens, context menu Reveal/Open,
/// rows whose file is gone are dimmed with actions disabled.
private struct HistoryRow: View {
    let entry: GrabHistoryEntry

    var body: some View {
        HStack(spacing: 10) {
            ThumbnailView(path: firstExistingPath)
            Text(title.uppercased())
                .font(Brand.mono(11))
                .foregroundStyle(.black.opacity(0.75))
                .lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 12)
            HStack(spacing: 6) {
                if let user = entry.user { Text(user.uppercased()) }
                Text(entry.date, format: .relative(presentation: .named))
            }
            .font(Brand.mono(9))
            .foregroundStyle(.black.opacity(0.4))
            .lineLimit(1)
        }
        .opacity(anyFileExists ? 1 : 0.35)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { open() }
        .contextMenu {
            Button("Reveal in Finder") { reveal() }.disabled(!anyFileExists)
            Button("Open") { open() }.disabled(!anyFileExists)
        }
        .help(anyFileExists ? entry.url : "File no longer in Downloads")
    }

    private var title: String {
        entry.files.count == 1 ? (entry.files.first ?? "") : "\(entry.files.count) files"
    }

    /// The script saves to ~/Downloads with no `-o` from the app, so names resolve there.
    /// Entries like `saved to ~/Downloads` (YouTube/Pinterest paths) simply don't resolve.
    private var paths: [String] {
        let downloads = NSString(string: "~/Downloads").expandingTildeInPath
        return entry.files.map { downloads + "/" + $0 }
    }

    private var existingPaths: [String] { paths.filter { FileManager.default.fileExists(atPath: $0) } }
    private var anyFileExists: Bool { !existingPaths.isEmpty }
    private var firstExistingPath: String? { existingPaths.first }

    private func reveal() {
        NSWorkspace.shared.activateFileViewerSelecting(existingPaths.map { URL(fileURLWithPath: $0) })
    }

    private func open() {
        guard let first = existingPaths.first else { return }
        NSWorkspace.shared.open(URL(fileURLWithPath: first))
    }
}

/// QuickLook thumbnail with the file's icon as immediate fallback. Requested at 2x for
/// Retina; a missing file renders a plain document icon so the row keeps its shape.
private struct ThumbnailView: View {
    let path: String?
    @State private var thumbnail: NSImage?

    private static let side: CGFloat = 24

    var body: some View {
        Group {
            if let thumbnail {
                Image(nsImage: thumbnail).resizable().scaledToFill()
            } else if let path {
                Image(nsImage: NSWorkspace.shared.icon(forFile: path)).resizable().scaledToFit()
            } else {
                Image(systemName: "doc").foregroundStyle(.tertiary)
            }
        }
        .frame(width: Self.side, height: Self.side)
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .task(id: path) {
            thumbnail = nil
            guard let path else { return }
            let request = QLThumbnailGenerator.Request(
                fileAt: URL(fileURLWithPath: path),
                size: CGSize(width: Self.side, height: Self.side),
                scale: 2, representationTypes: .thumbnail)
            let generated = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request)
            thumbnail = generated?.nsImage
        }
    }
}
