import Foundation

struct GrabResult {
    let ok: Bool
    let message: String
}

struct GrabRunner {
    /// Phase 1: the Homebrew-installed script. Phase 2 swaps this for the bundled copy.
    var executable: String = "/opt/homebrew/bin/carabiner"

    /// Which browser's cookies the script should use. The script reads this from
    /// `CARABINER_BROWSER`, defaulting to chrome — and we hand it our whole environment,
    /// so a stray `CARABINER_BROWSER=safari` would otherwise make the app read the URL
    /// from one browser and pull cookies from another. Setting it explicitly keeps the
    /// two sides in agreement, and is the seam Phase 2's browser picker needs.
    var browser: Browser = .chrome

    func run(url: String) -> GrabResult {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: executable)
        proc.arguments = [url]
        var env = ProcessInfo.processInfo.environment
        env["CARABINER_NO_NOTIFY"] = "1"          // the app owns notifications
        env["CARABINER_BROWSER"] = browser.rawValue
        proc.environment = env

        let outPipe = Pipe(), errPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = errPipe
        // `carabiner` branches on `[ -t 0 ]`: with a TTY on stdin it asks the carousel
        // question with `read` instead of the osascript dialog. Launched from a terminal
        // the child would inherit that TTY and block forever on a read nobody answers,
        // so we hand it /dev/null and pin it to the headless branch.
        proc.standardInput = FileHandle.nullDevice

        do { try proc.run() } catch {
            return GrabResult(ok: false, message: "Couldn't launch carabiner: \(error.localizedDescription)")
        }
        // Drain both pipes concurrently. `carabiner` shells out to yt-dlp/ffmpeg, which are
        // very chatty on stderr; reading stdout to EOF first would let the child block writing
        // into a full (~64KB) stderr buffer while we block reading stdout — a permanent hang.
        // Each closure writes its own variable, and `group.wait()` orders those writes before
        // the reads below, so there is no shared mutable state and no data race.
        var outData = Data()
        var errData = Data()
        let group = DispatchGroup()
        let queue = DispatchQueue.global(qos: .userInitiated)
        queue.async(group: group) { outData = outPipe.fileHandleForReading.readDataToEndOfFile() }
        queue.async(group: group) { errData = errPipe.fileHandleForReading.readDataToEndOfFile() }
        group.wait()
        proc.waitUntilExit()

        let outLines = Self.lines(String(data: outData, encoding: .utf8) ?? "")
        let errLines = Self.lines(String(data: errData, encoding: .utf8) ?? "")

        guard proc.terminationStatus == 0 else {
            let last = (outLines + errLines).last ?? ""
            // Only a *leading* marker is decoration; a "✗ " mid-line is part of the message.
            return GrabResult(ok: false, message: last.hasPrefix("✗ ") ? String(last.dropFirst(2)) : last)
        }

        // The script announces every save on stdout as `  ✓ <what>` — a filename for
        // Instagram, `saved to ~/Downloads` for the YouTube/Pinterest/generic paths.
        let saved = outLines.filter { $0.hasPrefix("✓ ") }.map { String($0.dropFirst(2)) }
        if saved.isEmpty {
            // Exit 0 with nothing announced: the user hit Cancel on the carousel prompt
            // (`carabiner` exits 0 there). Not a save — and not a crash either.
            return GrabResult(ok: false, message: "Nothing saved")
        }
        if saved.count == 1 { return GrabResult(ok: true, message: saved[0]) }
        return GrabResult(ok: true, message: "\(saved.count) files")
    }

    /// Non-empty, trimmed lines. Splits on `\r` as well as `\n`: yt-dlp writes its
    /// progress with carriage returns, so a newline-only split collapses a whole
    /// download into one unusable line.
    private static func lines(_ s: String) -> [String] {
        s.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }
}
