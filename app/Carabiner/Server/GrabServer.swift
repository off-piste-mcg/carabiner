import Foundation
import Network

/// A loopback-only HTTP/1.1 listener for the browser extension. Hand-rolled rather than
/// pulling in a server package: it serves a handful of routes (`/health`, `/grab`) and
/// the whole surface is small enough to audit, which matters for something holding an
/// open port.
///
/// Bound to 127.0.0.1 ONLY. Never 0.0.0.0 — that would expose it to the network.
final class GrabServer {
    enum State: Equatable { case stopped, listening, failed(String) }

    private let port: UInt16
    private weak var controller: MenuBarController?
    private var listener: NWListener?
    /// The listener's own queue: only ever handles `NWListener` state changes and
    /// incoming-connection callbacks. Deliberately NOT shared with connection I/O any
    /// more (see `accept`) — a shared queue meant one stalled client's reads and this
    /// queue's ability to accept new connections were the same serial resource.
    private let queue = DispatchQueue(label: "com.offpiste.carabiner.server")
    /// A slow or stalled client (a body that never arrives, a request with no `\r\n\r\n`
    /// at all) must not hold its file descriptor open until the app quits. These are
    /// local requests of a few hundred bytes; a few seconds is generous for a legitimate
    /// client and short enough that a stuck one clears itself.
    private static let connectionTimeout: TimeInterval = 5
    /// A `/grab` that has cleared `GrabGate` and won the busy check is no longer an
    /// ordinary request-response exchange — it stays open for the whole download +
    /// re-encode, which routinely runs past `connectionTimeout`. Swapping to this much
    /// longer bound (rather than dropping the deadline for the connection entirely) is
    /// deliberate: `GrabRunner` sets no timeout of its own on the `carabiner` child
    /// process, so a genuinely hung grab (a network stall, a script that never exits)
    /// would otherwise hold this connection's file descriptor open for the life of the
    /// app — exactly the leak `connectionTimeout` was added to close (see Task 6,
    /// Finding 2). Ten minutes is far beyond any real grab (gotcha #21: a full re-encode
    /// is ~12s; a carousel is a handful of those) but still finite, so a truly stuck
    /// child process eventually loses its fd instead of holding it forever.
    ///
    /// This bound governs only the machine-driven stages — probe, download, item,
    /// convert. It deliberately does NOT govern the carousel dialog (corrected in fix
    /// round 1; the original version of this comment implied it did, which was wrong).
    /// `::progress:prompt` blocks on a HUMAN answering an `osascript` dialog, with no
    /// upper bound at all — a user can open a carousel, click the button, and walk away
    /// for lunch. Counting that time against this deadline would cancel the connection
    /// mid-dialog with no terminal `result` line while the grab itself goes on, behind
    /// the scenes, to succeed: the extension's stream would die silently while the app's
    /// own banner correctly reports success. `stream`'s observer swaps this deadline for
    /// `pausedTimeout` for the duration of the prompt and only restores it once a real,
    /// machine-driven event follows — see `deadlineAction(for:paused:)`.
    private static let streamingTimeout: TimeInterval = 600
    /// The backstop while waiting on the carousel dialog (fix round 2; Finding 1).
    /// Round 1 handled the prompt by CANCELLING the deadline outright — `pauseForPrompt`
    /// nilled the pending work item and armed nothing. That reopens exactly the fd leak
    /// `connectionTimeout` exists to close, just gated on a different trigger: if the
    /// child hangs on or right after the dialog and never emits another marker,
    /// `completion` never fires, nothing ever re-arms, and the connection, its
    /// per-connection queue and its `NWConnection` stay open for the life of the app. A
    /// human answering a dialog should not be on a 10-minute clock — but they SHOULD be
    /// on some clock. One hour is generous enough that no real person answering a real
    /// dialog will ever hit it, while still being finite, so a hung child process loses
    /// its fd eventually instead of holding it forever.
    private static let pausedTimeout: TimeInterval = 3600

