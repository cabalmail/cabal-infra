import SwiftUI
import CabalmailKit

/// Addresses tab — mirrors `react/admin/src/Addresses/` (Phase 6, step 1).
///
/// Two sections: the user's owned addresses (revoke via swipe or context
/// menu, confirmation alert before the API call) and a "Request New" button
/// that presents the same `NewAddressSheet` the compose From picker uses.
///
/// The React equivalent split these into separate routes (`/addresses` vs
/// `/addresses/request`). Here the tab is the address list and the new-
/// address form opens as a sheet — native-idiomatic and keeps the caller on
/// the same screen after creation so a user can create several addresses in
/// a row without a screen flash per attempt.
struct AddressesView: View {
    @Environment(AppState.self) private var appState
    @State private var model: AddressesViewModel?
    @State private var showNewAddressSheet = false
    @State private var pendingRevoke: Address?
    @State private var filterQuery: String = ""
    @State private var isRefreshing = false
    /// Local banner. On iPad-regular this view lives in the settings sheet
    /// and on macOS in the settings window, so the root `AppState.toast`
    /// overlay can't reach it — host copy / creation banners here.
    @State private var toast: Toast?

    var body: some View {
        #if os(macOS)
        // Inside the Settings window's TabView the General tab is a bare
        // Form (see SettingsView) but Addresses and Folders had been
        // wrapped in NavigationStack + a `.toolbar` / `.safeAreaInset`
        // action strip. Both of those contribute to the window's
        // toolbar region, which is the same horizontal band the
        // General/Addresses/Folders tab buttons live in, so the tab
        // buttons re-centered whenever the active tab differed from
        // General. Match the SettingsView shape - bare content, no
        // NavigationStack - and move the "Request new address" action
        // into the List as its own section so the action has its own
        // space inside the scrollable content rather than crowding
        // the tab toolbar.
        content
            .refreshable { await model?.refresh(force: true) }
            .task { await ensureModel() }
            .sheet(isPresented: $showNewAddressSheet) { newAddressSheet }
            .confirmationDialog(
                revokeDialogTitle,
                isPresented: revokeDialogBinding,
                presenting: pendingRevoke,
                actions: revokeDialogActions,
                message: revokeDialogMessage
            )
            .toastOverlay($toast)
        #else
        NavigationStack {
            content
                .navigationTitle("Addresses")
                .toolbar { toolbarContent }
                .settingsSheetDoneButton()
                .refreshable { await model?.refresh(force: true) }
                .task { await ensureModel() }
                .sheet(isPresented: $showNewAddressSheet) { newAddressSheet }
                .confirmationDialog(
                    revokeDialogTitle,
                    isPresented: revokeDialogBinding,
                    presenting: pendingRevoke,
                    actions: revokeDialogActions,
                    message: revokeDialogMessage
                )
                .toastOverlay($toast)
        }
        #endif
    }

    private func manualRefresh() async {
        guard let model, !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        await model.refresh(force: true)
    }

    private func filteredAddresses(_ addresses: [Address]) -> [Address] {
        let needle = filterQuery.trimmingCharacters(in: .whitespaces).lowercased()
        guard !needle.isEmpty else { return addresses }
        return addresses.filter { address in
            address.address.lowercased().contains(needle)
                || (address.comment?.lowercased().contains(needle) ?? false)
        }
    }

    // MARK: - Subviews

    @ViewBuilder
    private var content: some View {
        if let model {
            List {
                if let errorMessage = model.errorMessage {
                    Section {
                        Label(errorMessage, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.red)
                    }
                }
                #if os(macOS)
                actionsSection
                #endif
                mainSection(for: model)
            }
        } else {
            ProgressView()
        }
    }

    #if os(macOS)
    // Filter + actions live in the List rather than the window's
    // toolbar/sidebar so they don't compete for space with the
    // General/Addresses/Folders tab buttons. `.searchable` would
    // default to toolbar placement on macOS, which re-introduces the
    // displacement bug.
    @ViewBuilder
    private var actionsSection: some View {
        Section {
            TextField("Filter addresses", text: $filterQuery)
            Button {
                Task { await manualRefresh() }
            } label: {
                Label {
                    Text("Refresh")
                } icon: {
                    RefreshActivityIcon(isLoading: isRefreshing)
                }
            }
            .disabled(isRefreshing || model == nil)
            Button {
                showNewAddressSheet = true
            } label: {
                Label("Request New Address", systemImage: "plus")
            }
        }
    }
    #endif

