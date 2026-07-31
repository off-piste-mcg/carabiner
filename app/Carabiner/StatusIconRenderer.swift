import AppKit

/// Draws the status item's image: the resting mark, or the mark shrunk inside a progress
/// ring. Pure — a value in, an image out, no state and no timers.
///
/// Geometry was settled by running a throwaway prototype on a real menu bar rather than
/// derived, because a true circle does not fit around the mark at its resting size: the
/// mark is 20.5 x 16pt, so a ring around it lands near 25pt diameter in a 22-24pt bar.
/// Hence the shrink to 10pt for the duration of a grab. See the design doc.
struct StatusIconRenderer {
    static let side: CGFloat = 22
    static let markHeight: CGFloat = 10
    static let stroke: CGFloat = 1.5
    static let trackAlpha: CGFloat = 0.12
    /// The asset is cropped to the mark's own bounds (496:388), so height sets the size
    /// and width follows.
    static let markAspect: CGFloat = 496.0 / 388.0

    let mark: NSImage?

    init(mark: NSImage?) { self.mark = mark }

    /// The resting icon — unchanged from what the menu bar has always shown.
    func idle() -> NSImage? {
        guard let copy = mark?.copy() as? NSImage else { return nil }
        copy.size = NSSize(width: 20.5, height: 16)
        copy.isTemplate = true
        return copy
    }

    func busy(progress: Double, alpha: CGFloat) -> NSImage {
        let side = Self.side, stroke = Self.stroke
        let mark = self.mark
        // Defensive, and deliberately untested: no input distinguishes this from its absence
        // at the pixel level. Negative values are already absorbed by the epsilon guard below,
        // and appendArc traces a complete circle for any sweep past 360°, so a test could only
        // ever assert something true of both implementations. Callers pass 0...1 today;
        // this is here so a future one that doesn't cannot produce a NaN angle.
        let clamped = min(1, max(0, progress))

        let image = NSImage(size: NSSize(width: side, height: side), flipped: false) { _ in
            let centre = NSPoint(x: side / 2, y: side / 2)
            let radius = side / 2 - (stroke / 2 + 0.5)

            let track = NSBezierPath()
            track.appendArc(withCenter: centre, radius: radius, startAngle: 0, endAngle: 360)
            track.lineWidth = stroke
            NSColor.black.withAlphaComponent(Self.trackAlpha * alpha).setStroke()
            track.stroke()

            if clamped > 0.002 {
                // From 12 o'clock, clockwise. AppKit measures anticlockwise from 3 o'clock,
                // so the sweep is 90 degrees *minus* the travelled fraction.
                let arc = NSBezierPath()
                arc.appendArc(withCenter: centre, radius: radius,
                              startAngle: 90, endAngle: 90 - 360 * CGFloat(clamped),
                              clockwise: true)
                arc.lineWidth = stroke
                arc.lineCapStyle = .round
                NSColor.black.withAlphaComponent(alpha).setStroke()
                arc.stroke()
            }

            if let mark {
                let h = Self.markHeight, w = h * Self.markAspect
                mark.draw(in: NSRect(x: (side - w) / 2, y: (side - h) / 2, width: w, height: h),
                          from: .zero, operation: .sourceOver, fraction: alpha)
            }
            return true
        }
        // Template rendering uses only the alpha channel, which is why the 12% track
        // survives tinting and the whole composite still adapts to light and dark bars
        // without a line of appearance-handling code.
        image.isTemplate = true
        return image
    }
}
