import Foundation

struct GrabResult {
    let ok: Bool
    let message: String
    /// The user dismissed the carousel dialog. Not a failure to report — the only correct
    /// banner response is silence.
    var cancelled: Bool = false
    /// `@handle` of the Instagram account the grab came from, when the engine reported
    /// one (`::progress:from:` marker). Decoration for the banner — nil is normal.
    var user: String? = nil
    /// Every `✓ <what>` line the script announced, in order — filenames for Instagram,
    /// `saved to ~/Downloads` for the YouTube/Pinterest/generic paths (so an entry is not
    /// guaranteed to be a filename). `message` keeps its one-line summary; this exists for
    /// the grab history, which needs the actual names. Default `[]` so every pre-existing
    /// call site and test is unaffected.
    var files: [String] = []
    /// Whether this failure was specifically yt-dlp/gallery-dl being denied the READ of a
    /// browser's cookie file (as opposed to, say, a deleted post or expired login). Default
    /// `false` so every pre-existing `GrabResult(...)` call site — including every test that
    /// predates this field — is unaffected. Only `run(url:)`'s general failure path ever sets
    /// it `true`; see `isCookieReadFailure`. Exists so `shouldRetryWithChrome` can be a pure
    /// function over structured data instead of re-parsing the message string, which is
    /// already-lossy (only the LAST output line survives into `message`).
    var cookieReadFailure: Bool = false
    /// Set only when `run(url:)`'s Chrome-cookie retry is what actually produced this
    /// SUCCESSFUL result. Review fix round 1, Finding 4: a silent fallback is an honesty
    /// problem — the grab used a DIFFERENT browser's login than the one asked for, which
    /// can mean a different Instagram account, so what landed in Downloads might not be
    /// what the user was looking at. `nil` (the default) means no fallback happened, which
    /// covers every pre-existing call site and test unchanged.
    var usedFallbackBrowser: Browser? = nil
}

/// Pure: does this raw tool output (yt-dlp/gallery-dl's own log, not the trimmed one-line
/// `GrabResult.message`) describe a denied READ of a cookie file? Deliberately narrow —
/// matching both the errno text AND the specific cookie-file name — so it can't misfire on
/// some unrelated "Operation not permitted" elsewhere in a long tool log (a permission error
/// on the *output* file, say), and can't fire on a failure that has nothing to do with
/// cookies at all (a deleted post, an expired login, a rate limit).
///
/// Matches on the substring, not a line-by-line scan: the real error yt-dlp emits wraps the
/// path onto its own line —
///   ERROR: [Errno 1] Operation not permitted:
///     '~/Library/Containers/com.apple.Safari/Data/Library/Cookies/Cookies.binarycookies'
/// — so anchoring to one line would miss it depending on exactly how the two pieces get
/// split across yt-dlp's stdout/stderr interleaving.
func isCookieReadFailure(inRawLog log: String) -> Bool {
    log.contains("Operation not permitted") && log.contains("Cookies.binarycookies")
}

/// Pure: whether a failed grab should be retried once against Chrome's cookies instead of
/// the browser it actually asked for. Scoped deliberately narrow:
///  - only Safari, the one browser whose cookie jar macOS puts behind Full Disk Access —
///    Chrome's is plain-readable, so there is nothing to retry there even if some other
///    error happened to look like this one;
///  - only a genuine cookie-file read failure (`GrabResult.cookieReadFailure`) — any other
///    reason a Safari grab failed (private post, deleted post, expired login) must fail
///    exactly as it always did, not silently retry against a different browser's session.
/// Bounded to one retry by construction: the caller always retries with `.chrome`, and this
/// function returns `false` whenever `browser` is already `.chrome`.
func shouldRetryWithChrome(browser: Browser, result: GrabResult) -> Bool {
    browser == .safari && !result.ok && result.cookieReadFailure
}

/// What the user sees when even the Chrome-cookie retry didn't fix it. "Operation not
/// permitted" on a path nobody recognises is not a diagnosis — name the actual missing
/// grant so it is discoverable from the banner (Setup & Permissions carries the matching
/// Full Disk Access row).
func fullDiskAccessDeniedResult() -> GrabResult {
    GrabResult(ok: false, message: "Full Disk Access needed to read Safari's cookies — see Setup & Permissions")
}