    /// Pure: which deadline applies to a connection, given whether it has become a
    /// streaming `/grab`. The only thing worth unit-testing about the deadline policy —
    /// everything else about it (scheduling, cancelling, rearming a real `NWConnection`)
    /// needs a live socket and isn't (see `test-progress`/Task 6's own note that this
    /// class of behaviour is verified by requests completing normally, not in isolation).
    static func deadline(forStreamingGrab streaming: Bool) -> TimeInterval {
        streaming ? streamingTimeout : connectionTimeout
    }

    /// The bound applied while on the carousel-dialog backstop (fix round 2, Finding 1).
    /// A separate accessor rather than folding into `deadline(forStreamingGrab:)` — that
    /// function answers a different axis ("streaming or not"), not "on the prompt
    /// backstop or not" — but exposed the same way, as a plain static function, so a test
    /// can pin its relationship to the other bounds without `pausedTimeout` needing to be
    /// anything but `private`.
    static func pausedDeadline() -> TimeInterval { pausedTimeout }

    /// What, if anything, should happen to a streaming connection's deadline in response
    /// to the next progress event. Pure — the actual rearming of a live `NWConnection`'s
    /// timer lives in `stream`'s observer closure; this is only the decision it acts on.
    /// `paused` is the caller's current belief about whether the connection is currently
    /// on the long `pausedTimeout` backstop rather than the ordinary streaming one
    /// (`stream` tracks this as local state, since it is the one place that owns the
    /// sequence of events for a given grab).
    ///
    /// Three outcomes, not two (fix round 2): `.backstop` no longer means "cancel the
    /// deadline" — a paused connection is always on SOME timer, just a much longer one.
    /// `[.prompt] then nothing ever again` must still terminate the connection
    /// eventually, which a bare cancel-and-forget cannot guarantee.
    enum DeadlineAction: Equatable { case backstop, resume, none }

    static func deadlineAction(for event: ProgressEvent, paused: Bool) -> DeadlineAction {
        switch event {
        // `.prompt` can in principle repeat (defensive, not expected from the engine
        // today) — already on the backstop means there is nothing further to arm.
        case .prompt: return paused ? .none : .backstop
        // Any OTHER event arriving while on the backstop means the human answered the
        // dialog and the engine is back to machine-driven work — resume the ordinary
        // streaming clock. Off the backstop, no other event changes anything.
        default: return paused ? .resume : .none
        }
    }

    // `state` and `lastSeen` are both confined to the MAIN queue — the discipline picked
    // for Finding 3, because task 9's onboarding UI reads both from main and that is the
    // one thread every write already needs to reach anyway. Every assignment below,
    // including the ones that already run on a thread that happens to be main (the
    // `start()` catch, called from App.swift at launch), is wrapped in
    // `DispatchQueue.main.async` on purpose: picking "main, always via async" as the one
    // rule means a future writer never has to reason about which of several call sites
    // is allowed to skip it.
    private(set) var state: State = .stopped
    /// Which browsers have proven they can reach us, and when. This is what turns an
    /// onboarding row green — a real connection, never a guess.
    ///
    /// Persisted to UserDefaults (review fix round 1, Finding 2): `GrabServer` itself is
    /// recreated fresh on every app launch, so an in-memory-only dictionary made the
    /// onboarding row's advertised "seen within 14 days" window fiction — it actually meant
    /// "seen since Carabiner was last relaunched", which drops to grey on every ordinary
    /// quit/update/crash no matter how recently a real request landed. Loaded once at
    /// init, written back after every update via `recordLastSeen`. UserDefaults matches the
    /// app's one existing use of it (`OnboardingWindowController.shownDefaultsKey`).
    private(set) var lastSeen: [String: Date] = GrabServer.loadLastSeen()

    private static let lastSeenDefaultsKey = "grabServerLastSeen"

    private static func loadLastSeen() -> [String: Date] {
        (UserDefaults.standard.dictionary(forKey: lastSeenDefaultsKey) as? [String: Date]) ?? [:]
    }

