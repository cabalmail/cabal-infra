import SwiftUI
import CabalmailKit

/// One account, as an administrator manages it: its status, the actions it
/// allows (confirm, enable or disable, delete), and which mail domains it may
/// create addresses on. Pushed from `UsersView`.
///
/// The signed-in administrator's own account offers no Disable or Delete: the
/// server refuses deleting it, and disabling it would sign them out for good.
struct UserDetailView: View {
    let model: UsersViewModel
    let username: String
    @Environment(\.dismiss) private var dismiss
    @State private var confirmingDelete = false

    var body: some View {
        Group {
            if let user = model.user(named: username) {
                form(for: user)
            } else {
                Text("This account no longer exists.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationTitle(username)
        .inlineNavigationTitle()
        .usersActionErrorAlert(model: model)
        .confirmationDialog(
            "Delete \(username)?",
            isPresented: $confirmingDelete,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                Task {
                    if await model.delete(username) { dismiss() }
                }
            }
            Button("Cancel", role: ConfirmationDialogPolicy.backOutRole) {}
        } message: {
            Text("The account and its domain access are deleted for good. This can't be undone.")
        }
    }

    private func form(for user: PoolUser) -> some View {
        Form {
            detailsSection(user)
            actionsSection(user)
            domainSection(user)
        }
        .groupedFormStyleOnMac()
    }

    private func detailsSection(_ user: PoolUser) -> some View {
        Section {
            LabeledContent("Status", value: Self.statusText(user.status))
            LabeledContent("Sign-in", value: user.enabled ? "Enabled" : "Disabled")
            if let created = user.created {
                LabeledContent("Created") {
                    Text(created, format: .dateTime.year().month().day())
                }
            }
            if let osid = user.osid {
                LabeledContent("Mail user ID", value: osid)
            }
        }
    }

    private func actionsSection(_ user: PoolUser) -> some View {
        let isBusy = model.busy.contains(user.username)
        let isSelf = model.isCurrentUser(user.username)
        return Section {
            if user.isPending {
                Button("Confirm account") {
                    Task { await model.confirm(user.username) }
                }
                .disabled(isBusy)
            } else {
                Button(user.enabled ? "Disable sign-in" : "Enable sign-in") {
                    Task { await model.setEnabled(user.username, enabled: !user.enabled) }
                }
                .disabled(isBusy || isSelf)
            }
            Button("Delete account…", role: .destructive) {
                confirmingDelete = true
            }
            .disabled(isBusy || isSelf)
        } footer: {
            if isSelf {
                Text("This is your own account, so it can't be disabled or deleted here.")
                    .sectionFooter()
            }
        }
    }

    private func domainSection(_ user: PoolUser) -> some View {
        Section {
            ForEach(model.domains, id: \.self) { domain in
                Toggle(domain, isOn: Binding(
                    get: { model.hasAccess(user.username, to: domain) },
                    set: { allowed in
                        Task { await model.setAccess(user.username, to: domain, allowed: allowed) }
                    }
                ))
            }
        } header: {
            Text("Domain access")
        } footer: {
            Text("\(user.username) can create addresses only on the domains turned on here.")
                .sectionFooter()
        }
    }

    /// Cognito's status in words.
    static func statusText(_ status: String) -> String {
        switch status {
        case "CONFIRMED": "Confirmed"
        case "UNCONFIRMED": "Awaiting confirmation"
        case "FORCE_CHANGE_PASSWORD": "Must set a new password"
        case "RESET_REQUIRED": "Must reset password"
        case "": "Unknown"
        default: status.capitalized
        }
    }

    /// The list row's second line.
    static func summary(of user: PoolUser, isCurrentUser: Bool) -> String {
        var parts = [user.isPending ? statusText(user.status) : (user.enabled ? "Enabled" : "Disabled")]
        if isCurrentUser { parts.append("You") }
        return parts.joined(separator: " · ")
    }
}
