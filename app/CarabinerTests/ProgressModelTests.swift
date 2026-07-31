import XCTest
@testable import Carabiner

final class ProgressParserTests: XCTestCase {
    func testParsesSimpleStages() {
        XCTAssertEqual(ProgressParser.parse("::progress:probe"), .probe)
        XCTAssertEqual(ProgressParser.parse("::progress:prompt"), .prompt)
        XCTAssertEqual(ProgressParser.parse("::progress:save"), .save)
    }

    /// yt-dlp's `%(progress._percent_str)s` is a *display* string — padded, with a percent
    /// sign. Parsing has to survive that rather than assume a bare number.
    func testParsesPaddedPercentString() {
        XCTAssertEqual(ProgressParser.parse("::progress:download:  42.3%"), .download(percent: 42.3))
        XCTAssertEqual(ProgressParser.parse("::progress:download:100.0%"), .download(percent: 100))
    }

    /// yt-dlp prints "N/A" when it does not know the total size, and gallery-dl reports no
    /// percentage at all. Both must degrade to "no data" — which makes the stage creep —
    /// rather than being dropped, which would leave the stage unset entirely.
    func testUnreadablePercentBecomesNoData() {
        XCTAssertEqual(ProgressParser.parse("::progress:download:N/A"), .download(percent: nil))
        XCTAssertEqual(ProgressParser.parse("::progress:download"), .download(percent: nil))
    }

    func testParsesItemAndConvert() {
        XCTAssertEqual(ProgressParser.parse("::progress:item:2:5"), .item(index: 2, total: 5))
        XCTAssertEqual(ProgressParser.parse("::progress:convert:remux"), .convert(.remux))
        XCTAssertEqual(ProgressParser.parse("::progress:convert:encode"), .convert(.encode))
    }

    /// Everything the tools normally print must be ignored, or ordinary log noise would
    /// drive the ring.
    func testIgnoresNonMarkerLines() {
        XCTAssertNil(ProgressParser.parse("[download] 42% of 3MiB"))
        XCTAssertNil(ProgressParser.parse(""))
        XCTAssertNil(ProgressParser.parse("::progress:nonsense"))
        XCTAssertNil(ProgressParser.parse("::progress:item:2"))
    }
}

final class LineBufferTests: XCTestCase {
    /// A marker split across two pipe reads must not be parsed as two half-lines — that
    /// would produce a garbage event and, worse, a plausible-looking one.
    func testReassemblesLineSplitAcrossChunks() {
        var buf = LineBuffer()
        XCTAssertEqual(buf.append(Data("::progr".utf8)), [])
        XCTAssertEqual(buf.append(Data("ess:probe\n".utf8)), ["::progress:probe"])
    }

    func testSplitsMultipleLinesInOneChunk() {
        var buf = LineBuffer()
        XCTAssertEqual(buf.append(Data("a\nb\nc".utf8)), ["a", "b"])
        XCTAssertEqual(buf.flush(), "c")
        XCTAssertNil(buf.flush())
    }
}

final class ProgressModelTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_000_000)
    private func at(_ s: TimeInterval) -> Date { t0.addingTimeInterval(s) }

    /// Creep must stay inside its band: it approaches the ceiling and never crosses it.
    /// Crossing would let an unknown-length stage claim progress belonging to the next one.
    ///
    /// Checked at two time scales on purpose. At 3s the stage is still visibly moving and
    /// the value is strictly below its ceiling. By 60s the exponential has saturated: the
    /// shortfall is ~8e-31, far below what a Double can represent near 0.12, so the value
    /// *is* the ceiling and only "never crosses" is assertable. An earlier version of this
    /// test demanded strict inequality at 60s, which no tau can satisfy — it fails for a
    /// reason that has nothing to do with the creep being wrong.
    func testCreepNeverReachesItsCeiling() {
        var m = ProgressModel(start: t0)
        m.apply(.probe, at: t0)
        XCTAssertLessThan(m.target(at: at(3)), 0.12)
        XCTAssertGreaterThan(m.target(at: at(3)), 0.11)
        XCTAssertLessThanOrEqual(m.target(at: at(60)), 0.12)
    }

    func testDownloadPercentMapsIntoItsBand() {
        var m = ProgressModel(start: t0)
        m.apply(.download(percent: 0), at: t0)
        XCTAssertEqual(m.target(at: t0), 0.12, accuracy: 0.001)
        m.apply(.download(percent: 100), at: at(1))
        XCTAssertEqual(m.target(at: at(1)), 0.75, accuracy: 0.001)
    }

    /// A retreating arc reads as an error. yt-dlp restarts its percentage when it moves
    /// from the video stream to the audio stream, so this is a real input, not a
    /// hypothetical one.
    func testValueNeverDecreases() {
        var m = ProgressModel(start: t0)
        m.apply(.download(percent: 80), at: t0)
        let high = m.target(at: t0)
        m.apply(.download(percent: 5), at: at(1))
        XCTAssertEqual(m.target(at: at(1)), high, accuracy: 0.0001)
    }

    /// The carousel dialog blocks on the user, not on the machine. Creeping there would
    /// claim the tool is working when it is waiting.
    func testPromptFreezesTheValue() {
        var m = ProgressModel(start: t0)
        m.apply(.probe, at: t0)
        let entry = m.target(at: at(2))
        m.apply(.prompt, at: at(2))
        XCTAssertEqual(m.target(at: at(30)), entry, accuracy: 0.0001)
    }

    /// With N items the download+convert range is divided evenly, so a five-slide carousel
    /// advances five times rather than snapping to 96% on the first file.
    func testItemsSubdivideTheDownloadConvertRange() {
        var m = ProgressModel(start: t0)
        m.apply(.item(index: 1, total: 4), at: t0)
        m.apply(.download(percent: 0), at: t0)
        XCTAssertEqual(m.target(at: t0), 0.12, accuracy: 0.001)

        m.apply(.item(index: 4, total: 4), at: at(1))
        m.apply(.convert(.encode), at: at(1))
        // Final slice, convert stage: its ceiling is the end of the whole item range.
        XCTAssertLessThanOrEqual(m.target(at: at(600)), 0.96)
        XCTAssertGreaterThan(m.target(at: at(600)), 0.95)
    }

    func testFinishGoesToFull() {
        var m = ProgressModel(start: t0)
        m.apply(.download(percent: 10), at: t0)
        m.finish(at: at(1))
        XCTAssertEqual(m.target(at: at(1)), 1.0, accuracy: 0.0001)
    }
}
