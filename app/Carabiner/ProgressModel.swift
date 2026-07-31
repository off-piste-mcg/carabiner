import Foundation

/// One thing the script has told us about where it has got to. The script reports stages
/// and local progress; the mapping onto a circle lives here, in the app, because the
/// circle is an app concern the script must stay ignorant of.
enum ProgressEvent: Equatable {
    case probe
    case prompt
    /// `nil` means the tool cannot report a percentage (gallery-dl always, yt-dlp when the
    /// total size is unknown). That stage creeps instead.
    case download(percent: Double?)
    case item(index: Int, total: Int)
    case convert(ConvertMode)
    case save
}

enum ConvertMode: String, Equatable {
    case remux, encode
}

enum ProgressStage: Equatable {
    case resolve, probe, prompt, download, convert, save, complete
}

enum ProgressParser {
    static let marker = "::progress:"

    static func parse(_ rawLine: String) -> ProgressEvent? {
        let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
        guard line.hasPrefix(marker) else { return nil }
        let fields = line.dropFirst(marker.count).components(separatedBy: ":")
        switch fields.first {
        case "probe":  return .probe
        case "prompt": return .prompt
        case "save":   return .save
        case "download":
            return .download(percent: fields.count > 1 ? percent(fields[1]) : nil)
        case "item":
            guard fields.count > 2, let i = Int(fields[1]), let n = Int(fields[2]),
                  i > 0, n > 0 else { return nil }
            return .item(index: i, total: n)
        case "convert":
            guard fields.count > 1, let mode = ConvertMode(rawValue: fields[1]) else { return nil }
            return .convert(mode)
        default:
            return nil
        }
    }

    /// yt-dlp's `%(progress._percent_str)s` is a display string: space-padded, carrying a
    /// percent sign, and literally "N/A" before the total size is known. Parse leniently —
    /// anything unreadable becomes "no data", which creeps, rather than an event we drop.
    private static func percent(_ field: String) -> Double? {
        let cleaned = field.replacingOccurrences(of: "%", with: "")
                           .trimmingCharacters(in: .whitespaces)
        guard let v = Double(cleaned), v.isFinite else { return nil }
        return min(100, max(0, v))
    }
}

/// Accumulates arbitrary byte chunks from a pipe and hands back whole lines. Pipe reads
/// land on no particular boundary, so a marker can arrive in two pieces; parsing those
/// pieces separately would produce a plausible-looking garbage event.
struct LineBuffer {
    private var pending = Data()

    mutating func append(_ chunk: Data) -> [String] {
        pending.append(chunk)
        var out: [String] = []
        while let nl = pending.firstIndex(of: 0x0A) {
            out.append(String(data: pending[..<nl], encoding: .utf8) ?? "")
            pending = Data(pending[(nl + 1)...])
        }
        return out
    }

    /// Whatever is left when the stream ends without a trailing newline.
    mutating func flush() -> String? {
        defer { pending = Data() }
        return pending.isEmpty ? nil : String(data: pending, encoding: .utf8)
    }
}

/// Turns a sequence of events into a 0...1 arc value.
struct ProgressModel {
    private struct Slice { let index: Int; let total: Int }

    private(set) var stage: ProgressStage = .resolve
    private var stageStart: Date
    private var downloadPercent: Double?
    private var convertMode: ConvertMode = .encode
    private var slice: Slice?
    /// The value is clamped non-decreasing: yt-dlp restarts its percentage when it moves
    /// from the video stream to the audio stream, and an arc that retreats reads as an error.
    private var highWater: Double = 0
    private var frozen: Double = 0

    init(start: Date) { stageStart = start }

    mutating func apply(_ event: ProgressEvent, at now: Date) {
        switch event {
        case .probe:  enterIfChanged(.probe, at: now)
        case .prompt: enterIfChanged(.prompt, at: now)
        case .save:   enterIfChanged(.save, at: now)
        case .download(let p):
            enterIfChanged(.download, at: now)
            downloadPercent = p
        case .convert(let mode):
            convertMode = mode
            enterIfChanged(.convert, at: now)
        case .item(let i, let n):
            slice = Slice(index: i, total: n)
            // A new item always restarts the download stage, even from the download stage —
            // its creep and its percentage belong to the new slice, not the old one.
            enter(.download, at: now)
        }
    }

    mutating func finish(at now: Date) { enterIfChanged(.complete, at: now) }

    mutating func target(at now: Date) -> Double {
        let band = currentBand()
        let raw: Double
        switch stage {
        case .prompt:
            raw = frozen
        case .complete:
            raw = 1.0
        case .download where downloadPercent != nil:
            raw = band.lo + (band.hi - band.lo) * (downloadPercent! / 100)
        default:
            let elapsed = max(0, now.timeIntervalSince(stageStart))
            raw = band.lo + (band.hi - band.lo) * (1 - exp(-elapsed / Self.tau(stage, convertMode)))
        }
        highWater = max(highWater, raw)
        return highWater
    }

    // MARK: - policy

    private static let itemLo = 0.12, itemHi = 0.96
    /// Within one item's slice, download and convert keep the same 3:1 proportion they
    /// have globally (0.63 wide against 0.21).
    private static let downloadShareOfSlice = 0.75

    static func band(_ stage: ProgressStage) -> (lo: Double, hi: Double) {
        switch stage {
        case .resolve:  return (0.00, 0.05)
        case .probe:    return (0.05, 0.12)
        case .prompt:   return (0.12, 0.12)
        case .download: return (0.12, 0.75)
        case .convert:  return (0.75, 0.96)
        case .save:     return (0.96, 1.00)
        case .complete: return (1.00, 1.00)
        }
    }

    static func tau(_ stage: ProgressStage, _ mode: ConvertMode) -> Double {
        switch stage {
        case .probe:   return 8.0
        case .convert: return mode == .remux ? 0.25 : 1.6
        default:       return 0.7
        }
    }

    private func currentBand() -> (lo: Double, hi: Double) {
        let base = Self.band(stage)
        guard let slice, slice.total > 1,
              stage == .download || stage == .convert else { return base }
        let width = (Self.itemHi - Self.itemLo) / Double(slice.total)
        let lo = Self.itemLo + width * Double(slice.index - 1)
        let split = lo + width * Self.downloadShareOfSlice
        return stage == .download ? (lo, split) : (split, lo + width)
    }

    private mutating func enterIfChanged(_ s: ProgressStage, at now: Date) {
        guard s != stage else { return }
        enter(s, at: now)
    }

    private mutating func enter(_ s: ProgressStage, at now: Date) {
        if s == .prompt { frozen = highWater }
        stage = s
        stageStart = now
        downloadPercent = nil
    }
}
