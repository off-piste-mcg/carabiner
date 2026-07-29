import Foundation

struct GrabResult {
    let ok: Bool
    let message: String
}

struct GrabRunner {
    /// Phase 1: the Homebrew-installed script. Phase 2 swaps this for the bundled copy.
    var executable: String = "/opt/homebrew/bin/carabiner"

    func run(url: String) -> GrabResult {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: executable)
        proc.arguments = [url]
        var env = ProcessInfo.processInfo.environment
        env["CARABINER_NO_NOTIFY"] = "1"          // the app owns notifications
        proc.environment = env

        let outPipe = Pipe(), errPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = errPipe

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

        let combined = (String(data: outData, encoding: .utf8) ?? "")
                     + "\n" + (String(data: errData, encoding: .utf8) ?? "")
        let lastLine = combined.split(separator: "\n").map(String.init)
            .last(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) ?? ""

        if proc.terminationStatus == 0 {
            return GrabResult(ok: true, message: "Saved to Downloads")
        } else {
            return GrabResult(ok: false, message: lastLine.replacingOccurrences(of: "✗ ", with: ""))
        }
    }
}
