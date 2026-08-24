import SwiftUI

/// The settings card's scrollable content: the Setup & Permissions rows re-housed in
/// brand style. Renders OnboardingViewModel and forwards intents — every permission
/// decision stays in that model (untouched; gotchas #28/#37/#40 live there). The card
/// chrome (header/✕/width/background) lives in SideRail now; this view owns only the
/// rows. Its one own decision is actionTitle(row:isOn:notApplicable:), which is pure
/// and tested (kept as SettingsPanel.actionTitle — SettingsPanelTests points at it).
struct SettingsContent: View {
    @ObservedObject var model: OnboardingViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            ForEach(PermissionRow.allCases, id: \.self) { row in
                PanelRow(
                    title: row.title.uppercased(),
                    detail: model.presentation(for: row).detail ?? row.why,
                    state: model.isNotApplicable(row) ? .notApplicable
                         : model.isOn(row) ? .on : .off,
                    actionTitle: SettingsPanel.actionTitle(row: row,
                                                  isOn: model.isOn(row),
                                                  notApplicable: model.isNotApplicable(row)),
                    manageTitle: SettingsPanel.manageTitle(row: row,
                                                  isOn: model.isOn(row),
                                                  notApplicable: model.isNotApplicable(row)),
                    action: { desiredOn in model.setEnabled(desiredOn, for: row) })
            }
            hotkeyRow
            Text("Your first grab may ask for access to Chrome's \"Safe Storage\" — "
                 + "click Always Allow. That's macOS guarding Chrome's cookies, which "
                 + "Carabiner reads to act as you.")
                .font(Brand.mono(9))
                .foregroundStyle(.black.opacity(0.4))
                .padding(.top, 4)
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 20)
    }

    @ViewBuilder
    private var hotkeyRow: some View {
        HStack(alignment: .top, spacing: 10) {
            StatusDot(state: model.hotkey.tick == .ok ? .on
                      : model.hotkey.tick.isFailure ? .failed : .off)
            VStack(alignment: .leading, spacing: 3) {
                Text("HOTKEY").font(Brand.mono(11)).kerning(1)
                Text(model.hotkey.detail ?? "One keystroke, from anywhere.")
                    .font(Brand.mono(9)).foregroundStyle(.black.opacity(0.45))
            }
            Spacer(minLength: 8)
            if let buttonTitle = model.hotkey.buttonTitle {
                Button(buttonTitle.uppercased()) { model.onBeginHotkeyTest() }
                    .buttonStyle(.plain)
                    .font(Brand.mono(10)).kerning(1)
                    .foregroundStyle(.black)
                    .padding(.horizontal, 10).padding(.vertical, 4)
                    .background(Capsule().fill(Brand.yellow))
            }
        }
    }
}

/// Namespace for the card's one own decision, kept at this name (not folded into
/// SettingsContent) because SettingsPanelTests points at `SettingsPanel.actionTitle`.
enum SettingsPanel {
    /// Which action a row offers. ALLOW when ungranted; nothing when granted (macOS
    /// offers no revoke) — except Launch at login, the one row that can honestly turn
    /// itself off; nothing when not applicable (nothing to flip on this machine).
    static func actionTitle(row: PermissionRow, isOn: Bool, notApplicable: Bool) -> String? {
        if notApplicable { return nil }
        if !isOn { return "ALLOW" }
        return row == .launchAtLogin ? "DISABLE" : nil
    }

    /// The quiet secondary action on a granted row: MANAGE opens the System Settings
    /// pane where the real switch lives (macOS gives the app no revoke of its own).
    /// Only rows whose switch IS in System Settings — not launchAtLogin (real DISABLE),
    /// not browserButton (its off-switch is the browser's extension UI, unreachable
    /// from here); never when off or notApplicable.
    static func manageTitle(row: PermissionRow, isOn: Bool, notApplicable: Bool) -> String? {
        guard isOn, !notApplicable else { return nil }
        switch row {
        case .notifications, .browserAccess, .carouselDialog, .fullDiskAccess: return "MANAGE"
        case .launchAtLogin, .browserButton: return nil
        }
    }
}

/// One permission row: dot, mono caps title, quiet detail, optional pill action.
private struct PanelRow: View {
    enum RowState { case on, off, notApplicable }

    let title: String
    let detail: String
    let state: RowState
    let actionTitle: String?
    /// MANAGE — quiet, hollow: navigates to System Settings rather than acting.
    let manageTitle: String?
    /// Called with the desired on/off — ALLOW sends true, DISABLE and MANAGE send false
    /// (a granted row's "off" resolves to .openSystemSettings in the model).
    let action: (Bool) -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            StatusDot(state: state == .on ? .on : state == .off ? .off : .dim)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(Brand.mono(11)).kerning(1)
                    .foregroundStyle(state == .notApplicable ? .black.opacity(0.35) : .black)
                Text(detail).font(Brand.mono(9)).foregroundStyle(.black.opacity(0.45))
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            if let actionTitle {
                Button(actionTitle) { action(actionTitle == "ALLOW") }
                    .buttonStyle(.plain)
                    .font(Brand.mono(10)).kerning(1)
                    .foregroundStyle(.black)
                    .padding(.horizontal, 10).padding(.vertical, 4)
                    .background(Capsule().fill(Brand.yellow))
            }
            if let manageTitle {
                Button(manageTitle) { action(false) }
                    .buttonStyle(.plain)
                    .font(Brand.mono(10)).kerning(1)
                    .foregroundStyle(.black.opacity(0.6))
                    .padding(.horizontal, 10).padding(.vertical, 4)
                    .background(Capsule().strokeBorder(.black.opacity(0.3), lineWidth: 1))
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(title)
    }
}

/// Filled yellow = granted; hollow = not; dim = nothing to grant; red = test failed.
private struct StatusDot: View {
    enum DotState { case on, off, dim, failed }
    let state: DotState

    var body: some View {
        Group {
            switch state {
            case .on: Circle().fill(Brand.yellow)
            case .off: Circle().strokeBorder(.black.opacity(0.35), lineWidth: 1)
            case .dim: Circle().fill(.black.opacity(0.15))
            case .failed: Circle().fill(.red.opacity(0.8))
            }
        }
        .frame(width: 8, height: 8)
        .padding(.top, 3)
    }
}
