import SwiftUI
import CabalmailKit

/// Address sidebar (Phase 5 of the folder/address polish plan).
///
/// Mirrors `FolderListView`'s shape: two sections (Favorites on top when
/// non-empty, then All addresses inclusive), per-row swipe + context-menu
/// affordances to toggle the favorite flag. Tapping an address copies it
/// to the pasteboard — the list is a management/grab surface, not a
/// message-list filter.
struct AddressListView: View {
    @Environment(AppState.self) private var appState
    @State private var model: AddressesViewModel?
    @State private var filterQuery: String = ""
    @State private var isRefreshing = false
    // Drives the "Request new address" sheet from the toolbar `+` button.
    @State private var showNewAddressSheet = false
    // Address staged for revocation by a row's swipe / context menu,
    // confirmed before the (irreversible) API call.
    @State private var pendingRevoke: Address?
    // Address staged for suspension. Reinstating is harmless (it republishes
    // DNS records) and fires directly, so only suspend is staged here.
    @State private var pendingSuspend: Address?
    /// When set, the parent (the wide macOS / iPad-regular sidebar) owns the
    /// filter field — rendered below the section tabs — and this view filters by
    /// it instead of showing its own top-of-sidebar `.searchable`. Nil keeps the
    /// self-contained searchable (compact, standalone).
    var externalFilter: Binding<String>?
    /// The filter text actually in effect: the parent's when injected, else the
    /// view's own `.searchable` query.
    private var activeFilterText: String { externalFilter?.wrappedValue ?? filterQuery }

    var body: some View {
        VStack(spacing: 0) {
            // Wide sidebar (iPad-regular / macOS): New / Reload flank the filter
            // below the Folders/Addresses tabs. Compact keeps them in the toolbar.
            if let externalFilter {
                SidebarListHeaderRow(
                    newAction: { showNewAddressSheet = true },
                    newDisabled: false,
                    newAccessibilityLabel: "Request new address",
                    newIdentifier: "address.new",
                    filterText: externalFilter,
                    filterPrompt: "Filter addresses",
                    isRefreshing: isRefreshing,
                    refreshDisabled: isRefreshing || model == nil,
                    refreshAccessibilityLabel: "Refresh addresses",
                    refreshIdentifier: "address.refresh",
                    refreshAction: { Task { await manualRefresh() } }
                )
            }
            addressList
        }
    }

    private var addressList: some View {
        List {
            if let model {
                if model.isLoading && model.addresses.isEmpty {
                    ProgressView("Loading addresses…")
                }
                if let errorMessage = model.errorMessage {
                    Label(errorMessage, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                }
                let favorites = filteredAddresses(model.favorites)
                let all = filteredAddresses(model.addresses)
                if !model.favorites.isEmpty {
                    Section("Favorites") {
                        ForEach(favorites, id: \.address) { address in
                            addressRow(address, model: model)
                        }
                    }
                    Section("All addresses") {
                        ForEach(all, id: \.address) { address in
                            addressRow(address, model: model)
                        }
                    }
                } else {
                    ForEach(all, id: \.address) { address in
                        addressRow(address, model: model)
                    }
                }
            }
        }
        .navigationTitle("Addresses")
        .sidebarFilterSearchable(text: $filterQuery, enabled: externalFilter == nil, prompt: "Filter addresses")
        .toolbar {
            // Compact keeps New / Reload in the toolbar; the wide sidebar moves
            // them into SidebarListHeaderRow beside the filter (externalFilter is
            // non-nil only on the wide layout).
            if externalFilter == nil {
                ToolbarItem {
                    Button {
                        showNewAddressSheet = true
                    } label: {
                        Image(systemName: "plus")
                            .accessibilityLabel("Request new address")
                    }
                    .accessibilityIdentifier("address.new")
                }
                ToolbarItem {
                    Button {
                        Task { await manualRefresh() }
                    } label: {
                        RefreshActivityIcon(isLoading: isRefreshing)
                            .accessibilityLabel("Refresh addresses")
                    }
                    .disabled(isRefreshing || model == nil)
                    .accessibilityIdentifier("address.refresh")
                }
            }
        }
        .refreshable {
            await model?.refresh(force: true)
        }
        .sheet(isPresented: $showNewAddressSheet) { newAddressSheet }
        .confirmationDialog(
            revokeDialogTitle,
            isPresented: revokeDialogBinding,
            titleVisibility: .visible,
            presenting: pendingRevoke,
            actions: revokeDialogActions,
            message: revokeDialogMessage
        )
        .confirmationDialog(
            suspendDialogTitle,
            isPresented: suspendDialogBinding,
            titleVisibility: .visible,
            presenting: pendingSuspend,
            actions: suspendDialogActions,
            message: suspendDialogMessage
        )
        .task {
            if model == nil, let client = appState.client {
                let newModel = AddressesViewModel(client: client)
                model = newModel
                await newModel.refresh()
            }
        }
    }

    @ViewBuilder
    private var newAddressSheet: some View {
        NewAddressSheet(
            domains: appState.client?.configuration.domains ?? [],
            onCreate: { address in
                await model?.onAddressCreated()
                appState.showToast(.addressCreated(address))
            }
        )
        .environment(appState)
    }

    private func manualRefresh() async {
        guard let model, !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        await model.refresh(force: true)
    }

    private func filteredAddresses(_ addresses: [Address]) -> [Address] {
        let needle = activeFilterText.trimmingCharacters(in: .whitespaces).lowercased()
        guard !needle.isEmpty else { return addresses }
        return addresses.filter { address in
            address.address.lowercased().contains(needle)
                || (address.comment?.lowercased().contains(needle) ?? false)
        }
    }
}

// Row construction and the confirmation-dialog plumbing live in a same-file
// extension so the primary struct body stays under SwiftLint's
// type_body_length cap (same split as MessageListView and its +Rows/+Bulk
// files, kept in-file here so the `private` state remains reachable).
extension AddressListView {
    // MARK: - Revoke confirmation plumbing

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
        Button("Cancel", role: ConfirmationDialogPolicy.backOutRole) {
            pendingRevoke = nil
        }
    }

