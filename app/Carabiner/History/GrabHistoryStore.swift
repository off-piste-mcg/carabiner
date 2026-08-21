import Foundation

struct GrabHistoryEntry: Codable, Identifiable, Equatable {
    let id: UUID
    let date: Date
    /// The URL the grab was asked for — the post, not the CDN file.
    let url: String
    /// The script's `✓ <what>` announcements. Usually filenames in ~/Downloads, but the
    /// YouTube/Pinterest paths announce `saved to ~/Downloads` — see GrabResult.files.
    let files: [String]
    /// `@handle` when the engine reported one; nil is normal.
    let user: String?
}

/// The recent-grabs history behind the main window. Newest first, capped, persisted as
/// JSON on every record. Main thread only: recording happens in the grab completion,
/// which is already on main, and the `@Published` entries drive SwiftUI.
///
/// Scope limit, stated rather than implied: only app-driven grabs (hotkey, extension,
/// main window, Dock drop) pass the recording point. The Shortcut runs the script with
/// no app involved, so its grabs can never appear here.
final class GrabHistoryStore: ObservableObject {
    @Published private(set) var entries: [GrabHistoryEntry]

    static let defaultCap = 50

    private let fileURL: URL
    private let cap: Int

    /// The real store lives in ~/Library/Application Support/Carabiner/history.json.
    /// `directory` is injectable so tests run against a temp dir, not the user's data.
    init(directory: URL = GrabHistoryStore.defaultDirectory(), cap: Int = GrabHistoryStore.defaultCap) {
        self.fileURL = directory.appendingPathComponent("history.json")
        self.cap = cap
        self.entries = Self.load(from: fileURL)
    }

    static func defaultDirectory() -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Carabiner")
    }

    /// Records a finished grab. Only successes: a failure is the banner's story, and a
    /// cancel is a deliberate act, not an outcome (the same reasoning as BannerPlanner's
    /// silence on cancel).
    func record(url: String, result: GrabResult) {
        guard result.ok else { return }
        let entry = GrabHistoryEntry(id: UUID(), date: Date(), url: url,
                                     files: result.files, user: result.user)
        entries = Array(([entry] + entries).prefix(cap))
        save()
    }

    // MARK: - persistence

    /// A corrupt or missing file means empty history, never a crash — history is a
    /// convenience, and refusing to launch over it would invert its worth.
    private static func load(from url: URL) -> [GrabHistoryEntry] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([GrabHistoryEntry].self, from: data)) ?? []
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(entries) else { return }
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            // Same stance as load: a full disk must not take a grab down with it.
            NSLog("Carabiner: couldn't save grab history — %@", error.localizedDescription)
        }
    }
}
