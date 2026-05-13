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
                if !model.favorites.isEmpty {
                    Section("Favorites") {
                        ForEach(model.favorites, id: \.address) { address in
                            addressRow(address, model: model)
                        }
                    }
                    Section("All addresses") {
                        ForEach(model.addresses, id: \.address) { address in
                            addressRow(address, model: model)
                        }
                    }
                } else {
                    ForEach(model.addresses, id: \.address) { address in
                        addressRow(address, model: model)
                    }
                }
            }
        }
        .navigationTitle("Addresses")
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
