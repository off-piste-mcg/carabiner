import AppKit

/// The setup & diagnostics window. Deliberately thin: all decisions come from
/// PermissionRow.presentation(for:) and HotkeyTestModel, which are tested; this file
/// only lays out rows and forwards button clicks.
final class OnboardingWindowController: NSWindowController, NSWindowDelegate {
    private let checker: PermissionChecking
    private let hotkeyIntercept: (@escaping () -> Void) -> Void
    private let clearIntercept: () -> Void

    private var hotkeyModel = HotkeyTestModel()
    private var hotkeyTimer: Timer?
    private var rowViews: [PermissionRow: RowView] = [:]
    private var hotkeyRowView: RowView!

    private static let accent = NSColor(srgbRed: 0x2D / 255.0, green: 0x5B / 255.0,
                                        blue: 0xFF / 255.0, alpha: 1)
    static let shownDefaultsKey = "onboardingShown"

    init(checker: PermissionChecking,
         hotkeyIntercept: @escaping (@escaping () -> Void) -> Void,
         clearIntercept: @escaping () -> Void) {
        self.checker = checker
        self.hotkeyIntercept = hotkeyIntercept
        self.clearIntercept = clearIntercept
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 480),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Carabiner Setup"
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        window.contentView = buildContent()
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    func show() {
        refreshAll()
        NSApp.activate(ignoringOtherApps: true)
        window?.center()
        window?.makeKeyAndOrderFront(nil)
    }

    // MARK: - layout

    private func buildContent() -> NSView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.edgeInsets = NSEdgeInsets(top: 24, left: 28, bottom: 20, right: 28)

        let logo = NSImageView(image: NSApp.applicationIconImage)
        logo.translatesAutoresizingMaskIntoConstraints = false
        logo.widthAnchor.constraint(equalToConstant: 56).isActive = true
        logo.heightAnchor.constraint(equalToConstant: 56).isActive = true

        let pitch = label("Clip a post. Keep the file.", font: .boldSystemFont(ofSize: 16),
                          color: Self.accent)
        let howTo = label(
            "1  Open an Instagram post in Chrome\n2  Press ⌃⌥⌘V\n3  The file lands in ~/Downloads\n\nCarousels ask: this slide, or all of them.",
            font: .monospacedSystemFont(ofSize: 12, weight: .regular))

        stack.addArrangedSubview(logo)
        stack.addArrangedSubview(pitch)
        stack.addArrangedSubview(howTo)
        stack.addArrangedSubview(separator())

        for row in PermissionRow.allCases {
            let v = RowView(title: row.title, why: row.why) { [weak self] in self?.act(on: row) }
            rowViews[row] = v
            stack.addArrangedSubview(v)
        }
        hotkeyRowView = RowView(title: "Hotkey", why: "One keystroke, from anywhere.") { [weak self] in
            self?.beginHotkeyTest()
        }
        stack.addArrangedSubview(hotkeyRowView)