// MARK: - Watchdog (final review, Finding 1)
//
// Before this, `runOnce` ended in a bare `proc.waitUntilExit()` with no bound at all. A
// child that never exited left `MenuBarController.busy` true for the life of the app:
// every extension `/grab` returned 409 forever AND the global hotkey silently no-opped,
// with nothing shown to the user — the only failure on this branch with no recovery short
// of quitting. `GrabServer` already solved the identical shape of problem for its own
// connection deadline (`deadlineAction(for:paused:)`, a 3600s backstop rather than an
// unbounded pause around the carousel dialog) — this reuses that exact decision function
// rather than inventing a second one, so "is the child paused on a human, or has it gone
// quiet" has exactly one answer in the app.

/// Pure: does receiving this event (`nil` for a raw chunk of stderr output that didn't
/// parse as a marker at all — still activity, just not a stage) change whether the
/// watchdog considers the child "paused on the carousel dialog" for the purpose of which
/// inactivity bound applies? Reuses `GrabServer.deadlineAction`'s own backstop/resume/none
/// split — the identical distinction, for the identical reason: `.prompt` blocks on a
/// human answering an osascript dialog, with no bound the engine itself imposes, so it
/// must not be timed against the same short clock as a machine stage that has actually
/// gone silent.
func watchdogPaused(after event: ProgressEvent?, previouslyPaused: Bool) -> Bool {
    guard let event else { return previouslyPaused }
    switch GrabServer.deadlineAction(for: event, paused: previouslyPaused) {
    case .backstop: return true
    case .resume:   return false
    case .none:     return previouslyPaused
    }
}

