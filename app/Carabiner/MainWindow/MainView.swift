import SwiftUI
import QuickLookThumbnailing

/// The main window's body: grab box on top, recent grabs below. Deliberately dumb, like
/// OnboardingView — it renders model state and forwards actions.
struct MainView: View {
    @ObservedObject var model: MainViewModel
    @ObservedObject var history: GrabHistoryStore

    init(model: MainViewModel) {
        self.model = model
        self.history = model.history
    }

    var body: some View {
        VStack(spacing: 0) {
            grabBox
                .padding(16)
            Divider()
            historyList
        }
        .frame(minWidth: 460, minHeight: 380)
    }

    private var grabBox: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                TextField("Paste an Instagram, YouTube or Pinterest link", text: $model.urlField)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { model.submit() }
                Button("Grab") { model.submit() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.grabbing)
            }
            if let stage = model.stage {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text(stage).font(.callout).foregroundStyle(.secondary)
                }
            } else if let feedback = model.feedback {
                Text(feedback).font(.callout).foregroundStyle(.secondary)
            }
        }
        // A URL dragged anywhere onto the box submits it — same path as typing it.
        .onDrop(of: [.url, .plainText], isTargeted: nil) { providers in
            loadDroppedURL(from: providers) { dropped in
                model.urlField = dropped
                model.submit()
            }
            return true
        }
    }

    @ViewBuilder
    private var historyList: some View {
        if history.entries.isEmpty {
            VStack(spacing: 6) {
                Text("No grabs yet").font(.title3).foregroundStyle(.secondary)
                Text("Files you grab land in ~/Downloads and show up here.")
                    .font(.callout).foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List(history.entries) { entry in
                HistoryRow(entry: entry)
            }
            .listStyle(.inset)
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

/// One grab: thumbnail, name, @user, when. Rows whose file no longer exists are dimmed
/// with the actions disabled — the history is a record, not a promise the file is there.
private struct HistoryRow: View {
    let entry: GrabHistoryEntry

    var body: some View {
        HStack(spacing: 10) {
            ThumbnailView(path: firstExistingPath)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).lineLimit(1).truncationMode(.middle)
                HStack(spacing: 6) {
                    if let user = entry.user { Text(user) }
                    Text(entry.date, format: .relative(presentation: .named))
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .opacity(anyFileExists ? 1 : 0.4)
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

    private static let side: CGFloat = 40

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
        .clipShape(RoundedRectangle(cornerRadius: 6))
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
