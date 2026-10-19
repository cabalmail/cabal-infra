import SwiftUI

/// The actions under a sign-up step: one default action and the ways out.
/// On the Mac they sit in a dialog-style row, the ways out leading and the
/// default action trailing and prominent, answering Return; elsewhere they
/// stack as full-width form rows, default action first
/// (`HostPlatform.formActionsInDialogRow`). The sign-in form's own Sign In
/// and Verify rows draw the same two arrangements.
struct AuthFormActions: View {
    struct Action {
        let title: String
        let identifier: String
        var isEnabled = true
        let perform: () -> Void
    }

    let primary: Action
    var isWorking = false
    var secondary: [Action] = []

    var body: some View {
        if HostPlatform.current.formActionsInDialogRow {
            HStack {
                ForEach(secondary, id: \.identifier) { action in
                    button(for: action)
                }
                Spacer()
                if isWorking {
                    ProgressView()
                        .controlSize(.small)
                }
                button(for: primary)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
        } else {
            Button(action: primary.perform) {
                HStack {
                    Text(primary.title)
                    Spacer()
                    if isWorking {
                        ProgressView()
                    }
                }
            }
            .disabled(!primary.isEnabled)
            .accessibilityIdentifier(primary.identifier)
            ForEach(secondary, id: \.identifier) { action in
                button(for: action)
            }
        }
    }

    private func button(for action: Action) -> some View {
        Button(action.title, action: action.perform)
            .disabled(!action.isEnabled)
            .accessibilityIdentifier(action.identifier)
    }
}