/// Pure: has the child been silent long enough to be considered hung. `paused` selects
/// which bound applies — see `watchdogPaused(after:previouslyPaused:)`. The one thing
/// worth unit-testing about watchdog policy, exactly as `GrabServer.deadlineAction` is for
/// the connection-level deadline: everything else (scheduling a real timer, killing a real
/// `Process`) needs a live child process and is covered by the integration tests in
/// GrabRunnerTests instead.
func watchdogHasExpired(secondsSinceActivity: TimeInterval, paused: Bool,
                        inactivityBound: TimeInterval, promptBound: TimeInterval) -> Bool {
    secondsSinceActivity >= (paused ? promptBound : inactivityBound)
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

    /// How long the child may go with no progress marker and no other stderr output
    /// before the watchdog considers it hung and kills it — an INACTIVITY bound, not a
    /// total-duration one (Finding 1, final review). Reuses `GrabServer`'s own streaming
    /// bound rather than inventing a shorter one: `ig_gallery` in the bash script wraps
    /// gallery-dl in a single `$(...)` command substitution and reports NOTHING on stderr
    /// between `progress download` and the whole batch finishing — for a several-item
    /// carousel that silence can legitimately span the entire download, not just one
    /// file, so a tight bound here would misfire on exactly the kind of grab this branch
    /// exists to support. `GrabServer.deadline(forStreamingGrab: true)` (600s) was already
    /// tuned generous enough to survive that same real-world case for the connection-level
    /// deadline; reusing it here is even safer, since this one resets on ANY activity
    /// rather than being a hard cap on total duration.
    var watchdogInactivityBound: TimeInterval = GrabRunner.defaultInactivityBound

    /// The bound while the child's last word was `.prompt` — a human reading the
    /// carousel dialog, not a stalled grab. Defaults to `GrabServer.pausedDeadline()`
    /// rather than inventing a second answer to "how long is too long to leave someone on
    /// a dialog": GrabServer already owns that number for the identical event on the
    /// connection side, and `watchdogPaused(after:previouslyPaused:)` reuses its exact
    /// `deadlineAction` decision to detect the same condition here.
    var watchdogPromptBound: TimeInterval = GrabRunner.defaultPromptBound

    static let defaultInactivityBound: TimeInterval = GrabServer.deadline(forStreamingGrab: true)
    static let defaultPromptBound: TimeInterval = GrabServer.pausedDeadline()

    static func bundledExecutable() -> String? {
        Bundle.main.url(forResource: "carabiner", withExtension: nil)?.path
    }

    static func binDirectory() -> String? {
        guard let res = Bundle.main.resourceURL?.appendingPathComponent("bin").path,
              FileManager.default.fileExists(atPath: res) else { return nil }
        return res
    }

    /// One grab attempt, plus (Safari only) the one-shot Chrome-cookie retry described on
    /// `shouldRetryWithChrome`. Callers still see exactly one `GrabResult`, and the fact
    /// that a SECOND child process ran is entirely internal — but which browser's session
    /// actually produced a successful result is not: `GrabResult.usedFallbackBrowser`
    /// carries that through (Finding 4, fix round 1), because it can mean a different
    /// Instagram account entirely, and a caller that stayed silent about it would be lying
    /// by omission about what actually got saved.
    func run(url: String) -> GrabResult {
        let result = runOnce(url: url)
        guard shouldRetryWithChrome(browser: browser, result: result) else { return result }
        NSLog("Carabiner: Safari cookie read failed — retrying %@ with Chrome's cookies", url)
        var retryRunner = self
        retryRunner.browser = .chrome
        var retryResult = retryRunner.runOnce(url: url)
        guard retryResult.ok else {
            // The Chrome retry's own failure reason (almost certainly unrelated — Chrome's
            // cookies are readable) would be a non-sequitur next to a banner about Safari.
            // Name the thing that is actually true and actually fixable instead.
            return fullDiskAccessDeniedResult()
        }
        // Finding 4: a silent fallback is an honesty problem — flag it so the caller can
        // tell the user their Safari grab actually used Chrome's session.
        retryResult.usedFallbackBrowser = .chrome
        return retryResult
    }

    private func runOnce(url: String) -> GrabResult {
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

        // Finding 1: bounds the child so a hung grab can't wedge `busy` forever. Boxed in
        // a class (matching GrabServer.accept's local `PendingDeadline`) because it is
        // written from the stderr-reading queue below and read from the watchdog timer's
        // own queue — both need to agree on "how long ago did the child last do anything"
        // and "is that silence `.prompt`-shaped or ordinary". A LOCAL class declaration —
        // legal in Swift, and the same pattern `GrabServer.accept` already uses for its
        // own per-connection deadline state.
        final class WatchdogState {
            private let lock = NSLock()
            private var lastActivity = Date()
            private var paused = false
            private(set) var fired = false
            func record(event: ProgressEvent?) {
                lock.lock(); defer { lock.unlock() }
                lastActivity = Date()
                paused = watchdogPaused(after: event, previouslyPaused: paused)
            }
            /// Called only from the watchdog timer's own queue. Marks `fired` and returns
            /// whether THIS call is the one that tripped it, so the timer kills the
            /// process exactly once rather than on every subsequent tick.
            func checkExpiry(inactivityBound: TimeInterval, promptBound: TimeInterval) -> Bool {
                lock.lock(); defer { lock.unlock() }
                guard !fired else { return false }
                let elapsed = Date().timeIntervalSince(lastActivity)
                guard watchdogHasExpired(secondsSinceActivity: elapsed, paused: paused,
                                         inactivityBound: inactivityBound, promptBound: promptBound)
                else { return false }
                fired = true
                return true
            }
        }
        let watchdog = WatchdogState()
        let watchdogTimer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
        // Polling rather than rescheduling a one-shot deadline on every event (the way
        // GrabServer's connection deadline works): simpler to reason about — one timer,
        // cancelled exactly once below — and cheap enough at this interval that a grab
        // which finishes normally pays for at most one or two ignored ticks.
        let watchdogPollInterval: TimeInterval = 0.25
        watchdogTimer.schedule(deadline: .now() + watchdogPollInterval, repeating: watchdogPollInterval)
        watchdogTimer.setEventHandler { [inactivityBound = watchdogInactivityBound, promptBound = watchdogPromptBound] in
            guard watchdog.checkExpiry(inactivityBound: inactivityBound, promptBound: promptBound) else { return }
            NSLog("Carabiner: grab watchdog fired — no activity for the bound, terminating the child")
            proc.terminate()
        }
        watchdogTimer.resume()

        // Drain both pipes concurrently. `carabiner` shells out to yt-dlp/ffmpeg, which are
        // very chatty on stderr; reading stdout to EOF first would let the child block writing
        // into a full (~64KB) stderr buffer while we block reading stdout — a permanent hang.
        // Each closure writes its own variable, and `group.wait()` orders those writes before
        // the reads below, so there is no shared mutable state and no data race.
        var outData = Data()
        var errData = Data()
        var user: String?
        let group = DispatchGroup()
        let queue = DispatchQueue.global(qos: .userInitiated)
        queue.async(group: group) { outData = outPipe.fileHandleForReading.readDataToEndOfFile() }
        // stderr is read incrementally rather than to EOF: progress is only useful while
        // the grab is still running, and readDataToEndOfFile would deliver every marker at
        // once, after the thing they describe had already finished. It is also the ONLY
        // place the watchdog observes activity — stdout carries nothing but the final
        // `✓`/`✗` summary line (drained to EOF above, all at once, at the very end), never
        // mid-grab chatter, so stderr is where "the child is still doing something" can
        // actually be observed while it's still running.
        queue.async(group: group) {
            let handle = errPipe.fileHandleForReading
            var buffer = LineBuffer()
            while true {
                let chunk = handle.availableData
                if chunk.isEmpty { break }
                errData.append(chunk)
                let lines = buffer.append(chunk)
                // Bytes arrived but no complete line yet — still activity: a chatty tool
                // mid-write must not look identical to total silence.
                if lines.isEmpty { watchdog.record(event: nil) }
                for line in lines {
                    let event = ProgressParser.parse(line)
                    watchdog.record(event: event)
                    if let event { self.onProgress?(event) }
                    if let u = ProgressParser.parseUser(line) { user = u }
                }
            }
            if let last = buffer.flush() {
                let event = ProgressParser.parse(last)
                watchdog.record(event: event)
                if let event { self.onProgress?(event) }
                if let u = ProgressParser.parseUser(last) { user = u }
            }
        }
        group.wait()
        proc.waitUntilExit()
        watchdogTimer.cancel()

        if watchdog.fired {
            // A normal failure, not a crash — `MenuBarController.grab`'s existing
            // completion path clears `busy` for ANY `GrabResult` exactly the same way, so
            // no second "unstick the app" mechanism is needed here; returning a result at
            // all is what fixes Finding 1.
            return GrabResult(ok: false, message: "Carabiner stopped responding and the grab was cancelled")
        }

        let outLines = Self.lines(String(data: outData, encoding: .utf8) ?? "")
        // Markers are stderr too. Left in, the last one would become the failure message —
        // and a grab that died on expired cookies would report a download percentage.
        let errLines = Self.lines(String(data: errData, encoding: .utf8) ?? "")
            .filter { !$0.hasPrefix(ProgressParser.marker) }

        guard proc.terminationStatus == 0 else {
            let last = (outLines + errLines).last ?? ""
            // isCookieReadFailure needs the RAW log, not `last` — the specific "Operation
            // not permitted: ...Cookies.binarycookies" text is buried mid-log; `die()`'s
            // one-line summary ("download failed.") is what survives into `last`/`message`.
            let rawErr = String(data: errData, encoding: .utf8) ?? ""
            // Only a *leading* marker is decoration; a "✗ " mid-line is part of the message.
            return GrabResult(ok: false,
                              message: last.hasPrefix("✗ ") ? String(last.dropFirst(2)) : last,
                              cookieReadFailure: isCookieReadFailure(inRawLog: rawErr))
        }

        // The script announces every save on stdout as `  ✓ <what>` — a filename for
        // Instagram, `saved to ~/Downloads` for the YouTube/Pinterest/generic paths.
        //
        // A progress marker leaking onto stdout could never be counted here (no `::progress:`
        // line carries a `✓ ` prefix), so a unit test of that property here cannot fail and
        // one was deleted for saying nothing. What genuinely holds the property up is that
        // markers stay off stdout at the source: `test/test-progress.sh` checks 2 and 6.
        let saved = outLines.filter { $0.hasPrefix("✓ ") }.map { String($0.dropFirst(2)) }
        if saved.isEmpty {
            // Exit 0 with nothing announced: the user hit Cancel on the carousel prompt
            // (`carabiner` prints `  cancelled.` and exits 0 there). Not a save — and not
            // a crash either. Anything else that exits 0 without announcing a save is a
            // genuine "nothing happened" worth reporting.
            let cancelled = outLines.contains("cancelled.")
            return GrabResult(ok: false, message: "Nothing saved", cancelled: cancelled)
        }
        if saved.count == 1 { return GrabResult(ok: true, message: saved[0], user: user, files: saved) }
        return GrabResult(ok: true, message: "\(saved.count) files", user: user, files: saved)
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