    /// The one place `lastSeen` is written — keeps the in-memory dictionary and its
    /// on-disk copy from drifting apart. MUST be called on main (see the confinement note
    /// above); both call sites already are.
    private func recordLastSeen(_ browser: String, at date: Date) {
        lastSeen[browser] = date
        UserDefaults.standard.set(lastSeen, forKey: Self.lastSeenDefaultsKey)
    }

    init(port: UInt16 = 51847, controller: MenuBarController) {
        self.port = port
        self.controller = controller
    }

    func start() {
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: NWEndpoint.Port(rawValue: port)!)
        params.allowLocalEndpointReuse = true
        do {
            let l = try NWListener(using: params)
            l.stateUpdateHandler = { [weak self] s in
                guard let self else { return }
                switch s {
                case .ready:
                    DispatchQueue.main.async { [weak self] in self?.state = .listening }
                    NSLog("Carabiner: extension server listening on 127.0.0.1:%d", Int(self.port))
                case .failed(let e):
                    // Deliberately NOT retrying on another port: the extension has no way
                    // to discover a moved port, so a silent move presents as a button that
                    // does nothing. Surfacing it in onboarding is the honest failure.
                    DispatchQueue.main.async { [weak self] in self?.state = .failed(e.localizedDescription) }
                    NSLog("Carabiner: extension server failed — %@", e.localizedDescription)
                default: break
                }
            }
            l.newConnectionHandler = { [weak self] c in self?.accept(c) }
            l.start(queue: queue)
            listener = l
        } catch {
            DispatchQueue.main.async { [weak self] in self?.state = .failed(error.localizedDescription) }
            NSLog("Carabiner: extension server could not start — %@", error.localizedDescription)
        }
    }

    private func accept(_ connection: NWConnection) {
        // Each connection gets its OWN queue rather than sharing the listener's — Finding
        // 2. One slow/stalled client used to be the same serial resource as accepting new
        // connections; now it can only block itself.
        let connQueue = DispatchQueue(label: "com.offpiste.carabiner.server.connection")
        connection.start(queue: connQueue)

        // A deadline, not a read timeout: simpler to reason about (one timer per
        // connection, cancelled implicitly by the connection itself finishing — cancel()
        // on an already-cancelled NWConnection is a documented no-op) and sufficient,
        // since a legitimate request completes in well under this window.
        //
        // Boxed in a class, not a local `let`, because this connection's deadline is
        // re-armed repeatedly over its life — 5s at accept, extended to 600s once a real
        // grab starts streaming, then swapped for the 1hr backstop and back around the
        // carousel dialog (Finding 2, fix round 1; Finding 1, fix round 2) — and every one
        // of those needs to cancel whichever `DispatchWorkItem` is *actually* pending
        // right now, not a stale reference to whichever one was scheduled first.
        final class PendingDeadline { var workItem: DispatchWorkItem? }
        let pendingDeadline = PendingDeadline()
        func arm(_ interval: TimeInterval) {
            pendingDeadline.workItem?.cancel()
            let work = DispatchWorkItem { connection.cancel() }
            pendingDeadline.workItem = work
            connQueue.asyncAfter(deadline: .now() + interval, execute: work)
        }
        arm(Self.deadline(forStreamingGrab: false))

        // Both handed all the way down to `grab(_:on:extendDeadline:backstopDeadline:)`.
        // `extendDeadline` is called exactly once for the initial 5s→600s transition, and
        // again as the "resume" half of the prompt backstop/resume cycle — both are the
        // same operation, "arm the ordinary streaming deadline". `backstopDeadline` is
        // called only around `::progress:prompt`, and — fix round 2, Finding 1 — ARMS the
        // long `pausedTimeout` rather than cancelling outright, so a connection can never
        // be left with nothing scheduled while paused. Every other outcome (malformed
        // request, 404, 403, 409, `/health`, a `/grab` that never streams) leaves the
        // original 5s deadline ticking untouched, which is what still protects the
        // listener against a client that stalls or never finishes sending a body.
        let extendForStreaming: () -> Void = { arm(Self.deadline(forStreamingGrab: true)) }
        let backstopForPrompt: () -> Void = { arm(Self.pausedTimeout) }

        receiveRequest(connection, buffer: Data(), extendDeadline: extendForStreaming, backstopDeadline: backstopForPrompt)
    }

    /// Reads until headers are complete and the declared body has arrived. Requests here
    /// are a few hundred bytes; anything over 64 KB is refused rather than buffered.
    private func receiveRequest(_ c: NWConnection, buffer: Data,
                                extendDeadline: @escaping () -> Void, backstopDeadline: @escaping () -> Void) {
        c.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            var buf = buffer
            if let data { buf.append(data) }
            if error != nil || (isComplete && buf.isEmpty) { c.cancel(); return }
            guard buf.count <= 64 * 1024 else {
                self.respond(c, status: 413, body: "too large"); return
            }
            switch HTTPRequest.parse(buf) {
            case .complete(let request):
                self.route(request, on: c, extendDeadline: extendDeadline, backstopDeadline: backstopDeadline)
            case .malformed(let reason):
                // A garbled Content-Length (Finding, minor) would otherwise sit waiting
                // for bytes that can never satisfy it until the connection deadline fires
                // — respond now instead of guessing at a byte count.
                self.respond(c, status: 400, body: reason)
            case .incomplete:
                if isComplete { c.cancel() }
                else { self.receiveRequest(c, buffer: buf, extendDeadline: extendDeadline, backstopDeadline: backstopDeadline) }
            }
        }
    }

    private func route(_ request: HTTPRequest, on c: NWConnection,
                       extendDeadline: @escaping () -> Void, backstopDeadline: @escaping () -> Void) {
        if request.method == "OPTIONS" { return preflight(request, on: c) }
        switch request.path {
        case "/health": health(request, on: c)
        case "/grab": grab(request, on: c, extendDeadline: extendDeadline, backstopDeadline: backstopDeadline)
        default: respond(c, status: 404, body: "no such route")
        }
    }

    /// Gated entirely through `GrabGate.check` — no second origin/host check lives here.
    /// Refuses rather than queues a second concurrent grab (409): a queue would let a
    /// stray double-click stack grabs the user can no longer see or cancel, and the app
    /// has exactly one status-item ring and one working banner to represent "busy" with.
    private func grab(_ request: HTTPRequest, on c: NWConnection,
                      extendDeadline: @escaping () -> Void, backstopDeadline: @escaping () -> Void) {
        guard request.method == "POST" else { return respond(c, status: 404, body: "POST only") }
        let payload = (try? JSONSerialization.jsonObject(with: Data(request.body.utf8))) as? [String: Any]
        switch GrabGate.check(origin: request.origin, url: payload?["url"] as? String) {
        case .rejected(let status, let reason):
            NSLog("Carabiner: /grab rejected (%d) — %@", status, reason)
            // NOT `origin: request.origin` (the brief's snippet, and this task's first
            // draft) — an origin the gate itself just rejected must never be echoed into
            // `Access-Control-Allow-Origin`, or a hostile page's own arbitrary Origin gets
            // reflected straight back, which is the same class of hole as echoing `*`
            // (verified: it let `https://evil.example` read its own 403 body). Re-run
            // `checkOrigin` so a bad-*origin* rejection (403) omits the header entirely —
            // matching `preflight`/`health`'s existing behaviour on the same failure — while
            // a bad-*URL* rejection (400, origin already valid) still echoes it, since that
            // is a legitimate extension the response should be readable to.
            respond(c, status: status, origin: GrabGate.checkOrigin(request.origin), body: reason)
        case .ok(let url):
            let browser = Browser(rawValue: (payload?["browser"] as? String) ?? "") ?? .chrome
            // Keyed off the validated `Browser` enum's rawValue, NOT the caller's raw
            // string (Finding 1, fix round 1). The equivalent value on `/health` is
            // control-character-stripped by `HTTPRequest.parse` specifically because
            // task 11's onboarding UI renders `lastSeen`'s keys directly — this path
            // skipped that mitigation and took the caller's string as-is, so
            // `{"browser":"chrome\r\n..."}` (or a fresh random string every request)
            // would land in `lastSeen` unsanitized and let the dictionary grow without
            // bound. Restricting to `Browser`'s finite case set fixes both problems in
            // one move: an unrecognised name already falls back to `.chrome` for
            // cookie purposes two lines up, so recording presence under that same
            // fallback is consistent, not a new behaviour.
            DispatchQueue.main.async { [weak self] in self?.recordLastSeen(browser.rawValue, at: Date()) }
            // Resolved once, here — a plain value, not a closure re-run per echo site —
            // and reused for every `Access-Control-Allow-Origin` below (500, 409, and
            // `stream`'s headers). Finding 3, fix round 1: those three sites used to
            // pass `request.origin` directly, which is safe only because
            // `GrabGate.check(...) == .ok` implies `checkOrigin(request.origin) != nil`
            // — true today, but a non-local invariant a reader has to go verify instead
            // of seeing it hold on the line itself. Passing the re-validated value
            // everywhere makes each site self-evidently safe.
            let validOrigin = GrabGate.checkOrigin(request.origin)
            DispatchQueue.main.async { [weak self] in
                guard let self, let controller = self.controller else {
                    self?.respond(c, status: 500, origin: validOrigin, body: "no controller"); return
                }
                guard !controller.isBusy else {
                    self.respond(c, status: 409, origin: validOrigin, body: "a grab is already running")
                    return
                }
                self.stream(url: url, browser: browser, controller: controller, origin: validOrigin,
                            on: c, extendDeadline: extendDeadline, backstopDeadline: backstopDeadline)
            }
        }
    }

    /// Sends headers immediately, then one NDJSON line per event, then the terminal
    /// result. The connection stays open for the whole grab — that open connection IS
    /// the progress channel.
    private func stream(url: String, browser: Browser, controller: MenuBarController,
                        origin: String?, on c: NWConnection,
                        extendDeadline: @escaping () -> Void, backstopDeadline: @escaping () -> Void) {
        // Past this point the connection is a legitimate, running grab — trade the short
        // request-response deadline for the long streaming one before doing anything else,
        // so nothing between here and the first byte of the response can race the old timer.
        extendDeadline()

        var head = "HTTP/1.1 200 OK\r\nContent-Type: application/x-ndjson\r\n"
        if let origin { head += "Access-Control-Allow-Origin: \(origin)\r\n" }
        head += "Cache-Control: no-store\r\nConnection: close\r\n\r\n"
        c.send(content: Data(head.utf8), completion: .contentProcessed { _ in })

        let write: (String) -> Void = { line in
            c.send(content: Data(line.utf8), completion: .contentProcessed { _ in })
        }
        // Local to this one grab's event sequence — `stream` is the one place that sees
        // every event in order, so it's the natural owner of "is the deadline currently
        // on the prompt backstop". Fed into the pure `deadlineAction` decision (Finding 2,
        // fix round 1; Finding 1, fix round 2) rather than re-deriving it inline, so the
        // actual backstop/resume logic has exactly one implementation and it's the tested
        // one.
        var deadlinePaused = false
        let observer: (ProgressEvent) -> Void = { event in
            switch Self.deadlineAction(for: event, paused: deadlinePaused) {
            case .backstop:
                deadlinePaused = true
                backstopDeadline()
            case .resume:
                deadlinePaused = false
                extendDeadline()
            case .none:
                break
            }
            write(GrabEvent.line(for: event))
        }
        // The app still posts its own banner: it is what reports the filename and the
        // @user. The in-page ring is additional feedback, not a replacement.
        controller.notifyGrabStarted()
        controller.grab(
            url: url,
            browser: browser,
            observer: observer,
            userObserver: { user in write(GrabEvent.line(forUser: user)) },
            completion: { result in
                // NOT `write(...); c.cancel()` (the brief's snippet, and this task's
                // first draft) — `write` fires `c.send` and returns immediately, so a
                // `cancel()` right after it races the in-flight send: `NWConnection`
                // does not guarantee an enqueued send survives a `cancel()` that lands
                // before its own completion handler runs. Verified against the real
                // bundled binaries: a grab whose only output was one `probe` marker
                // before erroring closed the connection with the `probe` line delivered
                // and the terminal `result` line silently dropped — the client saw the
                // stream end with no outcome at all. `respond(_:status:...)` below
                // already gets this right (`cancel()` nested inside the send's own
                // completion); this is that same fix for the terminal line here.
                let line = GrabEvent.line(for: result)
                c.send(content: Data(line.utf8), completion: .contentProcessed { _ in c.cancel() })
            })
    }

    private func health(_ request: HTTPRequest, on c: NWConnection) {
        // The health check is gated too: an arbitrary page must not be able to fingerprint
        // that Carabiner is installed. A dummy URL keeps the one gate function in charge.
        guard case .ok = GrabGate.check(origin: request.origin,
                                        url: "https://www.instagram.com/p/health/") else {
            return respond(c, status: 403, body: "forbidden")
        }
        if let browser = request.query["browser"], !browser.isEmpty {
            DispatchQueue.main.async { [weak self] in self?.recordLastSeen(browser, at: Date()) }
        }
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        // `checkOrigin(request.origin)`, not `request.origin` (fix round 2, Finding 2 —
        // the last site in the file still echoing the raw header). Safe today for the
        // same distant-invariant reason the round-1 sites were (the `guard case .ok`
        // above already implies `checkOrigin(request.origin) != nil`), but every echo
        // site should be self-evidently safe on its own line, not dependent on a reader
        // tracing that invariant back to the guard above.
        respond(c, status: 200, origin: GrabGate.checkOrigin(request.origin),
                contentType: "application/json",
                body: "{\"app\":\"carabiner\",\"version\":\"\(version)\"}")
    }

    private func preflight(_ request: HTTPRequest, on c: NWConnection) {
        // Finding 1 fix: route through the SAME check `check(origin:url:)` uses, rather
        // than a hand-rolled scheme-prefix test that skipped the character-set
        // validation. See GrabGate.checkOrigin's doc comment for why that mattered.
        guard let origin = GrabGate.checkOrigin(request.origin)
        else { return respond(c, status: 403, body: "forbidden") }
        respond(c, status: 204, origin: origin, body: "")
    }

    fileprivate func respond(_ c: NWConnection, status: Int, origin: String? = nil,
                             contentType: String = "text/plain", body: String) {
        var head = "HTTP/1.1 \(status) \(Self.reason(status))\r\n"
        head += "Content-Type: \(contentType)\r\n"
        head += "Content-Length: \(body.utf8.count)\r\n"
        // Echo only an origin the gate already accepted — never `*`, which would let any
        // page read the response.
        if let origin { head += "Access-Control-Allow-Origin: \(origin)\r\n" }
        head += "Access-Control-Allow-Headers: content-type\r\nConnection: close\r\n\r\n"
        c.send(content: Data((head + body).utf8), completion: .contentProcessed { _ in c.cancel() })
    }

    private static func reason(_ status: Int) -> String {
        switch status {
        case 200: return "OK"
        case 204: return "No Content"
        case 400: return "Bad Request"
        case 403: return "Forbidden"
        case 404: return "Not Found"
        case 409: return "Conflict"
        case 413: return "Payload Too Large"
        default:  return "Error"
        }
    }
}

