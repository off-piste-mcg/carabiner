import Foundation

struct GrabResult {
    let ok: Bool
    let message: String
}

struct GrabRunner {
    /// The bundled script when the app ships one, else the Homebrew-installed copy.
    /// Phase 2 bundles it; the fallback keeps a dev build working before `fetch-deps.sh`
    /// has ever run, so an unbundled build fails at the *dependency* check with a real
    /// message instead of "couldn't launch carabiner".
    var executable: String = GrabRunner.bundledExecutable() ?? "/opt/homebrew/bin/carabiner"

    /// Which browser's cookies the script should use. The script reads this from
    /// `CARABINER_BROWSER`, defaulting to chrome — and we hand it our whole environment,
    /// so a stray `CARABINER_BROWSER=safari` would otherwise make the app read the URL
    /// from one browser and pull cookies from another. Setting it explicitly keeps the
    /// two sides in agreement, and is the seam Phase 2's browser picker needs.
    var browser: Browser = .chrome

    /// The app's private binaries. `nil` when this build has no bundled copies, in which
    /// case CARABINER_BIN is left unset entirely and the script uses Homebrew.
    var binDirectory: String? = GrabRunner.binDirectory()

    /// Called once per `::progress:` line the script writes to stderr, in order, on a
    /// background queue. Hop to the main queue before touching any UI.
    var onProgress: ((ProgressEvent) -> Void)?

    static func bundledExecutable() -> String? {
        Bundle.main.url(forResource: "carabiner", withExtension: nil)?.path
    }

    static func binDirectory() -> String? {
        guard let res = Bundle.main.resourceURL?.appendingPathComponent("bin").path,
              FileManager.default.fileExists(atPath: res) else { return nil }
        return res
    }

    func run(url: String) -> GrabResult {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: executable)
        proc.arguments = [url]
        var env = ProcessInfo.processInfo.environment
        env["CARABINER_NO_NOTIFY"] = "1"          // the app owns notifications
        env["CARABINER_BROWSER"] = browser.rawValue
        // Only set it when we actually have one: an empty CARABINER_BIN would put an
        // empty entry at the front of the script's PATH, which means the current
        // directory. See test above.
        if let binDirectory { env["CARABINER_BIN"] = binDirectory }
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
        // stderr is read incrementally rather than to EOF: progress is only useful while
        // the grab is still running, and readDataToEndOfFile would deliver every marker at
        // once, after the thing they describe had already finished.
        queue.async(group: group) {
            let handle = errPipe.fileHandleForReading
            var buffer = LineBuffer()
            while true {
                let chunk = handle.availableData
                if chunk.isEmpty { break }
                errData.append(chunk)
                for line in buffer.append(chunk) {
                    if let event = ProgressParser.parse(line) { self.onProgress?(event) }
                }
            }
            if let last = buffer.flush(), let event = ProgressParser.parse(last) {
                self.onProgress?(event)
            }
        }
        group.wait()
        proc.waitUntilExit()

        let outLines = Self.lines(String(data: outData, encoding: .utf8) ?? "")
        // Markers are stderr too. Left in, the last one would become the failure message —
        // and a grab that died on expired cookies would report a download percentage.
        let errLines = Self.lines(String(data: errData, encoding: .utf8) ?? "")
            .filter { !$0.hasPrefix(ProgressParser.marker) }

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
