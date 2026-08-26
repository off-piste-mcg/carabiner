import Foundation

/// State behind the main window. Pure enough to unit-test the decisions (submit
/// validation, stage text); the window controller wires `onGrab` to the real grab path.
/// Main thread only, like every model in this app.
final class MainViewModel: ObservableObject {
    /// The grab box's text field.
    @Published var urlField = ""
    /// Stage text while a grab this window started is running, nil otherwise.
    @Published private(set) var stage: String?
    /// Whether a window-initiated grab is in flight (disables the button, shows the stage).
    @Published private(set) var grabbing = false
    /// Inline message under the grab box — invalid URL, or busy elsewhere. Cleared on the
    /// next successful submit.
    @Published private(set) var feedback: String?
    /// Which side card is expanded from the rail, nil = collapsed. Set by the rail's
    /// icons, MainWindowController.showSettings(), and the auto-peek; cleared by ✕ /
    /// Esc / a canvas click / window close.
    @Published var panel: SidePanel?
    /// The first-run explainer, nil when it is not showing. A fresh IntroModel per
    /// showing, so reopening from the menu always starts at card 1.
    @Published var intro: IntroModel?

    enum SidePanel { case grabs, settings }

    /// Pending auto-collapse of a peeked grabs card. A manual rail open cancels it so
    /// a deliberate open never snaps shut.
    private var peekCollapse: DispatchWorkItem?

    let history: GrabHistoryStore

    /// Wired by MenuBarController to the shared grab path. Receives the gate's
    /// re-serialised URL, never the raw field text.
    var onGrab: ((String) -> Void)?
    /// Reads MenuBarController.isBusy so a hotkey/extension grab in flight renders as
    /// "already grabbing" instead of silently queue-jumping into a 409-shaped no-op.
    var isBusyElsewhere: () -> Bool = { false }
    /// Records that the explainer has been seen. Wired by MainWindowController to
    /// IntroGate; defaulted here so a model built in a test writes nothing.
    var markIntroSeen: () -> Void = {}
    /// SKIP. MainWindowController uses it to fall through to the first-launch settings
    /// panel when this install has never been offered setup.
    var onIntroSkipped: (() -> Void)?
    /// SET UP PERMISSIONS. MainWindowController opens the settings panel.
    var onIntroFinished: (() -> Void)?

    init(history: GrabHistoryStore) {
        self.history = history
    }

    /// The rail's grabs icon. Manual opens cancel any pending peek collapse.
    func openGrabs() {
        peekCollapse?.cancel(); peekCollapse = nil
        panel = .grabs
    }

    func collapsePanel() {
        peekCollapse?.cancel(); peekCollapse = nil
        panel = nil
    }

    /// First launch and the "How Carabiner works" menu item.
    func showIntro() {
        intro = IntroModel()
    }

    /// SKIP, and closing the window while the explainer is up. Marks it seen — an exit
    /// by an unexpected door must not make the intro reappear next launch.
    func skipIntro() {
        guard intro != nil else { return }
        intro = nil
        markIntroSeen()
        onIntroSkipped?()
    }

    /// SET UP PERMISSIONS on the last card.
    func finishIntro() {
        guard intro != nil else { return }
        intro = nil
        markIntroSeen()
        onIntroFinished?()
    }

    /// The Grab button / return key. Validates through the same allowlist as the
    /// extension and the Dock drop.
    func submit() {
        let text = urlField.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        guard !grabbing else { return }
        guard !isBusyElsewhere() else {
            feedback = "Already grabbing — wait for the current one to finish."
            return
        }
        guard case .ok(let accepted) = GrabGate.checkURL(text) else {
            feedback = "Carabiner grabs https links from Instagram, YouTube and Pinterest."
            return
        }
        feedback = nil
        grabbing = true
        stage = "Reading the link…"
        onGrab?(accepted)
    }

    // MARK: - driven by MenuBarController while the window's grab runs

    func handle(_ event: ProgressEvent) {
        guard grabbing else { return }
        if let text = Self.stageText(for: event) { stage = text }
    }

    func grabFinished(_ result: GrabResult) {
        grabbing = false
        stage = nil
        if result.ok { urlField = "" }
        // Failures already get the outcome banner; mirror the message inline so the
        // answer is where the question was asked. A cancel is a deliberate act — silence,
        // same as the banners.
        if !result.ok && !result.cancelled { feedback = result.message }

        // Auto-peek: show the new row land, then tuck away. Never yanks a panel the
        // user opened (guard nil), and never auto-collapses a manual open (the work
        // item is cancelled by openGrabs/collapsePanel).
        if result.ok && panel == nil {
            panel = .grabs
            let work = DispatchWorkItem { [weak self] in
                guard let self, self.panel == .grabs else { return }
                self.panel = nil
            }
            peekCollapse = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5, execute: work)
        }
    }

    /// Same stage phrasing as BannerPlanner, minus its post/remove state machine — the
    /// window is visible UI, so `.prompt` gets words here where the banner gets removed
    /// (a banner beside the dialog misleads; a status line under the box does not).
    static func stageText(for event: ProgressEvent) -> String? {
        switch event {
        case .probe: return "Checking the post…"
        case .prompt: return "Waiting for your answer…"
        case .download: return "Saving to Downloads"
        case .item(let index, let total):
            return total > 1 ? "Saving slide \(index) of \(total)…" : "Saving to Downloads"
        case .convert, .save: return nil
        }
    }
}
