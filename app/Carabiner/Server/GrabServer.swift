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
    private let queue = DispatchQueue(label: "com.offpiste.carabiner.server")

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
                    self.state = .listening
                    NSLog("Carabiner: extension server listening on 127.0.0.1:%d", Int(self.port))
                case .failed(let e):
                    // Deliberately NOT retrying on another port: the extension has no way
                    // to discover a moved port, so a silent move presents as a button that
                    // does nothing. Surfacing it in onboarding is the honest failure.
                    self.state = .failed(e.localizedDescription)
                    NSLog("Carabiner: extension server failed — %@", e.localizedDescription)
                default: break
                }
            }
            l.newConnectionHandler = { [weak self] c in self?.accept(c) }
            l.start(queue: queue)
            listener = l
        } catch {
            state = .failed(error.localizedDescription)
            NSLog("Carabiner: extension server could not start — %@", error.localizedDescription)
        }
    }

    private func accept(_ connection: NWConnection) {
        connection.start(queue: queue)
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
            guard let request = HTTPRequest(buf) else {
                if isComplete { c.cancel() } else { self.receiveRequest(c, buffer: buf) }
                return
            }
            self.route(request, on: c)
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
            DispatchQueue.main.async { self.lastSeen[browser] = Date() }
        }
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        respond(c, status: 200, origin: request.origin,
                contentType: "application/json",
                body: "{\"app\":\"carabiner\",\"version\":\"\(version)\"}")
    }

    private func preflight(_ request: HTTPRequest, on c: NWConnection) {
        guard let origin = request.origin,
              GrabGate.allowedOriginSchemes.contains(where: { origin.hasPrefix($0) })
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

/// Minimal HTTP/1.1 request. Returns nil while the request is still incomplete, so the
/// caller keeps reading.
struct HTTPRequest {
    let method: String
    let path: String
    let query: [String: String]
    let headers: [String: String]
    let body: String

    init?(_ data: Data) {
        guard let text = String(data: data, encoding: .utf8),
              let headEnd = text.range(of: "\r\n\r\n") else { return nil }
        let head = String(text[text.startIndex..<headEnd.lowerBound])
        var lines = head.components(separatedBy: "\r\n")
        guard !lines.isEmpty else { return nil }
        let requestLine = lines.removeFirst().components(separatedBy: " ")
        guard requestLine.count >= 2 else { return nil }
        method = requestLine[0]
        let target = requestLine[1]
        let parts = target.components(separatedBy: "?")
        path = parts[0]
        var q: [String: String] = [:]
        if parts.count > 1 {
            for pair in parts[1].components(separatedBy: "&") {
                let kv = pair.components(separatedBy: "=")
                if kv.count == 2 { q[kv[0]] = kv[1].removingPercentEncoding ?? kv[1] }
            }
        }
        query = q
        var h: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            h[String(line[line.startIndex..<colon]).lowercased()] =
                String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
        }
        headers = h
        let bodyText = String(text[headEnd.upperBound...])
        // Wait for the whole declared body before routing.
        if let declared = Int(h["content-length"] ?? "0"), bodyText.utf8.count < declared { return nil }
        body = bodyText
    }

    var origin: String? { headers["origin"] }
}