/// What `HTTPRequest.parse` found. Split into three cases (not just "nil means keep
/// reading") because "not enough bytes yet" and "these bytes will never form a valid
/// request" need different responses: the first tells the caller to keep waiting, the
/// second — a garbled Content-Length, say — should get a 400 immediately rather than
/// wait on bytes that will never arrive to satisfy it.
enum HTTPRequestParseResult {
    case incomplete
    case malformed(reason: String)
    case complete(HTTPRequest)
}

/// Minimal HTTP/1.1 request.
struct HTTPRequest {
    let method: String
    let path: String
    let query: [String: String]
    let headers: [String: String]
    let body: String

    static func parse(_ data: Data) -> HTTPRequestParseResult {
        guard let text = String(data: data, encoding: .utf8),
              let headEnd = text.range(of: "\r\n\r\n") else { return .incomplete }
        let head = String(text[text.startIndex..<headEnd.lowerBound])
        var lines = head.components(separatedBy: "\r\n")
        guard !lines.isEmpty else { return .malformed(reason: "empty request") }
        let requestLine = lines.removeFirst().components(separatedBy: " ")
        guard requestLine.count >= 2 else { return .malformed(reason: "bad request line") }
        let method = requestLine[0]
        let target = requestLine[1]

        // Split on the FIRST "?" only, then the first "=" within each pair — the
        // previous version used `components(separatedBy:)` for both, which splits on
        // EVERY occurrence and silently drops data: `?browser=a=b` lost the value
        // entirely (three `=`-separated parts never matched the `count == 2` check), and
        // `?a=1?b=2` lost `b=2` outright (a second top-level split on "?"). "?" and "="
        // have no special meaning past the first of each, so everything after belongs to
        // the current key/value.
        let path: String
        var q: [String: String] = [:]
        if let qIndex = target.firstIndex(of: "?") {
            path = String(target[target.startIndex..<qIndex])
            let queryString = String(target[target.index(after: qIndex)...])
            for pair in queryString.components(separatedBy: "&") {
                guard let eq = pair.firstIndex(of: "=") else { continue }
                let key = String(pair[pair.startIndex..<eq])
                let rawValue = String(pair[pair.index(after: eq)...])
                let decoded = rawValue.removingPercentEncoding ?? rawValue
                // A decoded value becomes a `lastSeen` dictionary key (GrabServer.health)
                // that task 11's onboarding UI renders directly — strip control
                // characters so a crafted `?browser=chrome%0D%0A...` can't ride along
                // into whatever that UI does with the string. Repeated key: last wins,
                // the same rule used for headers just below, for the same reason.
                let stripped = String(String.UnicodeScalarView(
                    decoded.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }))
                q[key] = stripped
            }
        } else {
            path = target
        }

