import SwiftUI

/// The setup window's body. Deliberately dumb: it renders whatever the view model's
/// presentations say and forwards taps. Nothing here decides anything.
struct OnboardingView: View {
    @ObservedObject var model: OnboardingViewModel

    var body: some View {
        Form {
            Section {
                ForEach(PermissionRow.allCases, id: \.self) { row in
                    PermissionToggleRow(title: row.title,
                                        why: row.why,
                                        detail: model.presentation(for: row).detail,
                                        isOn: model.isOn(row)) { desired in
                        model.setEnabled(desired, for: row)
                    }
                }
                SetupRow(tick: model.hotkey.tick,
                         title: "Hotkey",
                         why: "One keystroke, from anywhere.",
                         detail: model.hotkey.detail,
                         buttonTitle: model.hotkey.buttonTitle) { model.onBeginHotkeyTest() }
            } header: {
                header
            } footer: {
                Text("Your first grab may ask for access to Chrome's \"Safe Storage\" — "
                     + "click Always Allow. That's macOS guarding Chrome's cookies, which "
                     + "Carabiner reads to act as you.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.top, 4)
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var header: some View {
        VStack(spacing: 6) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 64, height: 64)
            Text("Carabiner").font(.title2).bold()
            Text("Clip a post. Keep the file.")
                .font(.body)
                .foregroundStyle(.secondary)
            Text("Open an Instagram post in Chrome, press ⌃⌥⌘V, and the file lands in "
                 + "your Downloads folder. Carousels ask: this slide, or all of them.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.top, 2)
        }
        .frame(maxWidth: .infinity)
        .padding(.bottom, 12)
        .textCase(nil)          // Section headers uppercase by default; this is prose.
    }
}

/// A permission row: name + reason on the left, a switch on the right, matching how
/// System Settings presents the same grants.
///
/// The switch is bound to the OS's answer, never to local state. Flipping it sends an
/// intent; the value only moves once the OS agrees. Turning one off opens System Settings
/// and leaves the switch on, because macOS gives an app no way to revoke its own grant —
/// that is honest rather than broken, and the alternative (animating off, then snapping
/// back) would claim something untrue.
private struct PermissionToggleRow: View {
    let title: String
    let why: String
    let detail: String?
    let isOn: Bool
    let onIntent: (Bool) -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.body)
                Text(why).font(.callout).foregroundStyle(.secondary)
                if let detail {
                    Text(detail).font(.callout).foregroundStyle(.secondary)
                }
            }

            Spacer(minLength: 8)

            Toggle("", isOn: Binding(get: { isOn }, set: { onIntent($0) }))
                .labelsHidden()
                .toggleStyle(.switch)
                .accessibilityLabel(title)
        }
        .padding(.vertical, 2)
    }
}

/// The hotkey row. Not a permission — there is nothing to grant, only evidence to gather
/// by listening (gotcha #14) — so it gets a button rather than a switch.
///
/// Its status symbol sits on the TRAILING edge, where the permission rows put their
/// switches. A leading symbol column would indent this row's title ~55pt past the other
/// three, since they have no such column.
private struct SetupRow: View {
    let tick: PermissionRow.Tick
    let title: String
    let why: String
    let detail: String?
    let buttonTitle: String?
    let action: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.body)
                Text(why).font(.callout).foregroundStyle(.secondary)
                if let detail {
                    Text(detail).font(.callout).foregroundStyle(.secondary)
                }
            }

            Spacer(minLength: 8)

            if let buttonTitle {
                Button(buttonTitle, action: action)
            } else {
                // No button means the test resolved; the symbol carries the result.
                Image(systemName: tick.symbolName)
                    .foregroundStyle(tick == .ok ? Color.green
                                     : tick.isFailure ? Color.red : Color.secondary)
                    .font(.body)
                    .padding(.top, 2)
            }
        }
        .padding(.vertical, 2)
    }
}
