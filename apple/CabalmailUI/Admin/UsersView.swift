import SwiftUI
import CabalmailKit

/// The administrator's Users screen (auth parity plan, C2), the Users
/// category's detail screen in Settings. Settings lists the category only
/// when the session's token names the `admin` group
/// (`SettingsCategory.listed(isAdmin:)`); the server enforces it either way.
///
/// The list splits accounts awaiting confirmation from confirmed ones, and
/// each row pushes `UserDetailView` for the account's actions and its domain
/// access, in the Settings detail column's `NavigationStack`.
struct UsersView: View {
    @Environment(AppState.self) private var appState
    @State private var model: UsersViewModel?

    var body: some View {
        Group {
            if let model {
                UsersListView(model: model)
            } else {
                ProgressView("Loading users…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationTitle("Users")
        .inlineNavigationTitle()
        .task {
            // Gate the load on the model's attempt flag, not on the model:
            // a pushed destination is rebuilt mid-transition on iPhone and a
            // cancelled first load must not strand its error (#1328).
            let target: UsersViewModel
            if let model {
                target = model
            } else {
                guard let client = appState.client else { return }
                target = UsersViewModel(
                    backend: LiveUsersBackend(client: client),
                    domains: client.configuration.domains.map(\.domain),
                    currentUsername: appState.lastUsername,
                    onAccessDenied: { [appState] in await appState.refreshAdminStatus() }
                )
                model = target
            }
            guard !target.hasAttemptedLoad else { return }
            await target.load()
        }
    }
}

private struct UsersListView: View {
    @Bindable var model: UsersViewModel

    var body: some View {
        AsyncContentView(
            isLoading: model.isLoading,
            loadingLabel: "Loading users…",
            errorMessage: model.loadError,
            retry: { Task { await model.load() } },
            content: {
                if model.accessDenied {
                    UsersAccessDeniedView()
                } else {
                    usersForm
                }
            }
        )
        .refreshable { await model.load() }
        .usersActionErrorAlert(model: model)
    }

    private var usersForm: some View {
        Form {
            if !model.pending.isEmpty {
                Section {
                    ForEach(model.pending) { user in
                        UserLink(model: model, user: user)
                    }
                } header: {
                    Text("Awaiting confirmation")
                } footer: {
                    Text("An account is confirmed when its owner enters the code from sign-up. "
                        + "Confirm one here if they can't.")
                        .sectionFooter()
                }
            }
            Section {
                ForEach(model.confirmed) { user in
                    UserLink(model: model, user: user)
                }
                Button {
                    Task { await model.load() }
                } label: {
                    Label("Reload", systemImage: "arrow.clockwise")
                }
            } header: {
                Text("Users")
            } footer: {
                Text("A new account can create addresses only on the domains an administrator turns on for it.")
                    .sectionFooter()
            }
        }
        .groupedFormStyleOnMac()
    }
}

/// One account's row: pushes its detail page.
private struct UserLink: View {
    let model: UsersViewModel
    let user: PoolUser

    var body: some View {
        NavigationLink {
            UserDetailView(model: model, username: user.username)
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(user.username)
                Text(UserDetailView.summary(of: user, isCurrentUser: model.isCurrentUser(user.username)))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private struct UsersAccessDeniedView: View {
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "lock")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text("Administrators only")
                .font(.headline)
            Text("The server says this account isn't an administrator.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

extension View {
    /// The alert for a failed Users action, shared by the list and the
    /// detail page.
    func usersActionErrorAlert(model: UsersViewModel) -> some View {
        alert(
            model.actionError?.title ?? "",
            isPresented: Binding(
                get: { model.actionError != nil },
                set: { if !$0 { model.actionError = nil } }
            ),
            presenting: model.actionError
        ) { _ in
            Button("OK") {}
        } message: { error in
            Text(error.message)
        }
    }
}
