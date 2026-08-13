import Foundation
import Network

/// A loopback-only HTTP/1.1 listener for the browser extension. Hand-rolled rather than
/// pulling in a server package: it serves exactly two routes and the whole surface is
/// small enough to audit, which matters for something holding an open port.
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
    private(set) var lastSeen: [String: Date] = [:]

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
        connQueue.asyncAfter(deadline: .now() + Self.connectionTimeout) {
            connection.cancel()
        }
        receiveRequest(connection, buffer: Data())
    }

    /// Reads until headers are complete and the declared body has arrived. Requests here
    /// are a few hundred bytes; anything over 64 KB is refused rather than buffered.
    private func receiveRequest(_ c: NWConnection, buffer: Data) {
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
                self.route(request, on: c)
            case .malformed(let reason):
                // A garbled Content-Length (Finding, minor) would otherwise sit waiting
                // for bytes that can never satisfy it until the connection deadline fires
                // — respond now instead of guessing at a byte count.
                self.respond(c, status: 400, body: reason)
            case .incomplete:
                if isComplete { c.cancel() } else { self.receiveRequest(c, buffer: buf) }
            }
        }
    }

    private func route(_ request: HTTPRequest, on c: NWConnection) {
        if request.method == "OPTIONS" { return preflight(request, on: c) }
        switch request.path {
        case "/health": health(request, on: c)
        default: respond(c, status: 404, body: "no such route")
        }
    }

    private func health(_ request: HTTPRequest, on c: NWConnection) {
        // The health check is gated too: an arbitrary page must not be able to fingerprint
        // that Carabiner is installed. A dummy URL keeps the one gate function in charge.
        guard case .ok = GrabGate.check(origin: request.origin,
                                        url: "https://www.instagram.com/p/health/") else {
            return respond(c, status: 403, body: "forbidden")
        }
        if let browser = request.query["browser"], !browser.isEmpty {
            DispatchQueue.main.async { [weak self] in self?.lastSeen[browser] = Date() }
        }
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        respond(c, status: 200, origin: request.origin,
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
