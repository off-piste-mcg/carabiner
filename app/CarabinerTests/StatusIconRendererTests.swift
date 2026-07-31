import XCTest
import AppKit
@testable import Carabiner

final class StatusIconRendererTests: XCTestCase {
    private func renderer() -> StatusIconRenderer {
        StatusIconRenderer(mark: NSImage(named: "StatusIcon"))
    }

    /// Alpha at a point, 0...1. Sampled from a bitmap rendered at 1x.
    private func alpha(_ image: NSImage, x: Int, y: Int) -> CGFloat {
        let rep = NSBitmapImageRep(data: image.tiffRepresentation!)!
        return rep.colorAt(x: x, y: y)?.alphaComponent ?? 0
    }

    /// Template rendering is what makes the icon adapt to a light or dark menu bar with no
    /// appearance-handling code. Losing the flag is invisible on whichever appearance the
    /// developer happens to be using.
    func testBothImagesAreTemplates() {
        XCTAssertTrue(renderer().busy(progress: 0.5, alpha: 1).isTemplate)
        XCTAssertEqual(renderer().idle()?.isTemplate, true)
    }

    func testSizes() {
        XCTAssertEqual(renderer().busy(progress: 0.5, alpha: 1).size, NSSize(width: 22, height: 22))
        XCTAssertEqual(renderer().idle()?.size, NSSize(width: 20.5, height: 16))
    }

    /// Alpha at a point on the ring, addressed by clock angle (0 = 12 o'clock, growing
    /// clockwise). Two things this hides are worth stating: the bitmap's origin is the
    /// TOP-left while the drawing runs in AppKit's y-up space, so y is flipped here; and
    /// the bitmap may be rendered at device scale, so every coordinate is derived from the
    /// rep's own pixel dimensions rather than from the 22pt point size.
    private func onRing(_ image: NSImage, clock degrees: Double) -> CGFloat {
        let rep = NSBitmapImageRep(data: image.tiffRepresentation!)!
        let w = Double(rep.pixelsWide), h = Double(rep.pixelsHigh)
        let scale = w / Double(StatusIconRenderer.side)
        let radius = w / 2 - (Double(StatusIconRenderer.stroke) / 2 + 0.5) * scale
        let rad = degrees * .pi / 180
        let x = w / 2 + radius * sin(rad)
        let yUp = h / 2 + radius * cos(rad)
        let px = min(max(Int(x.rounded(.down)), 0), rep.pixelsWide - 1)
        let py = min(max(Int((h - yUp).rounded(.down)), 0), rep.pixelsHigh - 1)
        return rep.colorAt(x: px, y: py)?.alphaComponent ?? 0
    }

    /// Guards the sampler itself. A full circle must be on the arc at every cardinal point
    /// and an empty one at none — if this fails, `onRing` is addressing the wrong pixels
    /// and every assertion below it is meaningless rather than wrong.
    func testRingSamplerFindsAFullCircleAndNotAnEmptyOne() {
        let r = renderer()
        let full = r.busy(progress: 1, alpha: 1)
        let empty = r.busy(progress: 0, alpha: 1)
        for deg in [0.0, 90.0, 180.0, 270.0] {
            XCTAssertGreaterThan(onRing(full, clock: deg), 0.5, "full circle at \(deg)°")
            XCTAssertLessThan(onRing(empty, clock: deg), 0.5, "empty ring at \(deg)°")
        }
    }

    func testArcStartsAtTwelveOClock() {
        XCTAssertGreaterThan(onRing(renderer().busy(progress: 0.1, alpha: 1), clock: 0), 0.5)
    }

    /// Direction is only observable where the two directions differ. Six o'clock is reached
    /// at 50% either way, so it cannot tell them apart — three and nine o'clock can: sweeping
    /// clockwise, 30% progress has passed 3 o'clock and is nowhere near 9.
    func testArcSweepsClockwiseNotAnticlockwise() {
        let third = renderer().busy(progress: 0.3, alpha: 1)
        XCTAssertGreaterThan(onRing(third, clock: 90), 0.5, "3 o'clock should be swept by 30%")
        XCTAssertLessThan(onRing(third, clock: 270), 0.5, "9 o'clock should not be swept by 30%")
    }

    /// The fade at the end of a grab has to actually fade.
    func testAlphaScalesTheWholeComposite() {
        let r = renderer()
        let opaque = alpha(r.busy(progress: 1, alpha: 1), x: 11, y: 21)
        let faded = alpha(r.busy(progress: 1, alpha: 0.25), x: 11, y: 21)
        XCTAssertLessThan(faded, opaque)
    }

    /// A missing asset must not crash the menu bar — it draws the ring and no mark.
    func testSurvivesAMissingMark() {
        let r = StatusIconRenderer(mark: nil)
        XCTAssertEqual(r.busy(progress: 0.5, alpha: 1).size, NSSize(width: 22, height: 22))
        XCTAssertNil(r.idle())
    }
}
