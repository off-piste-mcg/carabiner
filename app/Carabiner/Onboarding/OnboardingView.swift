import SwiftUI

/// The setup window's body. Deliberately dumb: it renders whatever the view model's
/// presentations say and forwards taps. Nothing here decides anything.
struct OnboardingView: View {
    @ObservedObject var model: OnboardingViewModel

    var body: some View {
        Form {
            Section {
                ForEach(PermissionRow.allCases, id: \.self) { row in
                    let p = model.presentation(for: row)
                    SetupRow(tick: p.tick,
                             title: row.title,
                             why: row.why,
                             detail: p.detail,
                             buttonTitle: p.buttonTitle) { model.act(on: row) }
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

/// One row: SF Symbol status, name + reason, optional detail, optional action button.
private struct SetupRow: View {
    let tick: PermissionRow.Tick
    let title: String
    let why: String
    let detail: String?
    let buttonTitle: String?
    let action: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: tick.symbolName)
                .foregroundStyle(tick == .ok ? Color.green
                                 : tick.isFailure ? Color.red : Color.secondary)
                .font(.body)
                .frame(width: 18)
                .padding(.top, 1)

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
            }
        }
        .padding(.vertical, 2)
    }
}
