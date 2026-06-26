import SwiftUI
import CabalmailKit

/// Address sidebar (Phase 5 of the folder/address polish plan).
///
/// Mirrors `FolderListView`'s shape: two sections (Favorites on top when
/// non-empty, then All addresses inclusive), per-row swipe + context-menu
/// affordances to toggle the favorite flag. Selecting an address sets a
/// filter on the message list — the parent owns the selection binding,
/// so it can clear the filter when the user switches folders or taps
/// the chip in the message-list header.
struct AddressListView: View {
    @Environment(AppState.self) private var appState
    @State private var model: AddressesViewModel?
    @State private var filterQuery: String = ""
    @State private var isRefreshing = false
    @Binding var selection: Address?
    /// When set, the parent (the wide macOS / iPad-regular sidebar) owns the
    /// filter field — rendered below the section tabs — and this view filters by
    /// it instead of showing its own top-of-sidebar `.searchable`. Nil keeps the
    /// self-contained searchable (compact, standalone).
    var externalFilter: Binding<String>?
    /// The filter text actually in effect: the parent's when injected, else the
    /// view's own `.searchable` query.
    private var activeFilterText: String { externalFilter?.wrappedValue ?? filterQuery }

    var body: some View {
        List(selection: $selection) {
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
            ToolbarItem {
                Button {
                    Task { await manualRefresh() }
                } label: {
                    RefreshActivityIcon(isLoading: isRefreshing)
                        .accessibilityLabel("Refresh addresses")
                }
                .disabled(isRefreshing || model == nil)
            }
        }
        .refreshable {
            await model?.refresh(force: true)
        }
        .task {
            if model == nil, let client = appState.client {
                let newModel = AddressesViewModel(client: client)
                model = newModel
                await newModel.refresh()
            }
        }
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

    @ViewBuilder
    private func addressRow(_ address: Address, model: AddressesViewModel) -> some View {
        row(for: address)
            .tag(address)
            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
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
                    appState.showToast(.addressCopied(address.address), duration: 7)
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
            }
    }

    @ViewBuilder
    private func row(for address: Address) -> some View {
        HStack {
            Image(systemName: address.favorite ? "star.fill" : "at")
                .foregroundStyle(address.favorite ? Color.yellow : Color.accentColor)
            VStack(alignment: .leading, spacing: 2) {
                Text(address.address)
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
