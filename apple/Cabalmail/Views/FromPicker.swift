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
/// 2. Existing addresses, alphabetized.
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
                ForEach(sortedAddresses) { address in
                    Button {
                        model.fromAddress = address.address
                    } label: {
                        if address.address == model.fromAddress {
                            Label(address.address, systemImage: "checkmark")
                        } else {
                            Text(address.address)
                        }
                    }
                }
            }
        } label: {
            HStack {
                Text(model.fromAddress ?? "Select an address…")
                    .foregroundStyle(model.fromAddress == nil ? .secondary : .primary)
                Spacer()
                Image(systemName: "chevron.down")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
        }
    }

    private var sortedAddresses: [Address] {
        model.availableAddresses.sorted { $0.address < $1.address }
    }
}
