import XCTest
@testable import Carabiner

final class GrabHistoryStoreTests: XCTestCase {
    private var directory: URL!

    override func setUp() {
        super.setUp()
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("carabiner-history-\(UUID().uuidString)")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
        super.tearDown()
    }

    private func ok(_ file: String, user: String? = nil) -> GrabResult {
        GrabResult(ok: true, message: file, user: user, files: [file])
    }

    func testRecordsSuccessNewestFirst() {
        let store = GrabHistoryStore(directory: directory)
        store.record(url: "https://www.instagram.com/p/AAA/", result: ok("a.mp4"))
        store.record(url: "https://www.instagram.com/p/BBB/", result: ok("b.jpg", user: "@off__piste"))
        XCTAssertEqual(store.entries.map(\.files), [["b.jpg"], ["a.mp4"]])
        XCTAssertEqual(store.entries.first?.user, "@off__piste")
        XCTAssertEqual(store.entries.first?.url, "https://www.instagram.com/p/BBB/")
    }

    func testFailureAndCancelAreNotRecorded() {
        let store = GrabHistoryStore(directory: directory)
        store.record(url: "https://x/a", result: GrabResult(ok: false, message: "Nothing saved"))
        store.record(url: "https://x/b", result: GrabResult(ok: false, message: "Nothing saved", cancelled: true))
        XCTAssertTrue(store.entries.isEmpty)
    }

    func testCapDropsTheOldest() {
        let store = GrabHistoryStore(directory: directory, cap: 3)
        for i in 1...5 { store.record(url: "https://x/\(i)", result: ok("f\(i).mp4")) }
        XCTAssertEqual(store.entries.map(\.files), [["f5.mp4"], ["f4.mp4"], ["f3.mp4"]])
    }

    func testPersistsAcrossInstances() {
        GrabHistoryStore(directory: directory)
            .record(url: "https://www.instagram.com/p/AAA/", result: ok("a.mp4", user: "@u"))
        let reloaded = GrabHistoryStore(directory: directory)
        XCTAssertEqual(reloaded.entries.count, 1)
        XCTAssertEqual(reloaded.entries.first?.files, ["a.mp4"])
        XCTAssertEqual(reloaded.entries.first?.user, "@u")
    }

    /// History is a convenience: garbage on disk must mean an empty list, never a crash —
    /// and recording over it must recover the file.
    func testCorruptFileMeansEmptyAndRecovers() {
        try! FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try! "not json{{{".write(to: directory.appendingPathComponent("history.json"),
                                 atomically: true, encoding: .utf8)
        let store = GrabHistoryStore(directory: directory)
        XCTAssertTrue(store.entries.isEmpty)
        store.record(url: "https://x/a", result: ok("a.mp4"))
        XCTAssertEqual(GrabHistoryStore(directory: directory).entries.count, 1)
    }

    func testMissingDirectoryMeansEmpty() {
        XCTAssertTrue(GrabHistoryStore(directory: directory).entries.isEmpty)
    }
}
