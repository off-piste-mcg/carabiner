import XCTest
@testable import Carabiner

/// The loopback smoke test Finding 3(a) (final review) asks for: every OTHER test in
/// GrabServerTests.swift exercises a pure decision function only — none of them ever
/// construct a real `GrabServer`. Proof, not assertion: deleting the `OPTIONS` branch from
/// `route()` (the CORS-preflight handler gotcha #29 calls load-bearing for Safari alone)
/// left all 204 Swift tests passing before this file existed. This class drives an actual
/// socket against an actual `GrabServer` instance so that class of regression has real
/// teeth again.
///
/// Deliberately narrow, per the brief: four checks over a real connection, not a
/// reimplementation of GrabServerTests' pure-function coverage.
final class GrabServerLoopbackTests: XCTestCase {
    // A distinct port PER TEST METHOD, not one shared for the whole class (measured
    // necessary: Xcode's default parallel test execution ran two of this class's own
    // setUp() calls at the identical millisecond, and whichever lost the race to bind a
    // single shared port failed with EADDRINUSE — a real flake, not a hypothetical one).
    // `GrabServer` has no `stop()`/teardown to wait on either, so even serial execution
    // would leave the next test racing the previous listener's async deallocation. A
    // per-test counter sidesteps both causes at once. Starts well off the real app's fixed
    // 51847 (GrabGate's whole reason for a FIXED port is that the extension has no way to
    // discover a moved one) — a dev build of Carabiner.app running on the same machine
    // while this suite runs must not collide with it either.
    private final class PortCounter {
        private let lock = NSLock()
        private var next: UInt16 = 51900
        func take() -> UInt16 { lock.lock(); defer { lock.unlock() }; next += 1; return next }
    }
    private static let portCounter = PortCounter()
    private var port: UInt16 = 0

    private var controller: MenuBarController!
    private var server: GrabServer!

    override func setUpWithError() throws {
        try super.setUpWithError()
        port = Self.portCounter.take()
        // GrabServer only needs a MenuBarController to hold weakly (isBusy/notifyGrabStarted/
        // grab); none of the four checks below reach `/grab`'s success path, so a plain,
        // freshly-constructed controller is all any of them touch.
        controller = MenuBarController()
        server = GrabServer(port: port, controller: controller)
        server.start()
        waitUntilListening()
    }

    override func tearDown() {
        server = nil
        controller = nil
        super.tearDown()
    }

    /// `state` is written via `DispatchQueue.main.async` from NWListener's own callback
    /// (GrabServer's documented main-queue confinement) — this test runs on main too, so
    /// polling has to PUMP the run loop rather than block it, or the queued `.main.async`
    /// write can never actually land.
    private func waitUntilListening(timeout: TimeInterval = 3) {
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            if case .listening = server.state { return }
            if Date() >= deadline {
                XCTFail("server never reached .listening (state: \(server.state))")
                return
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
    }

    private struct Response { let status: Int; let headers: [AnyHashable: Any] }

    private func send(method: String, path: String, origin: String?, body: Data? = nil) -> Response? {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)\(path)")!)
        request.httpMethod = method
        if let origin { request.setValue(origin, forHTTPHeaderField: "Origin") }
        if let body { request.httpBody = body }
        request.timeoutInterval = 5

        var result: Response?
        let done = expectation(description: "\(method) \(path)")
        URLSession.shared.dataTask(with: request) { _, response, _ in
            if let http = response as? HTTPURLResponse {
                result = Response(status: http.statusCode, headers: http.allHeaderFields)
            }
            done.fulfill()
        }.resume()
        wait(for: [done], timeout: 5)
        return result
    }

    // MARK: - the four checks

    func testOptionsFromAnExtensionOriginGetsNoContentAndEchoesTheOrigin() {
        guard let r = send(method: "OPTIONS", path: "/grab", origin: "chrome-extension://abc") else {
            return XCTFail("no HTTP response")
        }
        XCTAssertEqual(r.status, 204)
        XCTAssertEqual(r.headers["Access-Control-Allow-Origin"] as? String, "chrome-extension://abc")
    }

    func testOptionsFromAWebPageOriginIsForbidden() {
        guard let r = send(method: "OPTIONS", path: "/grab", origin: "https://evil.example") else {
            return XCTFail("no HTTP response")
        }
        XCTAssertEqual(r.status, 403)
    }

    func testHealthFromAnExtensionOriginSucceeds() {
        guard let r = send(method: "GET", path: "/health", origin: "chrome-extension://abc") else {
            return XCTFail("no HTTP response")
        }
        XCTAssertEqual(r.status, 200)
    }

    func testRequestOverTheSixtyFourKBCapIsRejected() {
        let big = Data(repeating: 0x61, count: 70 * 1024)
        guard let r = send(method: "POST", path: "/grab", origin: "chrome-extension://abc", body: big) else {
            return XCTFail("no HTTP response")
        }
        XCTAssertEqual(r.status, 413)
    }
}