        var h: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = String(line[line.startIndex..<colon]).lowercased()
            let value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            // Last line wins on a duplicate header (Origin, Content-Length — the only two
            // this server reads). RFC 7230 §3.2.2 permits combining most duplicates with
            // a comma; we need no such combining semantics here, so "last wins" is a
            // deliberate simplification pinned by HTTPRequestTests, not an oversight.
            h[name] = value
        }

        let bodyText = String(text[headEnd.upperBound...])
        let declared: Int
        if let raw = h["content-length"] {
            guard let parsed = Int(raw), parsed >= 0 else {
                return .malformed(reason: "bad content-length")
            }
            declared = parsed
        } else {
            // No header at all means no body, matching ordinary HTTP/1.1 semantics for a
            // request with no declared length and no chunked encoding (which this server
            // does not support).
            declared = 0
        }
        let bodyBytes = Array(bodyText.utf8)
        guard bodyBytes.count >= declared else { return .incomplete }
        // Truncate to exactly the declared length. Task 7 JSON-decodes this body, so
        // trailing bytes beyond Content-Length (there shouldn't be any — `Connection:
        // close` means no pipelining — but a client could still send extra) must not be
        // handed to the decoder as if they belonged to it. `String(decoding:as:)` rather
        // than `String(data:encoding:)` because a length that lands mid multi-byte
        // character must not crash the parser — it degrades to the replacement
        // character rather than failing the whole request; that degradation is a
        // pre-existing, documented limitation (invalid-UTF-8 handling), not something
        // this fix is responsible for closing.
        let body = String(decoding: bodyBytes.prefix(declared), as: UTF8.self)

        return .complete(HTTPRequest(method: method, path: path, query: q, headers: h, body: body))
    }

    var origin: String? { headers["origin"] }
}
