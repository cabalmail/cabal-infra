import CabalmailKit
import SwiftUI

/// Root view: reconnect prompt, loading spinner, or the address list,
/// depending on where the credential lifecycle stands (see WatchAppModel).
struct ContentView: View {
    @Environment(WatchAppModel.self) private var model

    /// Row awaiting revoke confirmation (drives the dialog).
    @State private var pendingRevoke: Address?

    /// Screenshot scaffolding: pushes the new-address flow (or the first
    /// address's large-type detail) on launch when the matching
    /// CABAL_WATCH_PREVIEW seed is active (see WatchAppModel).
    @State private var autoPushNewAddress = false
    @State private var autoPushDetail = false

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Cabalmail")
                .navigationDestination(isPresented: $autoPushNewAddress) {
                    NewAddressView()
                }
                .navigationDestination(isPresented: $autoPushDetail) {
                    if case .ready(let addresses) = model.phase, let first = addresses.first {
                        AddressDetailView(address: first)
                    }
                }
                .onAppear {
                    #if DEBUG
                    autoPushNewAddress = model.previewAutoPushNewAddress
                    autoPushDetail = model.previewAutoPushDetail
                    #endif
                }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case .waiting:
            waiting
        case .loading:
            ProgressView()
        case .ready(let addresses):
            list(addresses)
        case .failed(let message):
            failed(message)
        }
    }

    private var waiting: some View {
        VStack(spacing: 8) {
            Image(systemName: "iphone.and.arrow.right.inward")
                .font(.title3)
                .foregroundStyle(.tint)
            Text("Open Cabalmail on your iPhone to connect this watch.")
                .font(.footnote)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }

    private func failed(_ message: String) -> some View {
        VStack(spacing: 8) {
            Text(message)
                .font(.footnote)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            Button("Retry") {
                Task { await model.refresh() }
            }
        }
    }

    private func list(_ addresses: [Address]) -> some View {
        List {
            if addresses.isEmpty {
                Text("No addresses yet. Tap + to mint one.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            ForEach(addresses, id: \.address) { address in
                row(address)
                    .swipeActions(edge: .trailing) {
                        Button(role: .destructive) {
                            pendingRevoke = address
                        } label: {
                            Label("Revoke", systemImage: "xmark.bin")
                        }
                    }
            }
        }
        .refreshable {
            await model.refresh()
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                NavigationLink {
                    NewAddressView()
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel("New address")
            }
        }
        .confirmationDialog(
            "Revoke \(pendingRevoke?.address ?? "address")?",
            isPresented: revokeDialogBinding,
            titleVisibility: .visible,
            presenting: pendingRevoke
        ) { address in
            Button("Revoke", role: .destructive) {
                Task { await model.revoke(address) }
            }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("Mail sent to it will stop being delivered.")
        }
    }

    private var revokeDialogBinding: Binding<Bool> {
        Binding(
            get: { pendingRevoke != nil },
            set: { if !$0 { pendingRevoke = nil } }
        )
    }

    private func row(_ address: Address) -> some View {
        // Tap → large-type display (AddressDetailView); the trailing
        // swipe action for revoke coexists with the link.
        NavigationLink {
            AddressDetailView(address: address)
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    if address.favorite {
                        Image(systemName: "star.fill")
                            .font(.caption2)
                            .foregroundStyle(.yellow)
                    }
                    Text(address.address)
                        .font(.footnote)
                        .lineLimit(2)
                }
                if let comment = address.comment, !comment.isEmpty {
                    Text(comment)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
    }
}
