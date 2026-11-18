import SwiftUI
import CabalmailKit

/// From-address picker surfaced at the top of the compose sheet.
///
/// The field opens `FromAddressList`, a filter field over the addresses: a
/// popover on iPadOS, macOS and visionOS, a sheet on iPhone. It used to open
/// a `Menu`, which can't hold a text field, and a user who mints an address
/// per contact has more of them than a menu can usefully be scrolled through.
///
/// Ordering (deliberate, per `docs/README.md`):
///
/// 1. **Create new address…** — always first. Minting a per-contact
///    address is the *primary* compose action, not a side door. Placing it
///    ahead of the existing list also keeps the default-zero-state rule
///    ("no preselection") visually coherent: if the user hasn't picked an
///    address yet, creating one is the nearest thing to click.
/// 2. Existing addresses: **Favorites** section on top (when any match the
///    filter), then **All addresses** inclusive. (The sidebar address list
///    is one list under a Favorites pill instead; a picker wants both at
///    once.)
///
/// Send remains disabled (`ComposeViewModel.canSend`) until the user has
/// either picked an existing address or completed the inline creation flow.
struct FromPicker: View {
    @Bindable var model: ComposeViewModel
    let onCreateAddress: () -> Void

    @State private var isChoosing = false
    /// Set by the list's Create row, and acted on once the list has gone:
    /// the new-address sheet is presented from the compose surface, and on
    /// iPhone the list is a sheet over that surface, which can't present a
    /// second one until the first has finished leaving.
    @State private var createsOnDismiss = false

    var body: some View {
        Button {
            isChoosing = true
        } label: {
            HStack {
                fromLabel
                    .foregroundStyle(model.fromAddress == nil ? .secondary : .primary)
                Spacer()
                // A button draws no disclosure of its own on any platform,
                // so this is the control's only chevron (#1167 was a second
                // one, from the menu style the Mac used to draw this with).
                Image(systemName: "chevron.down")
                    .appFont(.caption)
                    .foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
        }
        .accessibilityIdentifier("compose.from")
        .popover(isPresented: $isChoosing, arrowEdge: .bottom) {
            FromAddressList(
                addresses: model.availableAddresses,
                selected: model.fromAddress,
                onPick: { address in
                    model.fromAddress = address.address
                    isChoosing = false
                },
                onCreateAddress: {
                    createsOnDismiss = true
                    isChoosing = false
                }
            )
            .onDisappear {
                guard createsOnDismiss else { return }
                createsOnDismiss = false
                onCreateAddress()
            }
        }
    }

    /// The field's own label: the address mail will be sent from.
    ///
    /// Addresses here are drawn through `AddressDisplay.wrappable`, like every
    /// other surface that shows a whole address: the token has no legal break,
    /// so a row narrow enough to wrap it hyphenates and draws a character the
    /// address does not contain (#1597 — `…@longsubdomain-` / `probe0916…` in
    /// this label on iPhone). The raw address stays what VoiceOver reads.
    @ViewBuilder
    private var fromLabel: some View {
        if let fromAddress = model.fromAddress {
            Text(AddressDisplay.wrappable(fromAddress))
                .accessibilityLabel(fromAddress)
        } else {
            Text("Select an address…")
        }
    }
}
