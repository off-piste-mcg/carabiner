import AppKit

/// Drives the status item's image while a grab is in flight: a 30fps timer, a smoothed
/// display value, and the complete/hold/fade ending.
///
/// Main-thread only. `GrabRunner.onProgress` fires on a background queue, so callers hop
/// before calling `handle`.
final class RingAnimator {
    private weak var button: NSStatusBarButton?
    private let renderer: StatusIconRenderer
    private var model = ProgressModel(start: Date())
    private var timer: Timer?
    private var displayed: Double = 0
    private var lastTick = Date()
    private var fadeStart: Date?
    /// Set when the grab succeeded: the arc must reach a full circle and be *seen* to,
    /// which is why the fade waits rather than starting the moment the process exits.
    private var holdUntil: Date?

    private static let fps = 30.0
    private static let holdSeconds = 0.5
    private static let fadeSeconds = 0.4

    init(button: NSStatusBarButton?, renderer: StatusIconRenderer) {
        self.button = button
        self.renderer = renderer
        button?.image = renderer.idle()
    }

    func begin() {
        let now = Date()
        model = ProgressModel(start: now)
        displayed = 0
        lastTick = now
        fadeStart = nil
        holdUntil = nil
        button?.image = renderer.busy(progress: 0, alpha: 1)

        timer?.invalidate()
        let t = Timer(timeInterval: 1.0 / Self.fps, repeats: true) { [weak self] _ in self?.tick() }
        // .common, not .default: an open menu runs the run loop in event-tracking mode, and
        // a .default timer would freeze the ring for as long as the menu is down.
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func handle(_ event: ProgressEvent) {
        // Once the ending has started, the run is over and nothing may move the arc again.
        //
        // Defensive, not load-bearing — it cannot fire today, and the comment here used to
        // claim otherwise. The claim was that a hard failure lurches the arc: `ig_video`
        // ends in `echo "$log" >&2`, and that captured log holds every
        // `::progress:download:` line that already went through `tee`, so a failed grab
        // really does report its whole download a second time. What that story missed is
        // *when* the replay lands. `GrabRunner.run` returns only after stderr hits EOF, so
        // every replayed marker is already enqueued on the main queue before
        // `MenuBarController` enqueues `finish(success:)` — and `finish` is the only thing
        // that sets `fadeStart` on the failure path. FIFO therefore guarantees this guard
        // is open when the replay arrives. `testFailureDumpMarkersArriveBeforeTheOutcome`
        // pins that ordering.
        //
        // What actually makes the replay harmless is `ProgressModel.highWater`: the replayed
        // values are ones already applied, and the arc is clamped non-decreasing, so
        // re-applying them targets exactly where it already is. Keep this line as insurance
        // against a future reordering; do not re-promote it to a fix for the lurch.
        guard fadeStart == nil else { return }
        model.apply(event, at: Date())
    }

    func finish(success: Bool) {
        guard timer != nil else { return }
        if success {
            model.finish(at: Date())
        } else {
            // A failed grab stops where it is. Completing the circle would say "done".
            fadeStart = Date()
        }
    }

    private func tick() {
        let now = Date()
        let dt = now.timeIntervalSince(lastTick)
        lastTick = now

        if let fadeStart {
            let f = now.timeIntervalSince(fadeStart) / Self.fadeSeconds
            if f >= 1 { stop(); return }
            button?.image = renderer.busy(progress: displayed, alpha: CGFloat(1 - f))
            return
        }

        let target = model.target(at: now)
        // Exponential smoothing, and never backwards — the model already clamps, this keeps
        // the *displayed* value from overshooting a jump.
        displayed = max(displayed, displayed + (target - displayed) * min(1, dt * 12))

        if model.stage == .complete, displayed >= 0.995 {
            let hold = holdUntil ?? now.addingTimeInterval(Self.holdSeconds)
            holdUntil = hold
            if now >= hold { fadeStart = now }
        }

        button?.image = renderer.busy(progress: displayed, alpha: 1)
    }

    private func stop() {
        timer?.invalidate()
        timer = nil
        // Back to exactly what the menu bar showed before the grab.
        button?.image = renderer.idle()
    }
}