    @ViewBuilder
    private func mainSection(for model: AddressesViewModel) -> some View {
        if model.isLoading && model.addresses.isEmpty {
            Section("My Addresses") {
                ProgressView()
                    .frame(maxWidth: .infinity, alignment: .center)
            }
        } else if model.addresses.isEmpty {
            Section("My Addresses") {
                // iPhone clips ContentUnavailableView inside a Section — use
                // a plain label so the "no addresses" hint still reads cleanly.
                #if os(macOS)
                Label("No addresses yet.", systemImage: "at")
                    .foregroundStyle(.secondary)
                #else
                Label(
                    "Tap + to request your first address.",
                    systemImage: "at"
                )
                .foregroundStyle(.secondary)
                #endif
            }
        } else if !model.favorites.isEmpty {
            Section("Favorites") {
                ForEach(filteredAddresses(model.favorites)) { address in
                    addressRow(address, model: model)
                }
            }
            Section("All addresses") {
                ForEach(filteredAddresses(model.addresses)) { address in
                    addressRow(address, model: model)
                }
            }
        } else {
            Section("My Addresses") {
                ForEach(filteredAddresses(model.addresses)) { address in
                    addressRow(address, model: model)
                }
            }
        }
    }

    @ViewBuilder
    private func addressRow(_ address: Address, model: AddressesViewModel) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(address.address)
                .font(.body)
                .textSelection(.enabled)
            if let comment = address.comment, !comment.isEmpty {
                Text(comment)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .swipeActions(edge: .trailing) {
            Button(role: .destructive) {
                pendingRevoke = address
            } label: {
                Label("Revoke", systemImage: "xmark.bin")
            }
            Button {
                Task { await model.toggleFavorite(address) }
            } label: {
                Label(
                    address.favorite ? "Unfavorite" : "Favorite",
                    systemImage: address.favorite ? "star.slash" : "star"
                )
            }
            .tint(address.favorite ? .gray : .yellow)
        }
        .contextMenu {
            Button {
                copyToPasteboard(address.address)
                toast = .addressCopied(address.address)
            } label: {
                Label("Copy Address", systemImage: "doc.on.doc")
            }
            Button {
                Task { await model.toggleFavorite(address) }
            } label: {
                Label(
                    address.favorite ? "Unfavorite" : "Favorite",
                    systemImage: address.favorite ? "star.slash" : "star.fill"
                )
            }
            Button(role: .destructive) {
                pendingRevoke = address
            } label: {
                Label("Revoke", systemImage: "xmark.bin")
            }
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem {
            Button {
                Task { await manualRefresh() }
            } label: {
                RefreshActivityIcon(isLoading: isRefreshing)
                    .accessibilityLabel("Refresh addresses")
            }
            .disabled(isRefreshing || model == nil)
        }
        ToolbarItem {
            Button {
                showNewAddressSheet = true
            } label: {
                Image(systemName: "plus")
                    .accessibilityLabel("Request new address")
            }
        }
    }

    @ViewBuilder
    private var newAddressSheet: some View {
        NewAddressSheet(
            domains: appState.client?.configuration.domains ?? [],
            onCreate: { address in
                await model?.onAddressCreated()
                toast = .addressCreated(address)
            }
        )
        .environment(appState)
    }

    // MARK: - Confirmation dialog plumbing

    private var revokeDialogTitle: String {
        if let address = pendingRevoke {
            return "Revoke \(address.address)?"
        }
        return "Revoke address?"
    }

    private var revokeDialogBinding: Binding<Bool> {
        Binding(
            get: { pendingRevoke != nil },
            set: { isPresented in
                if !isPresented { pendingRevoke = nil }
            }
        )
    }

    @ViewBuilder
    private func revokeDialogActions(for address: Address) -> some View {
        Button("Revoke", role: .destructive) {
            let target = address
            pendingRevoke = nil
            Task { await model?.revoke(target) }
        }
        Button("Cancel", role: .cancel) {
            pendingRevoke = nil
        }
    }

    @ViewBuilder
    private func revokeDialogMessage(for address: Address) -> some View {
        Text("Mail sent to \(address.address) will be rejected. This can't be undone.")
    }
}

// MARK: - Lifecycle

extension AddressesView {
    private func ensureModel() async {
        if model == nil, let client = appState.client {
            model = AddressesViewModel(client: client)
            await model?.refresh()
        }
    }
}
