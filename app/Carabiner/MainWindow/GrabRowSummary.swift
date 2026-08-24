import Foundation

/// The RECENT GRABS row title: what a grab contained, derived from its filenames.
/// "2 IMAGES, 1 VIDEO" / "1 IMAGE" / "3 VIDEOS"; entries whose files aren't parseable
/// media names (the engine's `saved to ~/Downloads` YouTube/Pinterest rows) collapse
/// to "SAVED TO DOWNLOADS".
enum GrabRowSummary {
    private static let imageExts: Set<String> = ["jpg", "jpeg", "png", "webp", "heic", "gif"]
    private static let videoExts: Set<String> = ["mp4", "mov", "m4v"]

    static func text(files: [String]) -> String {
        var images = 0, videos = 0
        for file in files {
            let ext = (file as NSString).pathExtension.lowercased()
            if imageExts.contains(ext) { images += 1 }
            if videoExts.contains(ext) { videos += 1 }
        }
        var parts: [String] = []
        if images > 0 { parts.append("\(images) IMAGE\(images == 1 ? "" : "S")") }
        if videos > 0 { parts.append("\(videos) VIDEO\(videos == 1 ? "" : "S")") }
        return parts.isEmpty ? "SAVED TO DOWNLOADS" : parts.joined(separator: ", ")
    }
}