        stack.addArrangedSubview(separator())
        stack.addArrangedSubview(label(
            "Your first grab may ask for access to Chrome's \"Safe Storage\" — click Always Allow. That's macOS guarding Chrome's cookies, which Carabiner reads to act as you.",
            font: .systemFont(ofSize: 11), color: .secondaryLabelColor))
        return stack
    }

    private func label(_ text: String, font: NSFont, color: NSColor = .labelColor) -> NSTextField {
        let l = NSTextField(wrappingLabelWithString: text)
        l.font = font
        l.textColor = color
        l.isSelectable = false
        return l
    }

    private func separator() -> NSBox {
        let b = NSBox()
        b.boxType = .separator
        return b
    }

    // MARK: - permission rows

    private func refreshAll() {
        for row in PermissionRow.allCases { refresh(row) }
        hotkeyRowView.apply(hotkeyModel.presentation)
    }

    private func refresh(_ row: PermissionRow) {
        checker.status(for: row) { [weak self] status in
            self?.rowViews[row]?.apply(row.presentation(for: status))
        }
    }

    private func act(on row: PermissionRow) {
        checker.status(for: row) { [weak self] status in
            guard let self else { return }
            switch row.presentation(for: status).action {
            case .request:
                self.checker.request(row) { _ in self.refresh(row) }
            case .openSystemSettings:
                self.checker.openSystemSettings(for: row)
            case .none:
                self.refresh(row)
            }
        }
    }

    // MARK: - hotkey test

    private func beginHotkeyTest() {
        hotkeyModel.beginTest()
        hotkeyRowView.apply(hotkeyModel.presentation)
        hotkeyIntercept { [weak self] in
            guard let self else { return }
            self.hotkeyTimer?.invalidate()
            self.hotkeyModel.hotkeyFired()
            self.hotkeyRowView.apply(self.hotkeyModel.presentation)
        }
        hotkeyTimer?.invalidate()
        hotkeyTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: false) { [weak self] _ in
            guard let self else { return }
            self.clearIntercept()
            self.hotkeyModel.timeout()
            self.hotkeyRowView.apply(self.hotkeyModel.presentation)
        }
    }

    // MARK: - NSWindowDelegate

    func windowDidBecomeKey(_ notification: Notification) { refreshAll() }

    func windowWillClose(_ notification: Notification) {
        hotkeyTimer?.invalidate()
        clearIntercept()
        UserDefaults.standard.set(true, forKey: Self.shownDefaultsKey)
    }
}

/// One row: name + why on the left, detail/status + button on the right.
private final class RowView: NSView {
    private let statusLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(wrappingLabelWithString: "")
    private let button = NSButton(title: "", target: nil, action: nil)
    private let onButton: () -> Void

    init(title: String, why: String, onButton: @escaping () -> Void) {
        self.onButton = onButton
        super.init(frame: .zero)

        let name = NSTextField(labelWithString: title)
        name.font = .systemFont(ofSize: 13, weight: .semibold)
        let whyLabel = NSTextField(wrappingLabelWithString: why)
        whyLabel.font = .systemFont(ofSize: 11)
        whyLabel.textColor = .secondaryLabelColor
        detailLabel.font = .systemFont(ofSize: 11)
        detailLabel.textColor = .secondaryLabelColor
        statusLabel.font = .systemFont(ofSize: 13)

        button.target = self
        button.action = #selector(buttonTapped)
        button.bezelStyle = .rounded

        let left = NSStackView(views: [name, whyLabel, detailLabel])
        left.orientation = .vertical
        left.alignment = .leading
        left.spacing = 2
        let root = NSStackView(views: [left, NSView(), statusLabel, button])
        root.orientation = .horizontal
        root.alignment = .centerY
        root.translatesAutoresizingMaskIntoConstraints = false
        addSubview(root)
        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: leadingAnchor),
            root.trailingAnchor.constraint(equalTo: trailingAnchor),
            root.topAnchor.constraint(equalTo: topAnchor),
            root.bottomAnchor.constraint(equalTo: bottomAnchor),
            widthAnchor.constraint(greaterThanOrEqualToConstant: 404),
        ])
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    @objc private func buttonTapped() { onButton() }

    func apply(_ p: RowPresentation) {
        apply(tick: p.tick, buttonTitle: p.buttonTitle, detail: p.detail)
    }

    func apply(_ p: HotkeyTestPresentation) {
        apply(tick: p.tick, buttonTitle: p.buttonTitle, detail: p.detail)
    }

    private func apply(tick: PermissionRow.Tick, buttonTitle: String?, detail: String?) {
        switch tick {
        case .ok:      statusLabel.stringValue = "✓"; statusLabel.textColor = .systemGreen
        case .cross:   statusLabel.stringValue = "✗"; statusLabel.textColor = .systemRed
        case .pending: statusLabel.stringValue = "○"; statusLabel.textColor = .tertiaryLabelColor
        }
        button.title = buttonTitle ?? ""
        button.isHidden = buttonTitle == nil
        detailLabel.stringValue = detail ?? ""
        detailLabel.isHidden = detail == nil
    }
}
