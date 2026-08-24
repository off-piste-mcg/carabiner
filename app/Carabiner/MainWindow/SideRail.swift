import SwiftUI
import QuickLookThumbnailing

/// The left rail: collapsed = a slim icon column; expanded = the RECENT GRABS or
/// SETTINGS card in the same frosted chrome (spec revision 2026-08-24). No scrim —
/// the hero stays visible beside the card.
struct SideRail: View {
    @ObservedObject var model: MainViewModel
    @ObservedObject var history: GrabHistoryStore
    @ObservedObject var settings: OnboardingViewModel

    var body: some View {
        Group {
            if let panel = model.panel {
                expandedCard(panel)
                    .transition(.move(edge: .leading).combined(with: .opacity))
            } else {
                rail
                    .transition(.move(edge: .leading).combined(with: .opacity))
            }
        }
        .padding([.leading, .bottom], 14)
        // Below the traffic lights: the transparent titlebar draws them over the
        // canvas at ~y20, and 14pt put the frosted corner right underneath them.
        .padding(.top, 48)
    }

    private var rail: some View {
        // Grabs at the top, Settings pinned to the bottom — the two are separate
        // destinations, not a stacked list, so they read as such with the rail's
        // height between them rather than 18pt.
        VStack(spacing: 0) {
            railButton("photo.on.rectangle.angled", help: "Recent grabs") { model.openGrabs() }
            Spacer(minLength: 24)
            railButton("gearshape", help: "Settings") { settings.refreshAll(); model.panel = .settings }
        }
        .padding(.vertical, 16)
        .frame(width: 48)
        .frame(maxHeight: .infinity)
        .background {
            // Liquid Glass on Tahoe; the same frost as always on 13–15.
            if #available(macOS 26.0, *) {
                Color.clear.glassEffect(.clear, in: RoundedRectangle(cornerRadius: 22))
            } else {
                RoundedRectangle(cornerRadius: 22).fill(.regularMaterial)
            }
        }
    }

    private func railButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(.black.opacity(0.6))
                .frame(width: 32, height: 32)
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private func expandedCard(_ panel: MainViewModel.SidePanel) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            // The yellow ✕ pill, top-left of the card (mockup #53).
            Button { model.collapsePanel() } label: {
                ZStack {
                    Capsule().fill(Brand.yellow).frame(width: 44, height: 16)
                    Image(systemName: "xmark").font(.system(size: 8, weight: .bold))
                        .foregroundStyle(.black)
                }
            }
            .buttonStyle(.plain)
            .help("Close")
            .padding(.top, 20)      // the card itself now starts below the traffic lights
            .padding(.leading, 20)
            .padding(.bottom, 20)

            Text(panel == .grabs ? "RECENT GRABS" : "SETTINGS")
                .font(Brand.mono(13)).kerning(2)
                .padding(.horizontal, 20)
                .padding(.bottom, 14)

            ScrollView(showsIndicators: false) {
                if panel == .grabs {
                    grabsContent
                } else {
                    SettingsContent(model: settings)
                }
            }
        }
        .frame(width: 300)
        .frame(maxHeight: .infinity, alignment: .top)
        .background {
            if #available(macOS 26.0, *) {
                Color.clear.glassEffect(.clear, in: RoundedRectangle(cornerRadius: 22))
            } else {
                RoundedRectangle(cornerRadius: 22).fill(.regularMaterial)
            }
        }
    }

    @ViewBuilder
    private var grabsContent: some View {
        if history.entries.isEmpty {
            Text("NO GRABS YET")
                .font(Brand.mono(10)).kerning(1)
                .foregroundStyle(.black.opacity(0.35))
                .padding(.horizontal, 20)
        } else {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(history.entries) { entry in
                    GrabRow(entry: entry)
                    Divider().opacity(0.35).padding(.leading, 20)
                }
            }
            .padding(.bottom, 16)
        }
    }
}

/// One grab, card-styled: 32px thumbnail, a content summary derived from the saved
/// files' extensions, and `FROM @USER` + relative time. Behavior ported from the
/// pre-rail HistoryRow: double-click opens, context menu Reveal/Open, rows whose file
/// is gone are dimmed with actions disabled.
private struct GrabRow: View {
    let entry: GrabHistoryEntry

    var body: some View {
        HStack(spacing: 10) {
            ThumbnailView(path: firstExistingPath, side: 32)
            VStack(alignment: .leading, spacing: 3) {
                Text(GrabRowSummary.text(files: entry.files))
                    .font(Brand.mono(11)).kerning(1)
                    .foregroundStyle(.black.opacity(0.8))
                    .lineLimit(1).truncationMode(.middle)
                secondLine
                    .font(Brand.mono(9))
                    .foregroundStyle(.black.opacity(0.4))
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .opacity(anyFileExists ? 1 : 0.35)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { open() }
        .contextMenu {
            Button("Reveal in Finder") { reveal() }.disabled(!anyFileExists)
            Button("Open") { open() }.disabled(!anyFileExists)
        }
        .help(anyFileExists ? entry.url : "File no longer in Downloads")
    }

    private var secondLine: Text {
        let relative = Text(entry.date, format: .relative(presentation: .named))
        if let user = entry.user {
            return Text("FROM \(user.uppercased()) · ") + relative
        }
        return relative
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
struct ThumbnailView: View {
    let path: String?
    let side: CGFloat
    @State private var thumbnail: NSImage?

    init(path: String?, side: CGFloat = 24) {
        self.path = path
        self.side = side
    }

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
        .frame(width: side, height: side)
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .task(id: path) {
            thumbnail = nil
            guard let path else { return }
            let request = QLThumbnailGenerator.Request(
                fileAt: URL(fileURLWithPath: path),
                size: CGSize(width: side, height: side),
                scale: 2, representationTypes: .thumbnail)
            let generated = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request)
            thumbnail = generated?.nsImage
        }
    }
}
