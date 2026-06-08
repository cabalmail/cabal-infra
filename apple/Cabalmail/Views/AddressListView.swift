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
        .searchable(text: $filterQuery, placement: .sidebar, prompt: "Filter addresses")
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
        let needle = filterQuery.trimmingCharacters(in: .whitespaces).lowercased()
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