    @ViewBuilder
    private func revokeDialogMessage(for address: Address) -> some View {
        Text("Mail sent to \(address.address) will be rejected. This can't be undone.")
    }

    // MARK: - Suspend confirmation plumbing

    private var suspendDialogTitle: String {
        if let address = pendingSuspend {
            return "Suspend \(address.address)?"
        }
        return "Suspend address?"
    }

    private var suspendDialogBinding: Binding<Bool> {
        Binding(
            get: { pendingSuspend != nil },
            set: { isPresented in
                if !isPresented { pendingSuspend = nil }
            }
        )
    }

    @ViewBuilder
    private func suspendDialogActions(for address: Address) -> some View {
        Button("Suspend") {
            let target = address
            pendingSuspend = nil
            Task { await model?.setSuspended(target, to: true) }
        }
        Button("Cancel", role: ConfirmationDialogPolicy.backOutRole) {
            pendingSuspend = nil
        }
    }

    @ViewBuilder
    private func suspendDialogMessage(for address: Address) -> some View {
        Text("""
        The DNS records for \(address.address) will be removed and inbound mail \
        will stop being deliverable. The address is kept and can be reinstated \
        at any time.
        """)
    }

    @ViewBuilder
    private func suspendToggleButton(_ address: Address, model: AddressesViewModel) -> some View {
        Button {
            if address.suspended {
                Task { await model.setSuspended(address, to: false) }
            } else {
                pendingSuspend = address
            }
        } label: {
            Label(
                address.suspended ? "Reinstate" : "Suspend",
                systemImage: address.suspended ? "play.circle" : "pause.circle"
            )
        }
        .accessibilityIdentifier("address.suspend")
    }

    @ViewBuilder
    private func addressRow(_ address: Address, model: AddressesViewModel) -> some View {
        Button {
            copyAddress(address)
        } label: {
            row(for: address)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Copy \(address.address)")
            // Two edges so neither side outgrows a narrow sidebar pane, and
            // the full-swipe default is the reversible action (suspend /
            // reinstate), not revoke. First button listed = full-swipe action.
            .swipeActions(edge: .leading, allowsFullSwipe: true) {
                suspendToggleButton(address, model: model)
                    .tint(.orange)
                Button(role: .destructive) {
                    pendingRevoke = address
                } label: {
                    Label("Revoke", systemImage: "xmark.bin")
                }
                .accessibilityIdentifier("address.revoke")
            }
            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                Button {
                    Task { await model.toggleFavorite(address) }
                } label: {
                    Label(
                        address.favorite ? "Unfavorite" : "Favorite",
                        systemImage: address.favorite ? "star.slash" : "star"
                    )
                }
                .tint(address.favorite ? .gray : .yellow)
                .accessibilityIdentifier("address.favorite")
            }
            // `.contain` keeps the revealed swipe buttons individually
            // reachable — see the subtree-merge trap in
            // docs/0.11.x/apple-testability-and-accessibility.md.
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("address.row.\(address.address)")
            .contextMenu {
                rowContextMenu(address, model: model)
            }
    }

    @ViewBuilder
    private func rowContextMenu(_ address: Address, model: AddressesViewModel) -> some View {
        Button {
            copyAddress(address)
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
        suspendToggleButton(address, model: model)
        Button(role: .destructive) {
            pendingRevoke = address
        } label: {
            Label("Revoke", systemImage: "xmark.bin")
        }
    }

    private func copyAddress(_ address: Address) {
        copyToPasteboard(address.address)
        appState.showToast(.addressCopied(address.address), duration: 7)
    }

    @ViewBuilder
    private func row(for address: Address) -> some View {
        HStack {
            Image(systemName: address.favorite ? "star.fill" : "at")
                // The asset-catalog accent, pinned like the folder icons
                // (see `iconForeground` in FolderListView+Helpers.swift):
                // `Color.accentColor` follows the macOS system accent when
                // that isn't "multicolor", leaving the icons off-brand.
                .foregroundStyle(address.favorite ? Color.yellow : Color("AccentColor"))
            VStack(alignment: .leading, spacing: 2) {
                Text(address.address)
                    .foregroundStyle(address.suspended ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
                if address.suspended {
                    Text("Suspended")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
                if let comment = address.comment, !comment.isEmpty {
                    Text(comment)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        #if os(visionOS)
        .contentShape(Rectangle())
        .hoverEffect(.highlight)
        #endif
    }
}
