import SwiftUI
import CabalmailKit

/// From-address picker surfaced at the top of the compose sheet.
///
/// Ordering (deliberate, per `docs/README.md`):
///
/// 1. **Create new address…** — always first. Minting a per-contact
///    address is the *primary* compose action, not a side door. Placing it
///    ahead of the existing list also keeps the default-zero-state rule
///    ("no preselection") visually coherent: if the user hasn't picked an
///    address yet, creating one is the nearest thing to click.
/// 2. Existing addresses: **Favorites** section on top (when non-empty),
///    then **All addresses** inclusive — mirrors the sidebar address list.
///
/// Send remains disabled (`ComposeViewModel.canSend`) until the user has
/// either picked an existing address or completed the inline creation flow.
struct FromPicker: View {
    @Bindable var model: ComposeViewModel
    let onCreateAddress: () -> Void

    var body: some View {
        Menu {
            Button {
                onCreateAddress()
            } label: {
                Label("Create new address…", systemImage: "plus.circle")
            }
            if !model.availableAddresses.isEmpty {
                Divider()
                if !favoriteAddresses.isEmpty {
                    Section("Favorites") {
                        ForEach(favoriteAddresses) { addressButton($0) }
                    }
                    Section("All addresses") {
                        ForEach(sortedAddresses) { addressButton($0) }
                    }
                } else {
                    ForEach(sortedAddresses) { addressButton($0) }
                }
            }
        } label: {
            HStack {
                fromLabel
                    .foregroundStyle(model.fromAddress == nil ? .secondary : .primary)
                Spacer()
                if FromPickerChevronPolicy.labelDrawsChevron(on: .current) {
                    Image(systemName: "chevron.down")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .contentShape(Rectangle())
        }
        .accessibilityIdentifier("compose.from")
    }

    /// The field's own label: the address mail will be sent from.
    ///
    /// Addresses here are drawn through `AddressDisplay.wrappable`, like every
    /// other surface that shows a whole address: the token has no legal break,
    /// so a row narrow enough to wrap it hyphenates and draws a character the
    /// address does not contain (#1597 — `…@longsubdomain-` / `probe0916…` in
    /// this label on iPhone, `pouls-f0k` for `poulsf0k` in the menu rows). The
    /// raw address stays what VoiceOver reads.
    @ViewBuilder
    private var fromLabel: some View {
        if let fromAddress = model.fromAddress {
            Text(AddressDisplay.wrappable(fromAddress))
                .accessibilityLabel(fromAddress)
        } else {
            Text("Select an address…")
        }
    }

    private func addressButton(_ address: Address) -> some View {
        Button {
            model.fromAddress = address.address
        } label: {
            if address.address == model.fromAddress {
                Label(AddressDisplay.wrappable(address.address), systemImage: "checkmark")
                    .accessibilityLabel(address.address)
            } else {
                Text(AddressDisplay.wrappable(address.address))
                    .accessibilityLabel(address.address)
            }
        }
    }

    private var favoriteAddresses: [Address] {
        model.availableAddresses.filter { $0.favorite }.sorted { $0.address < $1.address }
    }

    private var sortedAddresses: [Address] {
        model.availableAddresses.sorted { $0.address < $1.address }
    }
}
